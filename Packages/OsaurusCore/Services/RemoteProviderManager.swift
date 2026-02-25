//
//  RemoteProviderManager.swift
//  osaurus
//
//  Manages remote OpenAI-compatible API provider connections.
//

import Foundation

/// Notification posted when remote provider connection status changes
extension Foundation.Notification.Name {
    static let remoteProviderStatusChanged = Foundation.Notification.Name("RemoteProviderStatusChanged")
    static let remoteProviderModelsChanged = Foundation.Notification.Name("RemoteProviderModelsChanged")
}

/// Errors for remote provider operations
public enum RemoteProviderError: LocalizedError {
    case providerNotFound
    case providerDisabled
    case notConnected
    case invalidURL
    case timeout
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .providerNotFound:
            return "Provider not found"
        case .providerDisabled:
            return "Provider is disabled"
        case .notConnected:
            return "Not connected to provider"
        case .invalidURL:
            return "Invalid server URL"
        case .timeout:
            return "Request timed out"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        }
    }
}

/// Manages all remote OpenAI-compatible API provider connections
@MainActor
public final class RemoteProviderManager: ObservableObject {
    public static let shared = RemoteProviderManager()

    struct Hooks {
        var connectOverride: (@Sendable (_ providerId: UUID) async throws -> Void)?
    }

    nonisolated(unsafe) static var hooks: Hooks?
    nonisolated(unsafe) static var startupAutoConnectRetryDelaysOverrideNs: [UInt64]?

    /// Current configuration
    @Published public private(set) var configuration: RemoteProviderConfiguration

    /// Runtime state for each provider
    @Published public private(set) var providerStates: [UUID: RemoteProviderState] = [:]

    /// Active service instances keyed by provider ID
    private var services: [UUID: RemoteProviderService] = [:]
    private static var startupAutoConnectRetryDelaysNs: [UInt64] {
        startupAutoConnectRetryDelaysOverrideNs ?? [0, 500_000_000, 1_500_000_000]
    }

    private init() {
        self.configuration = RemoteProviderConfigurationStore.load()

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = RemoteProviderState(providerId: provider.id)
        }
    }

    // MARK: - Provider Management

    /// Add a new provider
    public func addProvider(_ provider: RemoteProvider, apiKey: String?) {
        configuration.add(provider)
        RemoteProviderConfigurationStore.save(configuration)

        // Save API key to Keychain if provided
        if let apiKey = apiKey, !apiKey.isEmpty {
            RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
        }

        // Initialize state
        providerStates[provider.id] = RemoteProviderState(providerId: provider.id)

        // Auto-connect if enabled
        if provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
    }

    /// Update an existing provider
    public func updateProvider(_ provider: RemoteProvider, apiKey: String?) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        configuration.update(provider)
        RemoteProviderConfigurationStore.save(configuration)

        // Update API key if provided (nil means no change, empty string means clear)
        if let apiKey = apiKey {
            if apiKey.isEmpty {
                RemoteProviderKeychain.deleteAPIKey(for: provider.id)
            } else {
                RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
            }
        }

        // Reconnect if was connected and still enabled
        if wasConnected && provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
    }

    /// Remove a provider
    public func removeProvider(id: UUID) {
        // Disconnect first
        disconnect(providerId: id)

        // Remove from configuration (also cleans up Keychain)
        configuration.remove(id: id)
        RemoteProviderConfigurationStore.save(configuration)

        // Clean up state
        providerStates.removeValue(forKey: id)

        notifyStatusChanged()
        notifyModelsChanged()
    }

    /// Set enabled state for a provider
    /// When enabled is true, automatically connects to the provider
    /// When enabled is false, disconnects from the provider
    public func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        RemoteProviderConfigurationStore.save(configuration)

        if enabled {
            // Always auto-connect when toggled ON
            Task {
                try? await connect(providerId: providerId)
            }
        } else {
            disconnect(providerId: providerId)
        }

        notifyStatusChanged()
    }

    // MARK: - Connection Management

    /// Connect to a provider (fetch models and create service)
    public func connect(providerId: UUID) async throws {
        guard let provider = configuration.provider(id: providerId) else {
            throw RemoteProviderError.providerNotFound
        }

        guard provider.enabled else {
            throw RemoteProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? RemoteProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
        state.healthState = .unknownFailure
        state.healthFixIt = nil
        providerStates[providerId] = state

        await emitDiagnostic(
            level: .info,
            event: "remote.connect.begin",
            context: [
                "providerId": provider.id.uuidString,
                "providerName": provider.name,
                "providerType": provider.providerType.rawValue,
                "baseURL": provider.baseURL?.absoluteString ?? "<invalid-url>",
            ]
        )

        do {
            // Fetch models from the provider
            let models = try await RemoteProviderService.fetchModels(from: provider)

            // Create service instance
            let service = RemoteProviderService(provider: provider, models: models)
            services[providerId] = service

            // Update state to connected
            state.isConnecting = false
            state.isConnected = true
            state.discoveredModels = models
            state.lastConnectedAt = Date()
            state.lastError = nil
            state.healthState = .ready
            state.healthFixIt = nil
            providerStates[providerId] = state

            print("[Osaurus] Remote Provider '\(provider.name)': Connected with \(models.count) models")
            await emitDiagnostic(
                level: .info,
                event: "remote.connect.success",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "modelCount": "\(models.count)",
                ]
            )

            notifyStatusChanged()
            notifyModelsChanged()

        } catch {
            let classified = classifyConnectionFailure(error, provider: provider)

            // Update state with error
            state.isConnecting = false
            state.isConnected = false
            state.lastError = classified.message
            state.healthState = classified.healthState
            state.healthFixIt = classified.fixIt
            state.discoveredModels = []
            providerStates[providerId] = state

            // Clean up — invalidate URLSession before discarding
            if let service = services.removeValue(forKey: providerId) {
                Task { await service.invalidateSession() }
            }

            print("[Osaurus] Remote Provider '\(provider.name)': Connection failed - \(classified.message)")
            await emitDiagnostic(
                level: .error,
                event: "remote.connect.failed",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "failureClass": classified.failureClass.rawValue,
                    "healthState": classified.healthState.rawValue,
                    "message": classified.message,
                    "fixIt": classified.fixIt ?? "",
                ]
            )

            notifyStatusChanged()
            throw RemoteProviderError.connectionFailed(classified.message)
        }
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
        // Invalidate the URLSession before discarding the service to prevent leaking
        if let service = services.removeValue(forKey: providerId) {
            Task { await service.invalidateSession() }
        }

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.lastError = nil
            state.healthState = .unknownFailure
            state.healthFixIt = nil
            state.discoveredModels = []
            providerStates[providerId] = state
        }

        if let provider = configuration.provider(id: providerId) {
            print("[Osaurus] Remote Provider '\(provider.name)': Disconnected")
        }

        notifyStatusChanged()
        notifyModelsChanged()
    }

    /// Reconnect to a provider
    public func reconnect(providerId: UUID) async throws {
        disconnect(providerId: providerId)
        try await connect(providerId: providerId)
    }

    /// Connect to all enabled providers that are marked for auto-connect on app launch
    public func connectEnabledProviders(isStartup: Bool = false) async {
        for provider in configuration.autoConnectProviders {
            if isStartup,
               shouldDisableStartupAutoConnect(provider: provider, healthState: .misconfiguredEndpoint)
            {
                await emitDiagnostic(
                    level: .warning,
                    event: "remote.autoconnect.skipped",
                    context: [
                        "providerId": provider.id.uuidString,
                        "providerName": provider.name,
                        "reason": "openclaw-endpoint-sanity-failed",
                    ]
                )
                await disableAutoConnectForProvider(
                    provider,
                    reason: "misconfigured-openclaw-endpoint"
                )
                continue
            }

            if isStartup,
                providerStates[provider.id]?.healthState == .misconfiguredEndpoint
            {
                await emitDiagnostic(
                    level: .warning,
                    event: "remote.autoconnect.skipped",
                    context: [
                        "providerId": provider.id.uuidString,
                        "providerName": provider.name,
                        "reason": "previously-misconfigured-endpoint",
                    ]
                )
                continue
            }

            let maxAttempts = isStartup ? Self.startupAutoConnectRetryDelaysNs.count : 1
            for attempt in 1...maxAttempts {
                if isStartup {
                    let delay = Self.startupAutoConnectRetryDelaysNs[max(0, attempt - 1)]
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }

                do {
                    if let connectOverride = Self.hooks?.connectOverride {
                        try await connectOverride(provider.id)
                    } else {
                        try await connect(providerId: provider.id)
                    }
                    break
                } catch {
                    let storedHealthState = providerStates[provider.id]?.healthState ?? .unknownFailure
                    let inferredFailureClass = inferFailureClass(from: error.localizedDescription)
                    let inferredHealthState = mapHealthState(inferredFailureClass)
                    let healthState = storedHealthState == .unknownFailure ? inferredHealthState : storedHealthState
                    await emitDiagnostic(
                        level: .warning,
                        event: "remote.autoconnect.retry",
                        context: [
                            "providerId": provider.id.uuidString,
                            "providerName": provider.name,
                            "attempt": "\(attempt)",
                            "maxAttempts": "\(maxAttempts)",
                            "healthState": healthState.rawValue,
                            "error": error.localizedDescription,
                        ]
                    )

                    print(
                        "[Osaurus] Failed to auto-connect to '\(provider.name)' (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )

                    if isStartup,
                       shouldDisableStartupAutoConnect(provider: provider, healthState: healthState)
                    {
                        await disableAutoConnectForProvider(
                            provider,
                            reason: "misconfigured-openclaw-endpoint"
                        )
                        break
                    }

                    // Endpoint/config/auth failures should not loop noisily on startup.
                    if healthState == .misconfiguredEndpoint || healthState == .authFailed {
                        break
                    }

                    if attempt == maxAttempts {
                        break
                    }
                }
            }
        }
    }

    /// Disconnect from all providers
    public func disconnectAll() {
        for providerId in services.keys {
            disconnect(providerId: providerId)
        }
    }

    // MARK: - Service Access

    /// Get the service for a provider
    public func service(for providerId: UUID) -> RemoteProviderService? {
        return services[providerId]
    }

    /// Get all connected services
    public func connectedServices() -> [RemoteProviderService] {
        return Array(services.values)
    }

    /// Get all available models across all connected providers (with prefixes)
    public func allAvailableModels() -> [String] {
        cachedAvailableModels().flatMap(\.models)
    }

    /// Get all available models synchronously from cached state
    public func cachedAvailableModels() -> [(providerId: UUID, providerName: String, models: [String])] {
        var result: [(providerId: UUID, providerName: String, models: [String])] = []

        for provider in configuration.providers {
            if let state = providerStates[provider.id], state.isConnected {
                // Create prefixed model names
                let prefix = provider.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "/", with: "-")
                let prefixedModels = state.discoveredModels.map { "\(prefix)/\($0)" }
                result.append((providerId: provider.id, providerName: provider.name, models: prefixedModels))
            }
        }

        return result
    }

    /// Find the service that handles a given model
    public func findService(forModel model: String) -> RemoteProviderService? {
        for service in services.values {
            if service.handles(requestedModel: model) {
                return service
            }
        }
        return nil
    }

    // MARK: - Test Connection

    /// Test connection to a provider configuration without persisting
    public func testConnection(
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType = .openai,
        apiKey: String?,
        headers: [String: String]
    ) async throws -> [String] {
        // Build temporary provider for testing
        let tempProvider = RemoteProvider(
            name: "Test",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: authType,
            providerType: providerType,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )

        // Manually add API key to headers for test (since it's not in Keychain)
        var testHeaders = headers
        if authType == .apiKey, let apiKey = apiKey, !apiKey.isEmpty {
            switch providerType {
            case .anthropic:
                testHeaders["x-api-key"] = apiKey
                // Add required Anthropic version header if not already set
                if testHeaders["anthropic-version"] == nil {
                    testHeaders["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                testHeaders["x-goog-api-key"] = apiKey
            case .openai, .openResponses:
                testHeaders["Authorization"] = "Bearer \(apiKey)"
            }
        }
        var testProvider = tempProvider
        testProvider.customHeaders = testHeaders
        // Keep auth in explicit headers to avoid depending on Keychain during tests.
        testProvider.authType = .none

        await emitDiagnostic(
            level: .info,
            event: "remote.test.begin",
            context: [
                "host": host,
                "providerType": providerType.rawValue,
                "basePath": basePath,
            ]
        )

        do {
            let models = try await RemoteProviderService.fetchModels(from: testProvider)
            await emitDiagnostic(
                level: .info,
                event: "remote.test.success",
                context: [
                    "host": host,
                    "providerType": providerType.rawValue,
                    "modelCount": "\(models.count)",
                ]
            )
            return models
        } catch {
            let classified = classifyConnectionFailure(error, provider: testProvider)
            await emitDiagnostic(
                level: .error,
                event: "remote.test.failed",
                context: [
                    "host": host,
                    "providerType": providerType.rawValue,
                    "failureClass": classified.failureClass.rawValue,
                    "healthState": classified.healthState.rawValue,
                    "message": classified.message,
                    "fixIt": classified.fixIt ?? "",
                ]
            )
            throw RemoteProviderError.connectionFailed(classified.renderedMessage)
        }
    }

    // MARK: - Private Helpers

    private struct ClassifiedConnectionFailure {
        let failureClass: RemoteProviderFailureClass
        let healthState: ProviderHealthState
        let message: String
        let fixIt: String?

        var renderedMessage: String {
            guard let fixIt, !fixIt.isEmpty else { return message }
            if message.localizedCaseInsensitiveContains(fixIt) {
                return message
            }
            return "\(message) \(fixIt)"
        }
    }

    private func classifyConnectionFailure(_ error: Error, provider: RemoteProvider) -> ClassifiedConnectionFailure {
        if let serviceError = error as? RemoteProviderServiceError {
            switch serviceError {
            case .discoveryFailed(let details):
                return ClassifiedConnectionFailure(
                    failureClass: details.failureClass,
                    healthState: mapHealthState(details.failureClass),
                    message: details.message,
                    fixIt: details.fixIt
                )
            case .invalidURL:
                return ClassifiedConnectionFailure(
                    failureClass: .misconfiguredEndpoint,
                    healthState: .misconfiguredEndpoint,
                    message: "Invalid provider URL configuration.",
                    fixIt: "Correct the provider host/path so it points to a model API endpoint (for example /v1/models)."
                )
            case .requestFailed(let message):
                let inferred = inferFailureClass(from: message)
                return ClassifiedConnectionFailure(
                    failureClass: inferred,
                    healthState: mapHealthState(inferred),
                    message: message,
                    fixIt: defaultFixIt(for: inferred, provider: provider)
                )
            case .invalidResponse:
                return ClassifiedConnectionFailure(
                    failureClass: .invalidResponse,
                    healthState: .unknownFailure,
                    message: "Provider returned an invalid response.",
                    fixIt: "Verify the endpoint speaks the selected provider protocol and returns JSON."
                )
            case .streamingError(let message):
                let inferred = inferFailureClass(from: message)
                return ClassifiedConnectionFailure(
                    failureClass: inferred,
                    healthState: mapHealthState(inferred),
                    message: message,
                    fixIt: defaultFixIt(for: inferred, provider: provider)
                )
            case .noModelsAvailable:
                return ClassifiedConnectionFailure(
                    failureClass: .gatewayUnavailable,
                    healthState: .gatewayUnavailable,
                    message: "Connection succeeded but no models were discovered.",
                    fixIt: "Ensure the upstream provider is serving models and your API key has model-list access."
                )
            case .notConnected:
                return ClassifiedConnectionFailure(
                    failureClass: .gatewayUnavailable,
                    healthState: .gatewayUnavailable,
                    message: "Provider is not connected.",
                    fixIt: "Retry after confirming the provider endpoint is reachable."
                )
            }
        }

        if let managerError = error as? RemoteProviderError, case .connectionFailed(let message) = managerError {
            let inferred = inferFailureClass(from: message)
            return ClassifiedConnectionFailure(
                failureClass: inferred,
                healthState: mapHealthState(inferred),
                message: message,
                fixIt: defaultFixIt(for: inferred, provider: provider)
            )
        }

        let fallbackClass = inferFailureClass(from: error.localizedDescription)
        return ClassifiedConnectionFailure(
            failureClass: fallbackClass,
            healthState: mapHealthState(fallbackClass),
            message: error.localizedDescription,
            fixIt: defaultFixIt(for: fallbackClass, provider: provider)
        )
    }

    private func mapHealthState(_ failureClass: RemoteProviderFailureClass) -> ProviderHealthState {
        switch failureClass {
        case .misconfiguredEndpoint:
            return .misconfiguredEndpoint
        case .authFailed:
            return .authFailed
        case .gatewayUnavailable:
            return .gatewayUnavailable
        case .networkUnreachable:
            return .networkUnreachable
        case .invalidResponse, .unknown:
            return .unknownFailure
        }
    }

    private func inferFailureClass(from rawMessage: String) -> RemoteProviderFailureClass {
        let message = rawMessage.lowercased()
        if message.contains("html") || message.contains("non-json") || message.contains("endpoint mismatch")
            || message.contains("misconfigured")
        {
            return .misconfiguredEndpoint
        }
        if message.contains("unauthorized") || message.contains("forbidden") || message.contains("401")
            || message.contains("403") || message.contains("authentication")
        {
            return .authFailed
        }
        if message.contains("timed out") || message.contains("timeout")
            || message.contains("could not connect")
            || message.contains("network")
            || message.contains("dns")
            || message.contains("offline")
            || message.contains("connection refused")
        {
            return .networkUnreachable
        }
        if message.contains("bad gateway") || message.contains("unavailable") || message.contains("gateway")
            || message.contains("503")
            || message.contains("502")
        {
            return .gatewayUnavailable
        }
        return .unknown
    }

    private func defaultFixIt(for failureClass: RemoteProviderFailureClass, provider: RemoteProvider) -> String? {
        switch failureClass {
        case .misconfiguredEndpoint:
            if looksLikeOpenClawControlEndpoint(provider) {
                return
                    "This looks like an OpenClaw UI/control endpoint. Use the provider's model API base URL (for example .../v1) instead."
            }
            return "Check host/path and ensure it targets a model API endpoint that returns JSON."
        case .authFailed:
            return "Update API key/token and retry."
        case .gatewayUnavailable:
            return "Ensure the upstream service is running and retry."
        case .networkUnreachable:
            return "Verify DNS/network connectivity and endpoint reachability."
        case .invalidResponse, .unknown:
            return nil
        }
    }

    private func looksLikeOpenClawControlEndpoint(_ provider: RemoteProvider) -> Bool {
        guard let modelsURL = provider.url(for: "/models") else { return false }
        let host = modelsURL.host?.lowercased() ?? ""
        let path = modelsURL.path.lowercased()
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

        if localHosts.contains(host), modelsURL.port == 18789 {
            return true
        }

        let controlPath =
            path.hasPrefix("/health")
            || path.hasPrefix("/ws")
            || path.hasPrefix("/mcp")
            || path.hasPrefix("/channels")
            || path.hasPrefix("/system")
            || path.hasPrefix("/wizard")
            || path.hasPrefix("/dashboard")
            || path == "/models"
        return localHosts.contains(host) && controlPath
    }

    private func shouldDisableStartupAutoConnect(
        provider: RemoteProvider,
        healthState: ProviderHealthState
    ) -> Bool {
        healthState == .misconfiguredEndpoint && looksLikeOpenClawControlEndpoint(provider)
    }

    private func disableAutoConnectForProvider(_ provider: RemoteProvider, reason: String) async {
        guard var updated = configuration.provider(id: provider.id), updated.autoConnect else { return }
        updated.autoConnect = false
        configuration.update(updated)
        RemoteProviderConfigurationStore.save(configuration)
        await emitDiagnostic(
            level: .warning,
            event: "remote.autoconnect.disabled",
            context: [
                "providerId": provider.id.uuidString,
                "providerName": provider.name,
                "reason": reason,
            ]
        )
        print("[Osaurus] Remote Provider '\(provider.name)': Auto-connect disabled (\(reason)).")
    }

    private func emitDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "remote-provider-manager",
            event: event,
            context: context
        )
    }

#if DEBUG
    static func _testSetHooks(_ hooks: Hooks?) {
        self.hooks = hooks
    }

    static func _testSetStartupRetryDelaysNs(_ delays: [UInt64]?) {
        startupAutoConnectRetryDelaysOverrideNs = delays
    }

    func _testSetConfiguration(_ configuration: RemoteProviderConfiguration) {
        self.configuration = configuration
        var states: [UUID: RemoteProviderState] = [:]
        for provider in configuration.providers {
            states[provider.id] = providerStates[provider.id] ?? RemoteProviderState(providerId: provider.id)
        }
        self.providerStates = states
        self.services.removeAll()
    }

    func _testSetProviderState(_ state: RemoteProviderState, for providerId: UUID) {
        providerStates[providerId] = state
    }
#endif

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: .remoteProviderStatusChanged, object: nil)
    }

    private func notifyModelsChanged() {
        NotificationCenter.default.post(name: .remoteProviderModelsChanged, object: nil)
    }
}

// MARK: - OpenAI Models Integration

extension RemoteProviderManager {
    /// Get OpenAI-compatible model objects for all connected providers
    func getOpenAIModels() -> [OpenAIModel] {
        var models: [OpenAIModel] = []

        for provider in configuration.providers {
            guard let state = providerStates[provider.id], state.isConnected else {
                continue
            }

            let prefix = provider.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "/", with: "-")

            for modelId in state.discoveredModels {
                let prefixedId = "\(prefix)/\(modelId)"
                var model = OpenAIModel(modelName: prefixedId)
                model.owned_by = provider.name
                models.append(model)
            }
        }

        return models
    }
}
