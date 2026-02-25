//
//  MCPProviderManager.swift
//  osaurus
//
//  Manages remote MCP provider connections and tool execution.
//

import Foundation
import MCP

/// Notification posted when provider connection status changes
extension Foundation.Notification.Name {
    static let mcpProviderStatusChanged = Foundation.Notification.Name("MCPProviderStatusChanged")
}

/// Manages all remote MCP provider connections
@MainActor
public final class MCPProviderManager: ObservableObject {
    public static let shared = MCPProviderManager()

    struct Hooks {
        var connectOverride: (@Sendable (_ providerId: UUID) async throws -> Void)?
    }

    nonisolated(unsafe) static var hooks: Hooks?
    nonisolated(unsafe) static var startupAutoConnectRetryDelaysOverrideNs: [UInt64]?

    /// Current configuration
    @Published public private(set) var configuration: MCPProviderConfiguration

    /// Runtime state for each provider
    @Published public private(set) var providerStates: [UUID: MCPProviderState] = [:]

    /// Active MCP clients keyed by provider ID
    private var clients: [UUID: MCP.Client] = [:]

    /// Discovered MCP tools keyed by provider ID
    private var discoveredTools: [UUID: [MCP.Tool]] = [:]

    /// Registered tool instances keyed by provider ID
    private var registeredTools: [UUID: [MCPProviderTool]] = [:]
    private static var startupAutoConnectRetryDelaysNs: [UInt64] {
        startupAutoConnectRetryDelaysOverrideNs ?? [0, 500_000_000, 1_500_000_000]
    }

    private init() {
        self.configuration = MCPProviderConfigurationStore.load()

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = MCPProviderState(providerId: provider.id)
        }
    }

    // MARK: - Provider Management

    /// Add a new provider
    public func addProvider(_ provider: MCPProvider, token: String?) {
        configuration.add(provider)
        MCPProviderConfigurationStore.save(configuration)

        // Save token to Keychain if provided
        if let token = token, !token.isEmpty {
            MCPProviderKeychain.saveToken(token, for: provider.id)
        }

        // Initialize state
        providerStates[provider.id] = MCPProviderState(providerId: provider.id)

        // Auto-connect if enabled
        if provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
    }

    /// Update an existing provider
    public func updateProvider(_ provider: MCPProvider, token: String?) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        configuration.update(provider)
        MCPProviderConfigurationStore.save(configuration)

        // Update token if provided (empty string means clear token)
        if let token = token {
            if token.isEmpty {
                MCPProviderKeychain.deleteToken(for: provider.id)
            } else {
                MCPProviderKeychain.saveToken(token, for: provider.id)
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
        MCPProviderConfigurationStore.save(configuration)

        // Clean up state
        providerStates.removeValue(forKey: id)

        notifyStatusChanged()
    }

    /// Set enabled state for a provider
    /// When enabled is true, automatically connects to the provider
    /// When enabled is false, disconnects from the provider
    public func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        MCPProviderConfigurationStore.save(configuration)

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

    /// Connect to a provider
    public func connect(providerId: UUID) async throws {
        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        guard provider.enabled else {
            throw MCPProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
        state.healthState = .unknownFailure
        state.healthFixIt = nil
        providerStates[providerId] = state

        await emitDiagnostic(
            level: .info,
            event: "mcp.connect.begin",
            context: [
                "providerId": provider.id.uuidString,
                "providerName": provider.name,
                "url": provider.url,
                "streaming": "\(provider.streamingEnabled)",
            ]
        )

        do {
            // Create authenticated transport
            let transport = try createTransport(for: provider)

            // Create MCP client
            let client = MCP.Client(
                name: "Osaurus",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            )

            // Connect
            _ = try await client.connect(transport: transport)

            // Store client
            clients[providerId] = client

            // Discover tools
            try await discoverTools(for: providerId, client: client, provider: provider)

            // Update state to connected (re-read state since discoverTools modified it)
            if var updatedState = providerStates[providerId] {
                updatedState.isConnecting = false
                updatedState.isConnected = true
                updatedState.lastConnectedAt = Date()
                updatedState.lastError = nil
                updatedState.healthState = .ready
                updatedState.healthFixIt = nil
                providerStates[providerId] = updatedState
                print(
                    "[Osaurus] MCP Provider '\(provider.name)': Connected with \(updatedState.discoveredToolCount) tools"
                )
                await emitDiagnostic(
                    level: .info,
                    event: "mcp.connect.success",
                    context: [
                        "providerId": provider.id.uuidString,
                        "providerName": provider.name,
                        "toolCount": "\(updatedState.discoveredToolCount)",
                    ]
                )
            }
            notifyStatusChanged()

        } catch {
            let classified = classifyConnectionFailure(error, provider: provider)

            // Update state with error - reset tool discovery state to match disconnect behavior
            state.isConnecting = false
            state.isConnected = false
            state.lastError = classified.message
            state.healthState = classified.healthState
            state.healthFixIt = classified.fixIt
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            providerStates[providerId] = state

            // Clean up (same as disconnect)
            clients.removeValue(forKey: providerId)
            discoveredTools.removeValue(forKey: providerId)
            registeredTools.removeValue(forKey: providerId)

            print("[Osaurus] MCP Provider '\(provider.name)': Connection failed - \(classified.message)")
            await emitDiagnostic(
                level: .error,
                event: "mcp.connect.failed",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "failureClass": classified.failureClass,
                    "healthState": classified.healthState.rawValue,
                    "message": classified.message,
                    "fixIt": classified.fixIt ?? "",
                ]
            )
            notifyStatusChanged()
            throw MCPProviderError.connectionFailed(classified.renderedMessage)
        }
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
        // Unregister tools
        if let tools = registeredTools[providerId] {
            let toolNames = tools.map { $0.name }
            ToolRegistry.shared.unregister(names: toolNames)
        }

        // Clean up
        clients.removeValue(forKey: providerId)
        discoveredTools.removeValue(forKey: providerId)
        registeredTools.removeValue(forKey: providerId)

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.lastError = nil
            state.healthState = .unknownFailure
            state.healthFixIt = nil
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            providerStates[providerId] = state
        }

        if let provider = configuration.provider(id: providerId) {
            print("[Osaurus] MCP Provider '\(provider.name)': Disconnected")
        }

        notifyStatusChanged()
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
                    event: "mcp.autoconnect.skipped",
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
                    event: "mcp.autoconnect.skipped",
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
                    let inferred = inferFailureClass(from: error.localizedDescription)
                    let healthState = storedHealthState == .unknownFailure ? inferred.healthState : storedHealthState
                    await emitDiagnostic(
                        level: .warning,
                        event: "mcp.autoconnect.retry",
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
        for providerId in clients.keys {
            disconnect(providerId: providerId)
        }
    }

    // MARK: - Tool Execution

    /// Execute a tool on a provider
    public func executeTool(providerId: UUID, toolName: String, argumentsJSON: String) async throws -> String {
        guard let client = clients[providerId] else {
            throw MCPProviderError.notConnected
        }

        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        let arguments = try MCPProviderTool.convertArgumentsToMCPValues(argumentsJSON)
        let timeout = provider.toolCallTimeout

        // Run the network call off MainActor so it doesn't block the UI thread.
        let (content, isError) = try await Self.callMCPTool(
            client: client,
            toolName: toolName,
            arguments: arguments,
            timeout: timeout
        )

        // Check for error
        if let isError = isError, isError {
            let errorText = content.compactMap { item -> String? in
                if case .text(let text) = item { return text }
                return nil
            }.joined(separator: "\n")
            throw MCPProviderError.toolExecutionFailed(errorText.isEmpty ? "Tool returned error" : errorText)
        }

        // Convert content to string
        return MCPProviderTool.convertMCPContent(content)
    }

    /// Trampoline that runs the MCP network call outside MainActor isolation.
    private nonisolated static func callMCPTool(
        client: MCP.Client,
        toolName: String,
        arguments: [String: MCP.Value],
        timeout: TimeInterval
    ) async throws -> ([MCP.Tool.Content], Bool?) {
        try await withThrowingTaskGroup(of: ([MCP.Tool.Content], Bool?).self) { group in
            group.addTask {
                try await client.callTool(name: toolName, arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPProviderError.timeout
            }
            guard let result = try await group.next() else {
                throw MCPProviderError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Test Connection

    /// Test connection to a provider without persisting
    public func testConnection(url: String, token: String?, headers: [String: String]) async throws -> Int {
        guard let endpoint = URL(string: url) else {
            throw MCPProviderError.invalidURL
        }
        if let sanityIssue = openClawMCPEndpointSanityIssue(for: endpoint) {
            throw MCPProviderError.endpointMismatch(sanityIssue)
        }

        await emitDiagnostic(
            level: .info,
            event: "mcp.test.begin",
            context: ["url": url]
        )

        // Create temporary transport
        let configuration = URLSessionConfiguration.default
        var allHeaders: [String: String] = headers
        if let token = token, !token.isEmpty {
            allHeaders["Authorization"] = "Bearer \(token)"
        }
        if !allHeaders.isEmpty {
            configuration.httpAdditionalHeaders = allHeaders
        }
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20

        let transport = HTTPClientTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false
        )

        let client = MCP.Client(
            name: "Osaurus",
            version: "1.0.0"
        )

        // Connect
        do {
            _ = try await client.connect(transport: transport)

            // List tools to verify connection
            let (tools, _) = try await client.listTools()
            await emitDiagnostic(
                level: .info,
                event: "mcp.test.success",
                context: [
                    "url": url,
                    "toolCount": "\(tools.count)",
                ]
            )
            return tools.count
        } catch {
            let classified = classifyConnectionFailure(
                error,
                provider: MCPProvider(name: "Test", url: url, enabled: true, customHeaders: headers)
            )
            await emitDiagnostic(
                level: .error,
                event: "mcp.test.failed",
                context: [
                    "url": url,
                    "failureClass": classified.failureClass,
                    "healthState": classified.healthState.rawValue,
                    "message": classified.message,
                    "fixIt": classified.fixIt ?? "",
                ]
            )
            throw MCPProviderError.connectionFailed(classified.renderedMessage)
        }
    }

    // MARK: - Private Helpers

    private func createTransport(for provider: MCPProvider) throws -> HTTPClientTransport {
        guard let endpoint = URL(string: provider.url) else {
            throw MCPProviderError.invalidURL
        }
        if let sanityIssue = openClawMCPEndpointSanityIssue(for: endpoint) {
            throw MCPProviderError.endpointMismatch(sanityIssue)
        }

        let urlConfig = URLSessionConfiguration.default

        // Build headers
        var headers = provider.resolvedHeaders()
        if let token = provider.getToken(), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        if !headers.isEmpty {
            urlConfig.httpAdditionalHeaders = headers
        }

        urlConfig.timeoutIntervalForRequest = provider.discoveryTimeout
        urlConfig.timeoutIntervalForResource = max(provider.discoveryTimeout, provider.toolCallTimeout)

        return HTTPClientTransport(
            endpoint: endpoint,
            configuration: urlConfig,
            streaming: provider.streamingEnabled
        )
    }

    private func discoverTools(for providerId: UUID, client: MCP.Client, provider: MCPProvider) async throws {
        // List tools with timeout
        let (mcpTools, _) = try await withTimeout(seconds: provider.discoveryTimeout) {
            try await client.listTools()
        }

        // Store discovered tools
        discoveredTools[providerId] = mcpTools

        // Create and register tool wrappers
        var tools: [MCPProviderTool] = []
        for mcpTool in mcpTools {
            let tool = MCPProviderTool(
                mcpTool: mcpTool,
                providerId: providerId,
                providerName: provider.name
            )
            tools.append(tool)
            ToolRegistry.shared.register(tool)
        }
        registeredTools[providerId] = tools

        // Update state
        if var state = providerStates[providerId] {
            state.discoveredToolCount = tools.count
            state.discoveredToolNames = tools.map { $0.mcpToolName }
            providerStates[providerId] = state
        }

        // Notify tools list changed
        await MCPServerManager.shared.notifyToolsListChanged()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPProviderError.timeout
            }

            guard let result = try await group.next() else {
                throw MCPProviderError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private struct ClassifiedConnectionFailure {
        let failureClass: String
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

    private func classifyConnectionFailure(_ error: Error, provider: MCPProvider) -> ClassifiedConnectionFailure {
        if let typed = error as? MCPProviderError {
            switch typed {
            case .endpointMismatch(let message):
                return ClassifiedConnectionFailure(
                    failureClass: "misconfigured-endpoint",
                    healthState: .misconfiguredEndpoint,
                    message: message,
                    fixIt:
                        "Use an MCP transport endpoint (for example /mcp or /sse), not OpenClaw UI/control routes like /health or /ws."
                )
            case .invalidURL:
                return ClassifiedConnectionFailure(
                    failureClass: "misconfigured-endpoint",
                    healthState: .misconfiguredEndpoint,
                    message: "Invalid MCP provider URL.",
                    fixIt: "Correct the URL and retry."
                )
            case .timeout:
                return ClassifiedConnectionFailure(
                    failureClass: "network-unreachable",
                    healthState: .networkUnreachable,
                    message: "MCP request timed out while connecting to \(provider.url).",
                    fixIt: "Check endpoint reachability and discovery timeout settings."
                )
            case .connectionFailed(let message):
                let inferred = inferFailureClass(from: message)
                return ClassifiedConnectionFailure(
                    failureClass: inferred.failureClass,
                    healthState: inferred.healthState,
                    message: message,
                    fixIt: inferred.fixIt
                )
            default:
                break
            }
        }

        let inferred = inferFailureClass(from: error.localizedDescription)
        return ClassifiedConnectionFailure(
            failureClass: inferred.failureClass,
            healthState: inferred.healthState,
            message: error.localizedDescription,
            fixIt: inferred.fixIt
        )
    }

    private func inferFailureClass(from rawMessage: String) -> (
        failureClass: String,
        healthState: ProviderHealthState,
        fixIt: String?
    ) {
        let message = rawMessage.lowercased()
        if message.contains("method not allowed") || message.contains("405")
            || message.contains("unsupported protocol")
        {
            return (
                "misconfigured-endpoint",
                .misconfiguredEndpoint,
                "Endpoint/protocol mismatch: configure the provider URL to an MCP endpoint (SSE/HTTP) instead of a control/UI route."
            )
        }
        if message.contains("unauthorized") || message.contains("forbidden")
            || message.contains("401") || message.contains("403")
            || message.contains("authentication")
        {
            return ("auth-failed", .authFailed, "Update token/headers and retry.")
        }
        if message.contains("network") || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("connection refused")
            || message.contains("could not connect")
            || message.contains("dns")
        {
            return ("network-unreachable", .networkUnreachable, "Check network reachability and endpoint host/port.")
        }
        if message.contains("unavailable") || message.contains("bad gateway")
            || message.contains("502")
            || message.contains("503")
        {
            return ("gateway-unavailable", .gatewayUnavailable, "Ensure the MCP gateway/server is running and retry.")
        }
        return ("unknown", .unknownFailure, nil)
    }

    private func openClawMCPEndpointSanityIssue(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let isOpenClawLocalGateway = localHosts.contains(host) && (url.port == 18789)
        let knownBadControlRoutes =
            path.hasPrefix("/health")
            || path.hasPrefix("/ws")
            || path.hasPrefix("/mcp")
            || path.hasPrefix("/dashboard")
            || path.hasPrefix("/channels")
            || path.hasPrefix("/system")
            || path.hasPrefix("/wizard")

        if isOpenClawLocalGateway && knownBadControlRoutes {
            return
                "Configured URL '\(url.absoluteString)' points to an OpenClaw control route. Use an MCP transport endpoint instead."
        }

        if isOpenClawLocalGateway, (path.isEmpty || path == "/" || path == "/models") {
            return
                "Configured URL '\(url.absoluteString)' looks like OpenClaw gateway root, not an MCP endpoint. Configure the mcporter MCP URL instead."
        }

        return nil
    }

    private func shouldDisableStartupAutoConnect(
        provider: MCPProvider,
        healthState: ProviderHealthState
    ) -> Bool {
        guard healthState == .misconfiguredEndpoint else { return false }
        guard let url = URL(string: provider.url) else { return false }
        return openClawMCPEndpointSanityIssue(for: url) != nil
    }

    private func disableAutoConnectForProvider(_ provider: MCPProvider, reason: String) async {
        guard var updated = configuration.provider(id: provider.id), updated.autoConnect else { return }
        updated.autoConnect = false
        configuration.update(updated)
        MCPProviderConfigurationStore.save(configuration)
        await emitDiagnostic(
            level: .warning,
            event: "mcp.autoconnect.disabled",
            context: [
                "providerId": provider.id.uuidString,
                "providerName": provider.name,
                "reason": reason,
            ]
        )
        print("[Osaurus] MCP Provider '\(provider.name)': Auto-connect disabled (\(reason)).")
    }

    private func emitDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "mcp-provider-manager",
            event: event,
            context: context
        )
    }

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: Foundation.Notification.Name.mcpProviderStatusChanged, object: nil)
    }

#if DEBUG
    static func _testSetHooks(_ hooks: Hooks?) {
        self.hooks = hooks
    }

    static func _testSetStartupRetryDelaysNs(_ delays: [UInt64]?) {
        startupAutoConnectRetryDelaysOverrideNs = delays
    }

    func _testSetConfiguration(_ configuration: MCPProviderConfiguration) {
        self.configuration = configuration
        var states: [UUID: MCPProviderState] = [:]
        for provider in configuration.providers {
            states[provider.id] = providerStates[provider.id] ?? MCPProviderState(providerId: provider.id)
        }
        self.providerStates = states
        self.clients.removeAll()
        self.discoveredTools.removeAll()
        self.registeredTools.removeAll()
    }

    func _testSetProviderState(_ state: MCPProviderState, for providerId: UUID) {
        providerStates[providerId] = state
    }

    func _testInferFailureClass(from rawMessage: String) -> (
        failureClass: String,
        healthState: ProviderHealthState,
        fixIt: String?
    ) {
        inferFailureClass(from: rawMessage)
    }

    func _testOpenClawMCPEndpointSanityIssue(url: URL) -> String? {
        openClawMCPEndpointSanityIssue(for: url)
    }
#endif
}

// MARK: - Errors

public enum MCPProviderError: LocalizedError {
    case providerNotFound
    case providerDisabled
    case notConnected
    case invalidURL
    case endpointMismatch(String)
    case timeout
    case toolExecutionFailed(String)
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
        case .endpointMismatch(let message):
            return "Endpoint mismatch: \(message)"
        case .timeout:
            return "Request timed out"
        case .toolExecutionFailed(let message):
            return "Tool execution failed: \(message)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        }
    }
}
