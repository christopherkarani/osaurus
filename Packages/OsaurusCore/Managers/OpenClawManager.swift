//
//  OpenClawManager.swift
//  osaurus
//

import Combine
import Foundation
import OpenClawKit
import OpenClawProtocol
import Terra

extension Foundation.Notification.Name {
    static let openClawGatewayStatusChanged = Foundation.Notification.Name("openClawGatewayStatusChanged")
    static let openClawModelsChanged = Foundation.Notification.Name("openClawModelsChanged")
    static let openClawConnectionChanged = Foundation.Notification.Name("openClawConnectionChanged")
}

public enum OpenClawPhase: Equatable, Sendable {
    case notConfigured
    case checkingEnvironment
    case environmentBlocked(OpenClawEnvironmentStatus)
    case installingCLI
    case configured
    case startingGateway
    case gatewayRunning
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case gatewayFailed(String)
    case connectionFailed(String)
}

public struct OpenClawGatewayHealth: Equatable, Sendable {
    public let uptime: TimeInterval
    public let memoryMB: Double
    public let activeRuns: Int
    public let version: String
    public let pid: Int?
    public let timestamp: Date

    public init(
        uptime: TimeInterval,
        memoryMB: Double,
        activeRuns: Int,
        version: String,
        pid: Int?,
        timestamp: Date
    ) {
        self.uptime = uptime
        self.memoryMB = memoryMB
        self.activeRuns = activeRuns
        self.version = version
        self.pid = pid
        self.timestamp = timestamp
    }
}

public enum ProviderDiscoveryError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case invalidResponse
    case requestTimeout(String)
    case unreachable(String)
    case httpFailure(statusCode: Int, detail: String?)
    case malformedPayload
    case noModelsFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "Invalid provider URL: \(raw)"
        case .invalidResponse:
            return "Provider returned an invalid /models response."
        case .requestTimeout(let endpoint):
            return "Timed out while requesting \(endpoint). Start the provider and retry."
        case .unreachable(let endpoint):
            return "Could not reach \(endpoint). Check the URL/network and retry."
        case .httpFailure(let statusCode, let detail):
            guard let detail, !detail.isEmpty else {
                return "Provider /models request failed with status \(statusCode)."
            }
            return "Provider /models request failed with status \(statusCode). \(detail)"
        case .malformedPayload:
            return "Provider /models payload is malformed or unsupported."
        case .noModelsFound(let endpoint):
            return "No models were discovered at \(endpoint). Start Osaurus local server and retry."
        }
    }
}

public enum ProviderReadinessReason: String, Sendable, Equatable {
    case ready = "ready"
    case noKey = "no-key"
    case unreachable = "unreachable"
    case noModels = "no-models"
    case invalidConfig = "invalid-config"

    public var isReady: Bool {
        self == .ready
    }

    public var shortLabel: String {
        switch self {
        case .ready:
            return "Ready"
        case .noKey:
            return "No API key"
        case .unreachable:
            return "Unreachable"
        case .noModels:
            return "No models"
        case .invalidConfig:
            return "Invalid config"
        }
    }
}

@MainActor
public final class OpenClawManager: ObservableObject {
    typealias GatewayPayload = [String: OpenClawProtocol.AnyCodable]
    typealias ToastEventSink = @MainActor (ToastEvent) -> Void

    public struct ProviderSeedModel: Sendable, Equatable {
        public let id: String
        public let name: String
        public let reasoning: Bool
        public let contextWindow: Int?
        public let maxTokens: Int?

        public init(
            id: String,
            name: String,
            reasoning: Bool = false,
            contextWindow: Int? = nil,
            maxTokens: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.reasoning = reasoning
            self.contextWindow = contextWindow
            self.maxTokens = maxTokens
        }

        fileprivate var configPatchObject: [String: Any] {
            var obj: [String: Any] = [
                "id": id,
                "name": name,
                "reasoning": reasoning
            ]
            if let contextWindow {
                obj["contextWindow"] = contextWindow
            }
            if let maxTokens {
                obj["maxTokens"] = maxTokens
            }
            return obj
        }
    }

    struct GatewayHooks {
        var channelsStatus: @Sendable () async throws -> [GatewayPayload]
        var channelsStatusDetailed: (@Sendable () async throws -> ChannelsStatusResult)? = nil
        var channelsLogout: (@Sendable (_ channelId: String, _ accountId: String?) async throws -> Void)? = nil
        var modelsList: @Sendable () async throws -> [OpenClawProtocol.ModelChoice]
        var health: @Sendable () async throws -> GatewayPayload
        /// Injected in tests to replace the `OpenClawGatewayConnection.shared.connect(...)` call
        /// inside `pollHealth`'s reconnect path.
        var gatewayConnect: (@Sendable () async throws -> Void)? = nil
        var heartbeatStatus: (@Sendable () async throws -> OpenClawHeartbeatStatus)?
        var setHeartbeats: (@Sendable (Bool) async throws -> Void)?
        var cronStatus: (@Sendable () async throws -> OpenClawCronStatus)? = nil
        var cronList: (@Sendable () async throws -> [OpenClawCronJob])? = nil
        var cronRuns: (@Sendable (_ jobId: String, _ limit: Int) async throws -> [OpenClawCronRunLogEntry])? = nil
        var cronRun: (@Sendable (_ jobId: String) async throws -> Void)? = nil
        var cronSetEnabled: (@Sendable (_ jobId: String, _ enabled: Bool) async throws -> Void)? = nil
        var agentsList: (@Sendable () async throws -> OpenClawGatewayAgentsListResponse)? = nil
        var agentsFilesList: (@Sendable (_ agentId: String) async throws -> OpenClawAgentFilesListResponse)? = nil
        var agentsFileGet: (@Sendable (_ agentId: String, _ name: String) async throws -> OpenClawAgentFileGetResponse)?
            = nil
        var agentsFileSet: (@Sendable (
            _ agentId: String,
            _ name: String,
            _ content: String
        ) async throws -> OpenClawAgentFileSetResponse)? = nil
        var skillsStatus: (@Sendable () async throws -> OpenClawSkillStatusReport)? = nil
        var skillsBins: (@Sendable () async throws -> [String])? = nil
        var skillsInstall: (@Sendable (_ name: String, _ installId: String, _ timeoutMs: Int?) async throws -> OpenClawSkillInstallResult)? = nil
        var skillsUpdate: (@Sendable (_ skillKey: String, _ enabled: Bool?) async throws -> OpenClawSkillUpdateResult)? = nil
        var skillsUpdateDetailed: (@Sendable (
            _ skillKey: String,
            _ enabled: Bool?,
            _ apiKey: String?,
            _ env: [String: String]?
        ) async throws -> OpenClawSkillUpdateResult)? = nil
        var systemPresence: (@Sendable () async throws -> [OpenClawPresenceEntry])? = nil
        var configGetFull: (@Sendable () async throws -> ConfigGetResult)? = nil
        var configPatch: (@Sendable (_ raw: String, _ baseHash: String) async throws -> ConfigPatchResult)? = nil
        var discoverProviderModels: (@Sendable (_ baseUrl: String, _ apiKey: String?) async throws -> [ProviderSeedModel])? = nil
        var osaurusLocalHealthCheck: (@Sendable () async -> Bool)? = nil
        var osaurusLocalStart: (@Sendable () async -> Void)? = nil
    }

    nonisolated(unsafe) static var gatewayHooks: GatewayHooks?
#if DEBUG
    nonisolated(unsafe) static var localTokenSyncHook: (@Sendable (_ clearSDKDeviceToken: Bool) -> Bool)?
    nonisolated(unsafe) static var authFailureToastDelayNanosecondsOverride: UInt64?
    nonisolated(unsafe) static var reconnectToastDelayNanosecondsOverride: UInt64?
#endif

    public enum GatewayStatus: Equatable, Sendable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
    }

    public enum OnboardingState: Equatable, Sendable {
        case unknown
        case checking
        case required
        case notRequired
        case failed(String)
    }

    public enum ToastEvent: Equatable, Sendable {
        case started
        case connected
        case disconnected
        case failed(String)
        case reconnecting(attempt: Int)
        case reconnected
        case cliInstallSuccess
    }

    public struct ChannelInfo: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let systemImage: String
        public let isLinked: Bool
        public let isConnected: Bool

        public init(id: String, name: String, systemImage: String, isLinked: Bool, isConnected: Bool) {
            self.id = id
            self.name = name
            self.systemImage = systemImage
            self.isLinked = isLinked
            self.isConnected = isConnected
        }
    }

    public struct ProviderInfo: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let modelCount: Int
        public let hasApiKey: Bool
        public let needsKey: Bool
        public let readinessReason: ProviderReadinessReason

        public var isReady: Bool { readinessReason.isReady }

        public init(
            id: String,
            name: String,
            modelCount: Int,
            hasApiKey: Bool = true,
            needsKey: Bool = true,
            readinessReason: ProviderReadinessReason? = nil
        ) {
            self.id = id
            self.name = name
            self.modelCount = modelCount
            self.hasApiKey = hasApiKey
            self.needsKey = needsKey
            if let readinessReason {
                self.readinessReason = readinessReason
            } else {
                self.readinessReason = (needsKey && !hasApiKey) ? .noKey : .ready
            }
        }
    }

    public struct MCPBridgeSyncErrorState: Sendable, Equatable {
        public enum Code: String, Sendable, Equatable {
            case notConnected = "not-connected"
            case syncInProgress = "sync-in-progress"
            case bridgeWriteFailed = "bridge-write-failed"
            case mcporterInstallFailed = "mcporter-install-failed"
            case mcporterUpdateFailed = "mcporter-update-failed"
            case automaticSyncSkipped = "automatic-sync-skipped"
        }

        public let code: Code
        public let message: String
        public let retryable: Bool
        public let mode: OpenClawMCPBridgeSyncMode?

        public init(
            code: Code,
            message: String,
            retryable: Bool,
            mode: OpenClawMCPBridgeSyncMode?
        ) {
            self.code = code
            self.message = message
            self.retryable = retryable
            self.mode = mode
        }
    }

    public enum ActiveSessionStatus: Equatable, Sendable {
        case thinking
        case usingTool(String)
        case responding
    }

    public struct ActiveSessionUsage: Equatable, Sendable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let totalTokens: Int?

        public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public struct ActiveSessionInfo: Identifiable, Sendable, Equatable {
        public let id: String
        public let key: String
        public let title: String
        public let model: String?
        public let status: ActiveSessionStatus
        public let usage: ActiveSessionUsage?
        public let updatedAt: Date

        public init(
            key: String,
            title: String,
            model: String?,
            status: ActiveSessionStatus,
            usage: ActiveSessionUsage?,
            updatedAt: Date
        ) {
            self.id = key
            self.key = key
            self.title = title
            self.model = model
            self.status = status
            self.usage = usage
            self.updatedAt = updatedAt
        }
    }

    public static let shared = OpenClawManager()

    @Published public private(set) var configuration: OpenClawConfiguration
    @Published public private(set) var phase: OpenClawPhase
    @Published public private(set) var gatewayStatus: GatewayStatus = .stopped
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var heartbeatEnabled: Bool = true
    @Published public private(set) var heartbeatLastTimestamp: Date?
    @Published public private(set) var environmentStatus: OpenClawEnvironmentStatus = .checking
    @Published public private(set) var channels: [ChannelInfo] = []
    @Published public private(set) var channelStatus: ChannelsStatusResult?
    @Published public private(set) var availableModels: [OpenClawProtocol.ModelChoice] = []
    @Published public private(set) var configuredProviders: [ProviderInfo] = []
    @Published public private(set) var cronStatus: OpenClawCronStatus?
    @Published public private(set) var cronJobs: [OpenClawCronJob] = []
    @Published public private(set) var cronRunsByJobID: [String: [OpenClawCronRunLogEntry]] = [:]
    @Published public private(set) var skillsAgents: [OpenClawGatewayAgentSummary] = []
    @Published public private(set) var selectedSkillsAgentId: String?
    @Published public private(set) var skillsReport: OpenClawSkillStatusReport?
    @Published public private(set) var skillsBins: [String] = []
    @Published public private(set) var connectedClients: [OpenClawPresenceEntry] = []
    @Published public private(set) var activeSessions: [ActiveSessionInfo] = []
    @Published public private(set) var lastHealth: OpenClawGatewayHealth?
    @Published public private(set) var lastError: String?
    @Published public private(set) var onboardingState: OnboardingState = .unknown
    @Published public private(set) var mcpBridgeIsSyncing = false
    @Published public private(set) var mcpBridgeLastSyncResult: OpenClawMCPBridgeSyncResult?
    @Published public private(set) var mcpBridgeLastSyncError: String?
    @Published public private(set) var mcpBridgeLastSyncMode: OpenClawMCPBridgeSyncMode?
    @Published public private(set) var mcpBridgeLastSyncErrorState: MCPBridgeSyncErrorState?

    public let activityStore = OpenClawActivityStore()

    private var healthMonitorTask: Task<Void, Never>?
    private var mcpBridgeAutoSyncTask: Task<Void, Never>?
    private var gatewayEventRefreshTask: Task<Void, Never>?
    private var pendingAuthFailureToastTask: Task<Void, Never>?
    private var pendingAuthFailureToastMessage: String?
    private var pendingReconnectToastTask: Task<Void, Never>?
    private var pendingReconnectToastAttempt: Int?
    private var reconnectToastShownForCurrentCycle = false
    private var trackedPID: Int?
    private var eventListenerID: UUID?
    private var runToSessionKey: [String: String] = [:]
    private var gatewayConnectionListenerID: UUID?
    private var providerReadinessOverrides: [String: ProviderReadinessReason] = [:]
    private var lastManualMCPBridgeEnableSkill = true
    private var lastManualMCPBridgeProviderEntries: [OpenClawMCPBridge.ProviderEntry]?
    private var lastManualMCPBridgeOutputURL: URL?
    private var mcpProviderStatusObserver: NSObjectProtocol?
    private var consecutiveHealthFailures = 0
    private var lastHealthFailureAt: Date?
    private var lastObservedGatewayConnectionState: OpenClawGatewayConnectionState?
    private var heartbeatStatusMethodUnsupported = false
    private var skillsBinsRoleUnauthorized = false
    private let notificationService = OpenClawNotificationService.shared
    private static let healthFailureThreshold = 3
    private static let healthFailureWindowSeconds: TimeInterval = 90
    private static let mcpBridgeAutoSyncDebounceNanoseconds: UInt64 = 750_000_000
    private static let authFailureToastDelayNanoseconds: UInt64 = 1_200_000_000
    private static let reconnectToastDelayNanoseconds: UInt64 = 2_500_000_000
    private static let providerConfigPatchRetryAttempts = 3
    private static let providerConfigPatchRetryDelayNanoseconds: UInt64 = 150_000_000
    private static let osaurusLocalServerBootstrapAttempts = 4
    private static let osaurusLocalServerBootstrapDelayNanoseconds: UInt64 = 350_000_000
    private static let kimiCodingCanonicalBaseURL = "https://api.kimi.com/coding"
    private static let kimiCodingLegacyPaths: Set<String> = ["/anthropic", "/anthropic/"]
    private static func emitDefaultToastEvent(_ event: ToastEvent) {
        switch event {
        case .started:
            ToastManager.shared.success("OpenClaw gateway started")
        case .connected:
            ToastManager.shared.success("OpenClaw connected")
        case .disconnected:
            ToastManager.shared.warning("OpenClaw disconnected")
        case .failed(let message):
            ToastManager.shared.error("OpenClaw failed", message: message)
        case .reconnecting(let attempt):
            ToastManager.shared.info("OpenClaw reconnecting...", message: "Attempt \(attempt)")
        case .reconnected:
            ToastManager.shared.success("OpenClaw reconnected")
        case .cliInstallSuccess:
            ToastManager.shared.success("OpenClaw CLI installed successfully")
        }
    }

    private var toastEventSink: ToastEventSink = OpenClawManager.emitDefaultToastEvent

    public var isConnected: Bool {
        connectionState == .connected
    }

    public var isOperational: Bool {
        phase == .connected
    }

    public var usesCustomGatewayEndpoint: Bool {
        hasCustomGatewayURL
    }

    public var isGatewayConnectionPending: Bool {
        guard !isConnected else { return false }
        if gatewayStatus == .starting { return true }
        switch phase {
        case .startingGateway, .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    public var gatewayConnectionReadinessMessage: String? {
        guard isGatewayConnectionPending else { return nil }
        switch phase {
        case .startingGateway:
            return "Gateway is starting…"
        case .connecting, .reconnecting:
            return "Gateway is connecting…"
        default:
            return "Gateway is still starting."
        }
    }

    public var gatewayEndpointSummary: String {
        if let custom = configuration.gatewayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty
        {
            return custom
        }
        return "127.0.0.1:\(configuration.gatewayPort)"
    }

    public var isLocalOnboardingGateRequired: Bool {
        guard configuration.isEnabled else { return false }
        guard !hasCustomGatewayURL else { return false }
        switch onboardingState {
        case .checking, .required:
            return true
        default:
            return false
        }
    }

    public var onboardingFailureMessage: String? {
        if case .failed(let message) = onboardingState {
            return message
        }
        return nil
    }

    private var hasCustomGatewayURL: Bool {
        !(configuration.gatewayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private init() {
        let loadedConfiguration = OpenClawConfigurationStore.load()
        self.configuration = loadedConfiguration
        self.phase = loadedConfiguration.isEnabled ? .configured : .notConfigured

        installMCPProviderStatusListener()

        Task { [weak self] in
            await self?.checkEnvironment()
            await self?.installConnectionStateListener()
        }
    }

    public func checkEnvironment() async {
        if configuration.isEnabled {
            phase = .checkingEnvironment
        } else {
            phase = .notConfigured
        }

        let status = await OpenClawEnvironment.check()
        environmentStatus = status

        switch status {
        case .ready:
            if !configuration.isEnabled {
                phase = .notConfigured
                onboardingState = .unknown
            } else if gatewayStatus == .running {
                phase = isConnected ? .connected : .gatewayRunning
            } else {
                phase = .configured
            }
        case .checking:
            phase = .checkingEnvironment
        default:
            if configuration.isEnabled {
                phase = .environmentBlocked(status)
            } else {
                phase = .notConfigured
                onboardingState = .unknown
            }
        }
    }

    public func refreshOnboardingState(force: Bool = false) async {
        guard configuration.isEnabled else {
            onboardingState = .unknown
            return
        }

        guard !hasCustomGatewayURL else {
            onboardingState = .notRequired
            return
        }

        guard isConnected else {
            if force || onboardingState == .checking {
                onboardingState = .unknown
            }
            return
        }

        if !force {
            switch onboardingState {
            case .required, .notRequired:
                return
            default:
                break
            }
        }

        onboardingState = .checking

        do {
            let requiresOnboarding = try await detectOnboardingRequirement()
            onboardingState = requiresOnboarding ? .required : .notRequired
        } catch {
            onboardingState = .failed(error.localizedDescription)
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.onboarding.state.failed",
                context: ["error": error.localizedDescription]
            )
        }
    }

    private func detectOnboardingRequirement() async throws -> Bool {
        let agents = try await gatewayAgentsList()
        let defaultAgentId = normalizedString(agents.defaultId) ?? agents.agents.first?.id
        guard let defaultAgentId else {
            return false
        }

        let listing = try await gatewayAgentsFilesList(agentId: defaultAgentId)
        return listing.files.contains { file in
            file.name.caseInsensitiveCompare("BOOTSTRAP.md") == .orderedSame && !file.missing
        }
    }

    public func installCLI(onProgress: @escaping @Sendable (String) -> Void) async throws {
        phase = .installingCLI
        do {
            try await OpenClawInstaller.install(onProgress: onProgress)
        } catch {
            // Always re-evaluate environment so dashboard controls are not left
            // disabled in an "installing" phase after a failed install attempt.
            await checkEnvironment()
            throw error
        }
        await checkEnvironment()
        emitToastEvent(.cliInstallSuccess)
    }

    public func startGateway() async throws {
        if hasCustomGatewayURL {
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.gateway.start.rejected",
                context: [
                    "reason": "custom-endpoint-configured",
                    "endpoint": gatewayEndpointSummary,
                ]
            )
            let rejectedEndpoint = gatewayEndpointSummary
            _ = await Terra.withAgentInvocationSpan(
                agent: .init(name: "openclaw.manager.gateway_start.rejected", id: nil)
            ) { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.gateway.start.endpoint": .string(rejectedEndpoint),
                ])
            }
            throw NSError(
                domain: "OpenClawManager",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Custom gateway endpoint is configured. Clear the endpoint to start a local gateway process."
                ]
            )
        }
        let startTime = Date()
        await emitStartupDiagnostic(
            level: .info,
            event: "openclaw.gateway.start.begin",
            context: [
                "endpoint": gatewayEndpointSummary,
                "bindMode": configuration.bindMode.rawValue,
                "port": "\(OpenClawEnvironment.gatewayPort(from: configuration))",
            ]
        )
        let beginEndpoint = gatewayEndpointSummary
        let beginBindMode = configuration.bindMode.rawValue
        let beginPort = OpenClawEnvironment.gatewayPort(from: configuration)
        _ = await Terra.withAgentInvocationSpan(
            agent: .init(name: "openclaw.manager.gateway_start.begin", id: nil)
        ) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.gateway.start.endpoint": .string(beginEndpoint),
                "osaurus.openclaw.gateway.start.bind_mode": .string(beginBindMode),
                "osaurus.openclaw.gateway.start.port": .int(beginPort),
            ])
        }

        if !configuration.isEnabled {
            configuration.isEnabled = true
            saveConfiguration()
        }

        gatewayStatus = .starting
        phase = .startingGateway
        postGatewayStatusChanged()

        // Tear down any running agent first to avoid --force lock conflicts.
        // Also kill any stale process still holding the port — launchctl bootout removes
        // the LaunchAgent from launchd's registry but does not always kill the process.
        _ = await OpenClawLaunchAgent.uninstall()
        let port = OpenClawEnvironment.gatewayPort(from: configuration)
        await OpenClawLaunchAgent.killProcessOnPort(port)

        if let error = await OpenClawLaunchAgent.install(
            port: OpenClawEnvironment.gatewayPort(from: configuration),
            bindMode: configuration.bindMode,
            token: resolveGatewayToken()
        ) {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.gateway.start.install.failed",
                context: [
                    "endpoint": gatewayEndpointSummary,
                    "elapsedMs": "\(elapsedMs)",
                    "error": error,
                ]
            )
            let installFailedEndpoint = gatewayEndpointSummary
            let installFailedError = error
            _ = await Terra.withAgentInvocationSpan(
                agent: .init(name: "openclaw.manager.gateway_start.install_failed", id: nil)
            ) { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.gateway.start.endpoint": .string(installFailedEndpoint),
                    "osaurus.openclaw.gateway.start.elapsed_ms": .int(elapsedMs),
                    "osaurus.openclaw.gateway.start.error": .string(installFailedError),
                ])
            }
            gatewayStatus = .failed(error)
            phase = .gatewayFailed(error)
            lastError = error
            postGatewayStatusChanged()
            throw NSError(domain: "OpenClawManager", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }

        let deadline = Date().addingTimeInterval(15)
        var lastPollError: String?
        var pollAttempt = 0
        while Date() < deadline {
            pollAttempt += 1
            let pollStart = Date()
            do {
                let payload = try await fetchHealthOverHTTP()
                if let pid = payload["pid"]?.value as? Int {
                    trackedPID = pid
                }
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                let pollElapsedMs = Int(Date().timeIntervalSince(pollStart) * 1000)
                await emitStartupDiagnostic(
                    level: .info,
                    event: "openclaw.gateway.start.poll.succeeded",
                    context: [
                        "attempt": "\(pollAttempt)",
                        "pollElapsedMs": "\(pollElapsedMs)",
                        "elapsedMs": "\(elapsedMs)",
                        "pid": trackedPID.map(String.init) ?? "<missing>",
                    ]
                )
                gatewayStatus = .running
                phase = isConnected ? .connected : .gatewayRunning
                lastError = nil
                postGatewayStatusChanged()
                emitToastEvent(.started)
                let successElapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                let successPollAttempt = pollAttempt
                let successConnected = isConnected
                _ = await Terra.withAgentInvocationSpan(
                    agent: .init(name: "openclaw.manager.gateway_start.success", id: nil)
                ) { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.gateway.start.poll_attempts": .int(successPollAttempt),
                        "osaurus.openclaw.gateway.start.elapsed_ms": .int(successElapsedMs),
                        "osaurus.openclaw.gateway.start.connected": .bool(successConnected),
                    ])
                }
                return
            } catch {
                lastPollError = error.localizedDescription
                let pollElapsedMs = Int(Date().timeIntervalSince(pollStart) * 1000)
                await emitStartupDiagnostic(
                    level: .warning,
                    event: "openclaw.gateway.start.poll.failed",
                    context: [
                        "attempt": "\(pollAttempt)",
                        "pollElapsedMs": "\(pollElapsedMs)",
                        "error": error.localizedDescription,
                    ]
                )
                let pollErrorMessage = error.localizedDescription
                let failedPollAttempt = pollAttempt
                let failedPollElapsedMs = pollElapsedMs
                _ = await Terra.withAgentInvocationSpan(
                    agent: .init(name: "openclaw.manager.gateway_start.poll_failed", id: nil)
                ) { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.gateway.start.poll_attempt": .int(failedPollAttempt),
                        "osaurus.openclaw.gateway.start.poll_elapsed_ms": .int(failedPollElapsedMs),
                        "osaurus.openclaw.gateway.start.poll_error": .string(pollErrorMessage),
                    ])
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let message = "Gateway did not respond within 15 seconds. \(lastPollError ?? "Unknown error.")"
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        await emitStartupDiagnostic(
            level: .error,
            event: "openclaw.gateway.start.timeout",
            context: [
                "attempts": "\(pollAttempt)",
                "elapsedMs": "\(elapsedMs)",
                "error": message,
            ]
        )
        let timeoutPollAttempt = pollAttempt
        _ = await Terra.withAgentInvocationSpan(
            agent: .init(name: "openclaw.manager.gateway_start.timeout", id: nil)
        ) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.gateway.start.poll_attempts": .int(timeoutPollAttempt),
                "osaurus.openclaw.gateway.start.elapsed_ms": .int(elapsedMs),
                "osaurus.openclaw.gateway.start.error": .string(message),
            ])
        }
        gatewayStatus = .failed(message)
        phase = .gatewayFailed(message)
        lastError = message
        postGatewayStatusChanged()
        emitToastEvent(.failed(message))
        throw NSError(domain: "OpenClawManager", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func stopGateway() async {
        await disconnectInternal()
        if let error = await OpenClawLaunchAgent.uninstall() {
            gatewayStatus = .failed(error)
            phase = .gatewayFailed(error)
            lastError = error
        } else {
            gatewayStatus = .stopped
            phase = configuration.isEnabled ? .configured : .notConfigured
            lastError = nil
        }
        trackedPID = nil
        postGatewayStatusChanged()
    }

    public func connect() async throws {
        let connectStartedAt = Date()
        guard gatewayStatus == .running || hasCustomGatewayURL else {
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.connect.rejected",
                context: [
                    "reason": "gateway-not-running",
                    "gatewayStatus": gatewayStatusLabel(gatewayStatus),
                    "customEndpoint": "\(hasCustomGatewayURL)",
                ]
            )
            throw NSError(
                domain: "OpenClawManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Gateway is not running."]
            )
        }
        guard connectionState != .connected else {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connect.skipped",
                context: ["reason": "already-connected"]
            )
            return
        }

        let startedAt = Date()
        let endpoints = try resolveGatewayEndpoints()
        let preferLocalGatewaySources = !hasCustomGatewayURL && Self.isLoopbackGatewayURL(endpoints.webSocketURL)
        var preConnectDiagnosticContext = [
            "webSocketURL": endpoints.webSocketURL.absoluteString,
            "healthURL": endpoints.healthURL?.absoluteString ?? "<none>",
            "preferLocalCredentialSources": preferLocalGatewaySources ? "true" : "false",
        ]
        if preferLocalGatewaySources {
            // Keep local-loopback auth aligned with the gateway-owned token sources.
            let synced = synchronizeLocalGatewayToken(clearSDKDeviceToken: false)
            preConnectDiagnosticContext["localCredentialSyncAttempted"] = "true"
            preConnectDiagnosticContext["localCredentialSyncSucceeded"] = synced ? "true" : "false"
        } else {
            preConnectDiagnosticContext["localCredentialSyncAttempted"] = "false"
        }
        let credentialResolution = resolveGatewayCredential(preferLocalGatewaySources: preferLocalGatewaySources)
        preConnectDiagnosticContext["credentialConfigured"] = credentialResolution.credential?.isEmpty == false ? "true" : "false"
        preConnectDiagnosticContext["credentialSource"] = credentialResolution.source.rawValue
        preConnectDiagnosticContext.merge(credentialResolution.availability.diagnosticsContext()) { _, new in new }
        await emitStartupDiagnostic(
            level: .info,
            event: "openclaw.connect.begin",
            context: preConnectDiagnosticContext
        )
        let connectBeginURL = endpoints.webSocketURL.absoluteString
        let connectBeginCredentialSource = credentialResolution.source.rawValue
        let connectBeginCredentialConfigured = credentialResolution.credential?.isEmpty == false
        _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.connect.begin", id: nil)) {
            scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.manager.connect.url": .string(connectBeginURL),
                "osaurus.openclaw.manager.connect.credential_source": .string(connectBeginCredentialSource),
                "osaurus.openclaw.manager.connect.credential_configured": .bool(connectBeginCredentialConfigured),
            ])
        }

        connectionState = .connecting
        phase = .connecting
        postConnectionChanged()

        do {
            try await gatewayConnect(
                url: endpoints.webSocketURL,
                token: credentialResolution.credential,
                healthURL: endpoints.healthURL
            )
            await installEventListener()
            if hasCustomGatewayURL {
                gatewayStatus = .running
                postGatewayStatusChanged()
            }
            lastError = nil
            resetHealthFailureTracking()
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            await emitStartupDiagnostic(
                level: .info,
                event: "openclaw.connect.success",
                context: [
                    "elapsedMs": "\(elapsedMs)",
                    "webSocketURL": endpoints.webSocketURL.absoluteString,
                ]
            )
            let connectURL = endpoints.webSocketURL.absoluteString
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.connect.success", id: nil))
            { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.manager.connect.url": .string(connectURL),
                    "osaurus.openclaw.manager.connect.latency_ms": .double(
                        Date().timeIntervalSince(connectStartedAt) * 1000
                    ),
                ])
            }
        } catch {
            var terminalError = error
            if shouldAttemptLocalAuthRecovery(for: error.localizedDescription, endpoint: endpoints.webSocketURL) {
                let credentialHydrated = synchronizeLocalGatewayToken(clearSDKDeviceToken: true)
                let recoveryCandidates = resolveGatewayCredentialCandidates(preferLocalGatewaySources: true)
                let attemptedCredential = Self.normalizedGatewayCredential(credentialResolution.credential)
                var recoveryContext: [String: String] = [
                    "error": error.localizedDescription,
                    "credentialHydrated": credentialHydrated ? "true" : "false",
                    "recoveryCandidateCount": "\(recoveryCandidates.candidates.count)",
                    "recoveryCandidateSources": recoveryCandidates.candidates.map(\.source.rawValue).joined(separator: ","),
                    "initialCredentialSource": credentialResolution.source.rawValue,
                ]
                recoveryContext.merge(recoveryCandidates.availability.diagnosticsContext()) { _, new in new }
                await emitStartupDiagnostic(
                    level: .warning,
                    event: "openclaw.connect.retry.authRecovery",
                    context: recoveryContext
                )

                var recoveryAttempt = 0
                for candidate in recoveryCandidates.candidates {
                    if candidate.credential == attemptedCredential {
                        continue
                    }
                    recoveryAttempt += 1
                    await emitStartupDiagnostic(
                        level: .debug,
                        event: "openclaw.connect.retry.candidate.begin",
                        context: [
                            "attempt": "\(recoveryAttempt)",
                            "credentialSource": candidate.source.rawValue,
                            "webSocketURL": endpoints.webSocketURL.absoluteString,
                        ]
                    )
                    let recoveryBeginURL = endpoints.webSocketURL.absoluteString
                    let recoveryBeginSource = candidate.source.rawValue
                    let recoveryBeginAttempt = recoveryAttempt
                    _ = await Terra.withAgentInvocationSpan(
                        agent: .init(name: "openclaw.manager.connect.recovery_candidate.begin", id: nil)
                    ) { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                            Terra.Keys.Terra.openClawGateway: .bool(true),
                            Terra.Keys.GenAI.providerName: .string("openclaw"),
                            "osaurus.openclaw.manager.connect.url": .string(recoveryBeginURL),
                            "osaurus.openclaw.manager.connect.recovery_source": .string(recoveryBeginSource),
                            "osaurus.openclaw.manager.connect.recovery_attempt": .int(recoveryBeginAttempt),
                        ])
                    }
                    do {
                        try await gatewayConnect(
                            url: endpoints.webSocketURL,
                            token: candidate.credential,
                            healthURL: endpoints.healthURL
                        )
                        await installEventListener()
                        if hasCustomGatewayURL {
                            gatewayStatus = .running
                            postGatewayStatusChanged()
                        }
                        lastError = nil
                        resetHealthFailureTracking()
                        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                        await emitStartupDiagnostic(
                            level: .info,
                            event: "openclaw.connect.success.afterAuthRecovery",
                            context: [
                                "elapsedMs": "\(elapsedMs)",
                                "credentialSource": candidate.source.rawValue,
                                "attempt": "\(recoveryAttempt)",
                                "webSocketURL": endpoints.webSocketURL.absoluteString,
                            ]
                        )
                        let recoveryURL = endpoints.webSocketURL.absoluteString
                        let recoverySource = candidate.source.rawValue
                        let recoverySuccessAttempt = recoveryAttempt
                        _ = await Terra.withAgentInvocationSpan(
                            agent: .init(name: "openclaw.manager.connect.success.auth_recovery", id: nil)
                        ) { scope in
                            scope.setAttributes([
                                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                                Terra.Keys.Terra.openClawGateway: .bool(true),
                                Terra.Keys.GenAI.providerName: .string("openclaw"),
                                "osaurus.openclaw.manager.connect.url": .string(recoveryURL),
                                "osaurus.openclaw.manager.connect.recovery_source": .string(recoverySource),
                                "osaurus.openclaw.manager.connect.recovery_attempt": .int(recoverySuccessAttempt),
                                "osaurus.openclaw.manager.connect.latency_ms": .double(
                                    Date().timeIntervalSince(connectStartedAt) * 1000
                                ),
                            ])
                        }
                        return
                    } catch {
                        terminalError = error
                        let continueRecovery = shouldAttemptLocalAuthRecovery(
                            for: error.localizedDescription,
                            endpoint: endpoints.webSocketURL
                        )
                        await emitStartupDiagnostic(
                            level: .warning,
                            event: "openclaw.connect.retry.candidate.failed",
                            context: [
                                "attempt": "\(recoveryAttempt)",
                                "credentialSource": candidate.source.rawValue,
                                "error": error.localizedDescription,
                                "continueRecovery": continueRecovery ? "true" : "false",
                                "webSocketURL": endpoints.webSocketURL.absoluteString,
                            ]
                        )
                        let recoveryFailedURL = endpoints.webSocketURL.absoluteString
                        let recoveryFailedSource = candidate.source.rawValue
                        let recoveryFailedMessage = error.localizedDescription
                        let recoveryFailedAttempt = recoveryAttempt
                        _ = await Terra.withAgentInvocationSpan(
                            agent: .init(name: "openclaw.manager.connect.recovery_candidate.failed", id: nil)
                        ) { scope in
                            scope.setAttributes([
                                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                                Terra.Keys.Terra.openClawGateway: .bool(true),
                                Terra.Keys.GenAI.providerName: .string("openclaw"),
                                "osaurus.openclaw.manager.connect.url": .string(recoveryFailedURL),
                                "osaurus.openclaw.manager.connect.recovery_source": .string(recoveryFailedSource),
                                "osaurus.openclaw.manager.connect.recovery_attempt": .int(recoveryFailedAttempt),
                                "osaurus.openclaw.manager.connect.recovery_error": .string(recoveryFailedMessage),
                                "osaurus.openclaw.manager.connect.recovery_continue": .bool(continueRecovery),
                            ])
                        }
                        if !continueRecovery {
                            break
                        }
                    }
                }
            }
            connectionState = .failed(terminalError.localizedDescription)
            phase = .connectionFailed(terminalError.localizedDescription)
            lastError = terminalError.localizedDescription
            postConnectionChanged()
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.connect.failed",
                context: [
                    "elapsedMs": "\(elapsedMs)",
                    "webSocketURL": endpoints.webSocketURL.absoluteString,
                    "error": terminalError.localizedDescription,
                ]
            )
            let failedURL = endpoints.webSocketURL.absoluteString
            let failedMessage = terminalError.localizedDescription
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.connect.failed", id: nil))
                { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.manager.connect.url": .string(failedURL),
                        "osaurus.openclaw.manager.connect.latency_ms": .double(
                            Date().timeIntervalSince(connectStartedAt) * 1000
                        ),
                        "osaurus.openclaw.manager.connect.error": .string(failedMessage),
                    ])
                }
            throw terminalError
        }
    }

    public func disconnect() {
        Task { [weak self] in
            await self?.disconnectInternal()
        }
    }

    public func refreshStatus() async {
        guard isConnected else { return }
        let refreshStartedAt = Date()
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.refresh.begin",
            context: [:]
        )
        _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.refresh.begin", id: nil)) {
            scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
            ])
        }

        do {
            async let modelsTask = gatewayModelsList()
            async let healthTask = gatewayHealth()
            async let heartbeatTask: OpenClawHeartbeatStatus? = {
                try? await gatewayHeartbeatStatus()
            }()

            if let detailedStatus = try await gatewayChannelsStatusDetailed() {
                channelStatus = detailedStatus
                channels = channelInfos(from: detailedStatus)
                notificationService.ingestStatus(detailedStatus)
            } else {
                let channelPayload = try await gatewayChannelsStatus()
                channels = channelPayload.map(channelInfo(from:)).sorted { $0.name < $1.name }
                channelStatus = nil
            }

            let models = try await modelsTask
            let newIDs = models.map(\.id)
            let oldIDs = availableModels.map(\.id)
            if newIDs != oldIDs {
                availableModels = models
                postModelsChanged()
            }

            let health = try await healthTask
            updateHealth(from: health)
            postGatewayStatusChanged()

            if let heartbeatInfo = await heartbeatTask {
                heartbeatEnabled = heartbeatInfo.enabled ?? heartbeatEnabled
                heartbeatLastTimestamp = heartbeatInfo.lastHeartbeatAt
            }
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.refresh.success",
                context: [
                    "channelCount": "\(channels.count)",
                    "modelCount": "\(availableModels.count)",
                ]
            )
            let channelCount = channels.count
            let modelCount = availableModels.count
            let heartbeatOn = heartbeatEnabled
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.refresh.success", id: nil))
            { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.manager.refresh.channel_count": .int(channelCount),
                    "osaurus.openclaw.manager.refresh.model_count": .int(modelCount),
                    "osaurus.openclaw.manager.refresh.heartbeat_enabled": .bool(heartbeatOn),
                    "osaurus.openclaw.manager.refresh.latency_ms": .double(
                        Date().timeIntervalSince(refreshStartedAt) * 1000
                    ),
                ])
            }
        } catch {
            let message = "Status refresh failed: \(error.localizedDescription)"
            lastError = message
            connectionState = .failed(message)
            phase = .connectionFailed(message)
            emitToastEvent(.failed(message))
            postConnectionChanged()
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.refresh.failed",
                context: ["error": message]
            )
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.manager.refresh.failed", id: nil)) {
                scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.manager.refresh.error": .string(message),
                    "osaurus.openclaw.manager.refresh.latency_ms": .double(
                        Date().timeIntervalSince(refreshStartedAt) * 1000
                    ),
                ])
            }
        }
    }

    public func shutdown() async {
        await disconnectInternal()
        saveConfiguration()
    }

    public func emergencyStopSession(key: String) async throws {
        try await OpenClawSessionManager.shared.patchSession(key: key, sendPolicy: "deny")
        activeSessions.removeAll { $0.key == key }
        runToSessionKey = runToSessionKey.filter { $0.value != key }
    }

    public func disconnectChannel(channelId: String, accountId: String? = nil) async throws {
        try await gatewayChannelsLogout(channelId: channelId, accountId: accountId)
        await refreshStatus()
    }

    public func refreshCron() async {
        guard isConnected else { return }
        do {
            cronStatus = try await gatewayCronStatus()
            cronJobs = try await gatewayCronList()
        } catch {
            lastError = "Cron refresh failed: \(error.localizedDescription)"
        }
    }

    public func refreshCronRuns(jobId: String, limit: Int = 50) async {
        guard isConnected else { return }
        do {
            cronRunsByJobID[jobId] = try await gatewayCronRuns(jobId: jobId, limit: limit)
        } catch {
            lastError = "Cron run history failed: \(error.localizedDescription)"
        }
    }

    public func runCronJob(jobId: String) async throws {
        try await gatewayCronRun(jobId: jobId)
        await refreshCronRuns(jobId: jobId)
        await refreshCron()
    }

    public func setCronJobEnabled(jobId: String, enabled: Bool) async throws {
        try await gatewayCronSetEnabled(jobId: jobId, enabled: enabled)
        await refreshCron()
    }

    public func refreshSkills() async {
        guard isConnected else { return }
        do {
            if let agentsList = try? await gatewayAgentsList() {
                updateSkillsAgentSelection(with: agentsList)
            }
            skillsReport = try await gatewaySkillsStatus(agentId: selectedSkillsAgentId)
            skillsBins = try await gatewaySkillsBins()
        } catch {
            lastError = "Skills refresh failed: \(error.localizedDescription)"
        }
    }

    public func selectSkillsAgent(_ agentId: String?) async {
        let normalized = normalizeSkillsAgentId(agentId)
        guard selectedSkillsAgentId != normalized else { return }
        selectedSkillsAgentId = normalized
        await refreshSkills()
    }

    private func updateSkillsAgentSelection(with response: OpenClawGatewayAgentsListResponse) {
        let agents = response.agents
        skillsAgents = agents

        let validIDs = Set(agents.map(\.id))
        let normalizedDefault = normalizeSkillsAgentId(response.defaultId)
        if let selected = normalizeSkillsAgentId(selectedSkillsAgentId), validIDs.contains(selected) {
            selectedSkillsAgentId = selected
            return
        }
        selectedSkillsAgentId = normalizedDefault ?? agents.first?.id
    }

    private func normalizeSkillsAgentId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public func updateSkillEnabled(skillKey: String, enabled: Bool) async throws {
        _ = try await gatewaySkillsUpdate(skillKey: skillKey, enabled: enabled, apiKey: nil, env: nil)
        await refreshSkills()
    }

    public func updateSkillConfiguration(
        skillKey: String,
        apiKey: String?,
        env: [String: String]?
    ) async throws {
        _ = try await gatewaySkillsUpdate(skillKey: skillKey, enabled: nil, apiKey: apiKey, env: env)
        await refreshSkills()
    }

    public func installSkill(name: String, installId: String) async throws {
        _ = try await gatewaySkillsInstall(name: name, installId: installId, timeoutMs: 120_000)
        await refreshSkills()
    }

    public func refreshConnectedClients() async {
        guard isConnected else { return }
        do {
            connectedClients = try await gatewaySystemPresence()
        } catch {
            lastError = "Connected clients refresh failed: \(error.localizedDescription)"
        }
    }

    public func listAgentWorkspaceFiles(agentId: String? = nil) async throws -> OpenClawAgentFilesListResponse {
        let resolvedAgentId = try await resolveTargetAgentId(agentId)
        return try await gatewayAgentsFilesList(agentId: resolvedAgentId)
    }

    public func readAgentWorkspaceFile(
        name: String,
        agentId: String? = nil
    ) async throws -> OpenClawAgentWorkspaceFile {
        let resolvedAgentId = try await resolveTargetAgentId(agentId)
        let response = try await gatewayAgentsFileGet(agentId: resolvedAgentId, name: name)
        return response.file
    }

    public func writeAgentWorkspaceFile(
        name: String,
        content: String,
        agentId: String? = nil
    ) async throws -> OpenClawAgentWorkspaceFile {
        let resolvedAgentId = try await resolveTargetAgentId(agentId)
        let response = try await gatewayAgentsFileSet(
            agentId: resolvedAgentId,
            name: name,
            content: content
        )
        return response.file
    }

    public func readAgentMemoryFile(agentId: String? = nil) async throws -> OpenClawAgentWorkspaceFile? {
        let resolvedAgentId = try await resolveTargetAgentId(agentId)
        let listing = try await gatewayAgentsFilesList(agentId: resolvedAgentId)

        let preferredName = listing.files.first {
            $0.name.lowercased() == "memory.md" && !$0.missing
        }?.name ?? listing.files.first(where: { $0.name.lowercased() == "memory.md" })?.name

        guard let preferredName else {
            return nil
        }
        let response = try await gatewayAgentsFileGet(agentId: resolvedAgentId, name: preferredName)
        return response.file
    }

    public func syncMCPProvidersToOpenClaw(
        enableMcporterSkill: Bool = true
    ) async throws -> OpenClawMCPBridgeSyncResult {
        try await syncMCPProvidersToOpenClaw(
            enableMcporterSkill: enableMcporterSkill,
            providerEntriesOverride: nil,
            outputURLOverride: nil,
            mode: .manual,
            allowUnownedOverwrite: true
        )
    }

    func syncMCPProvidersToOpenClaw(
        enableMcporterSkill: Bool,
        providerEntriesOverride: [OpenClawMCPBridge.ProviderEntry]?,
        outputURLOverride: URL?,
        mode: OpenClawMCPBridgeSyncMode = .manual,
        allowUnownedOverwrite: Bool = true
    ) async throws -> OpenClawMCPBridgeSyncResult {
        guard isConnected else {
            let message = "Connect OpenClaw before syncing MCP providers."
            setMCPBridgeSyncErrorState(
                code: .notConnected,
                message: message,
                retryable: true,
                mode: mode
            )
            throw NSError(
                domain: "OpenClawManager",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard !mcpBridgeIsSyncing else {
            let message = "MCP bridge sync is already in progress."
            setMCPBridgeSyncErrorState(
                code: .syncInProgress,
                message: message,
                retryable: false,
                mode: mode
            )
            throw NSError(
                domain: "OpenClawManager",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        mcpBridgeIsSyncing = true
        mcpBridgeLastSyncMode = mode
        mcpBridgeLastSyncError = nil
        mcpBridgeLastSyncErrorState = nil
        defer { mcpBridgeIsSyncing = false }

        let providerEntries = resolveMCPBridgeProviderEntries(override: providerEntriesOverride)
        let outputURL = outputURLOverride ?? OpenClawMCPBridge.defaultConfigFileURL()
        if mode == .manual {
            lastManualMCPBridgeEnableSkill = enableMcporterSkill
            lastManualMCPBridgeProviderEntries = providerEntries
            lastManualMCPBridgeOutputURL = outputURL
        }

        do {
            let syncResult = try OpenClawMCPBridge.writeConfig(
                providers: providerEntries,
                to: outputURL,
                mode: mode,
                allowUnownedOverwrite: allowUnownedOverwrite
            )

            do {
                try await applyMcporterSkillSync(
                    enableMcporterSkill: enableMcporterSkill,
                    configPath: syncResult.configPath
                )
                await refreshSkills()
                mcpBridgeLastSyncResult = syncResult
                mcpBridgeLastSyncError = nil
                mcpBridgeLastSyncErrorState = nil
                return syncResult
            } catch {
                let rollbackPerformed = (try? OpenClawMCPBridge.rollbackToBackup(configFileURL: outputURL)) ?? false
                let rollbackDetail = rollbackPerformed
                    ? " Restored previous bridge config from backup."
                    : " No backup was available for rollback."
                let message = "Failed to update OpenClaw mcporter skill after writing bridge config. \(error.localizedDescription).\(rollbackDetail)"
                let code: MCPBridgeSyncErrorState.Code = {
                    if let syncError = error as? MCPBridgeSkillSyncFailure {
                        switch syncError {
                        case .installOptionUnavailable, .installFailed:
                            return .mcporterInstallFailed
                        case .updateFailed:
                            return .mcporterUpdateFailed
                        }
                    }
                    return .mcporterUpdateFailed
                }()
                setMCPBridgeSyncErrorState(
                    code: code,
                    message: message,
                    retryable: mode == .manual,
                    mode: mode
                )
                throw NSError(
                    domain: "OpenClawManager",
                    code: 17,
                    userInfo: [NSLocalizedDescriptionKey: mcpBridgeLastSyncError ?? message]
                )
            }
        } catch {
            if mode == .automatic, error is OpenClawMCPBridgeError {
                let message = "Automatic MCP sync skipped: \(error.localizedDescription)"
                setMCPBridgeSyncErrorState(
                    code: .automaticSyncSkipped,
                    message: message,
                    retryable: true,
                    mode: mode
                )
                throw error
            }

            if mcpBridgeLastSyncError == nil {
                setMCPBridgeSyncErrorState(
                    code: .bridgeWriteFailed,
                    message: "MCP bridge sync failed: \(error.localizedDescription)",
                    retryable: mode == .manual,
                    mode: mode
                )
            }
            throw error
        }
    }

    public func retryLastMCPBridgeSync() async throws -> OpenClawMCPBridgeSyncResult {
        try await syncMCPProvidersToOpenClaw(
            enableMcporterSkill: lastManualMCPBridgeEnableSkill,
            providerEntriesOverride: lastManualMCPBridgeProviderEntries,
            outputURLOverride: lastManualMCPBridgeOutputURL,
            mode: .manual,
            allowUnownedOverwrite: true
        )
    }

    public func setAutoSyncMCPBridge(_ enabled: Bool) {
        guard configuration.autoSyncMCPBridge != enabled else { return }
        configuration.autoSyncMCPBridge = enabled
        saveConfiguration()

        if enabled {
            scheduleMCPBridgeAutoSync(reason: "auto-sync enabled", debounce: false)
        } else {
            mcpBridgeAutoSyncTask?.cancel()
            mcpBridgeAutoSyncTask = nil
        }
    }

    private enum MCPBridgeSkillSyncFailure: LocalizedError {
        case installOptionUnavailable
        case installFailed(String)
        case updateFailed(String)

        var errorDescription: String? {
            switch self {
            case .installOptionUnavailable:
                return "OpenClaw mcporter skill is not installed and no install option is available."
            case .installFailed(let detail):
                return "OpenClaw mcporter skill install failed: \(detail)"
            case .updateFailed(let detail):
                return detail
            }
        }
    }

    private func setMCPBridgeSyncErrorState(
        code: MCPBridgeSyncErrorState.Code,
        message: String,
        retryable: Bool,
        mode: OpenClawMCPBridgeSyncMode
    ) {
        let sanitized = Self.redactedSensitiveText(message)
        mcpBridgeLastSyncError = sanitized
        mcpBridgeLastSyncErrorState = MCPBridgeSyncErrorState(
            code: code,
            message: sanitized,
            retryable: retryable,
            mode: mode
        )
        lastError = sanitized
    }

    private func applyMcporterSkillSync(
        enableMcporterSkill: Bool,
        configPath: String
    ) async throws {
        let enabled: Bool? = enableMcporterSkill ? true : nil
        let env = ["MCPORTER_CONFIG": configPath]

        do {
            _ = try await gatewaySkillsUpdate(
                skillKey: "mcporter",
                enabled: enabled,
                apiKey: nil,
                env: env
            )
        } catch {
            guard enableMcporterSkill, shouldAttemptMcporterInstall(after: error) else {
                throw MCPBridgeSkillSyncFailure.updateFailed(error.localizedDescription)
            }

            guard let installOption = try await resolveMcporterInstallOption() else {
                throw MCPBridgeSkillSyncFailure.installOptionUnavailable
            }

            do {
                _ = try await gatewaySkillsInstall(
                    name: "mcporter",
                    installId: installOption.id,
                    timeoutMs: 120_000
                )
            } catch {
                throw MCPBridgeSkillSyncFailure.installFailed(error.localizedDescription)
            }

            do {
                _ = try await gatewaySkillsUpdate(
                    skillKey: "mcporter",
                    enabled: enabled,
                    apiKey: nil,
                    env: env
                )
            } catch {
                throw MCPBridgeSkillSyncFailure.updateFailed(error.localizedDescription)
            }
        }
    }

    private func shouldAttemptMcporterInstall(after error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 404 {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("not found")
            || message.contains("unknown skill")
            || message.contains("missing skill")
            || message.contains("no such skill")
    }

    private func resolveMcporterInstallOption() async throws -> OpenClawSkillInstallOption? {
        if let existing = skillsReport?.skills.first(where: { isMcporterSkill($0) })?.install.first {
            return existing
        }

        let refreshedReport = try await gatewaySkillsStatus()
        skillsReport = refreshedReport
        return refreshedReport.skills.first(where: { isMcporterSkill($0) })?.install.first
    }

    private func isMcporterSkill(_ skill: OpenClawSkillStatus) -> Bool {
        skill.skillKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mcporter"
            || skill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mcporter"
    }

    private static func redactedSensitiveText(_ raw: String) -> String {
        var message = raw
        let replacements: [(String, String)] = [
            (#"(?i)(api[_-]?key\s*[=:]\s*)([^\s,;]+)"#, "$1[REDACTED]"),
            (#"(?i)(token\s*[=:]\s*)([^\s,;]+)"#, "$1[REDACTED]"),
            (#"(?i)(authorization\s*:\s*bearer\s+)([^\s,;]+)"#, "$1[REDACTED]"),
            (#"(?i)(bearer\s+)([^\s,;]+)"#, "$1[REDACTED]")
        ]

        for (pattern, template) in replacements {
            message = message.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        return message
    }

    // MARK: - Provider Management

    private enum ProviderConfigMutation {
        case skip
        case set(provider: [String: Any], allowlistEntries: [String: [String: Any]])
        case remove
    }

    private func applyProviderConfigMutation(
        providerId: String,
        buildMutation: (
            _ existingProvider: [String: OpenClawProtocol.AnyCodable]?,
            _ config: [String: OpenClawProtocol.AnyCodable]?
        ) throws -> ProviderConfigMutation
    ) async throws -> ConfigPatchResult? {
        var lastError: Error?
        for attempt in 1...Self.providerConfigPatchRetryAttempts {
            let configResult = try await gatewayConfigGetFull()
            guard let baseHash = configResult.baseHash else {
                throw NSError(
                    domain: "OpenClawManager",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "No baseHash in config response."]
                )
            }

            let existingProvider = Self.providerConfigEntry(from: configResult.config, providerId: providerId)
            let mutation = try buildMutation(existingProvider, configResult.config)
            switch mutation {
            case .skip:
                return nil
            case .set(let providerEntry, let allowlistEntries):
                var patch: [String: Any] = [
                    "models": [
                        "providers": [
                            providerId: providerEntry
                        ]
                    ]
                ]
                if !allowlistEntries.isEmpty {
                    patch["agents"] = [
                        "defaults": [
                            "models": allowlistEntries
                        ]
                    ]
                }
                let patchData = try JSONSerialization.data(withJSONObject: patch)
                let patchJSON = String(data: patchData, encoding: .utf8) ?? "{}"
                do {
                    return try await gatewayConfigPatch(raw: patchJSON, baseHash: baseHash)
                } catch {
                    lastError = error
                    guard attempt < Self.providerConfigPatchRetryAttempts,
                        Self.isStaleBaseHashError(error)
                    else {
                        throw error
                    }
                    try? await Task.sleep(
                        nanoseconds: Self.providerConfigPatchRetryDelayNanoseconds * UInt64(attempt)
                    )
                }
            case .remove:
                let patch: [String: Any] = [
                    "models": [
                        "providers": [
                            providerId: NSNull()
                        ]
                    ]
                ]
                let patchData = try JSONSerialization.data(withJSONObject: patch)
                let patchJSON = String(data: patchData, encoding: .utf8) ?? "{}"
                do {
                    return try await gatewayConfigPatch(raw: patchJSON, baseHash: baseHash)
                } catch {
                    lastError = error
                    guard attempt < Self.providerConfigPatchRetryAttempts,
                        Self.isStaleBaseHashError(error)
                    else {
                        throw error
                    }
                    try? await Task.sleep(
                        nanoseconds: Self.providerConfigPatchRetryDelayNanoseconds * UInt64(attempt)
                    )
                }
            }
        }

        if let lastError {
            throw lastError
        }
        return nil
    }

    @discardableResult
    public func addProvider(
        id: String,
        baseUrl: String,
        apiCompatibility: String,
        apiKey: String?,
        seedModelsFromEndpoint: Bool = false,
        requireSeededModels: Bool = false
    ) async throws -> Int {
        let normalizedProviderID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBaseURL = Self.canonicalProviderBaseURL(
            providerId: normalizedProviderID,
            baseURL: baseUrl
        )
        let normalizedAPI = Self.canonicalProviderAPICompatibility(
            providerId: normalizedProviderID,
            baseURL: normalizedBaseURL,
            apiCompatibility: apiCompatibility
        )
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let discoveredModels: [ProviderSeedModel]
        if seedModelsFromEndpoint {
            await ensureOsaurusLocalServerReadyIfNeeded(
                providerId: id,
                baseURL: normalizedBaseURL
            )
            do {
                discoveredModels = try await gatewayDiscoverProviderModels(
                    baseUrl: normalizedBaseURL,
                    apiKey: normalizedAPIKey
                )
            } catch let discoveryError as ProviderDiscoveryError {
                let shouldRetryLocalBootstrap: Bool = {
                    guard Self.isOsaurusLocalProviderEndpoint(providerId: id, baseURL: normalizedBaseURL) else {
                        return false
                    }
                    switch discoveryError {
                    case .requestTimeout, .unreachable:
                        return true
                    default:
                        return false
                    }
                }()

                guard shouldRetryLocalBootstrap else {
                    providerReadinessOverrides[id] = Self.readinessReason(for: discoveryError)
                    throw discoveryError
                }

                await ensureOsaurusLocalServerReadyIfNeeded(
                    providerId: id,
                    baseURL: normalizedBaseURL
                )
                do {
                    discoveredModels = try await gatewayDiscoverProviderModels(
                        baseUrl: normalizedBaseURL,
                        apiKey: normalizedAPIKey
                    )
                } catch let retryDiscoveryError as ProviderDiscoveryError {
                    providerReadinessOverrides[id] = Self.readinessReason(for: retryDiscoveryError)
                    throw retryDiscoveryError
                } catch {
                    providerReadinessOverrides[id] = .unreachable
                    throw error
                }
            } catch {
                providerReadinessOverrides[id] = .unreachable
                throw error
            }

        } else {
            discoveredModels = []
        }

        let configuredModels = Self.configuredProviderModels(
            providerId: id,
            baseURL: normalizedBaseURL,
            apiCompatibility: normalizedAPI,
            discoveredModels: discoveredModels
        )

        if requireSeededModels && configuredModels.isEmpty {
            providerReadinessOverrides[id] = .noModels
            throw ProviderDiscoveryError.noModelsFound("\(normalizedBaseURL)/models")
        }

        var providerEntry: [String: Any] = [
            "baseUrl": normalizedBaseURL,
            "api": normalizedAPI,
            "models": configuredModels.map(\.configPatchObject)
        ]
        let effectiveAPIKey: String? = {
            if let normalizedAPIKey, !normalizedAPIKey.isEmpty {
                return normalizedAPIKey
            }

            let normalizedProviderID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !configuredModels.isEmpty, Self.isLikelyLocalEndpoint(normalizedBaseURL) {
                // OpenClaw's model registry currently requires apiKey to mark custom
                // providers with explicit models[] as available.
                return Self.localProviderPlaceholderAPIKey(for: normalizedProviderID)
            }
            return nil
        }()
        if let effectiveAPIKey {
            providerEntry["apiKey"] = effectiveAPIKey
        }

        let desiredAllowlistEntries = Self.desiredAllowlistEntries(
            providerId: id,
            configuredModels: configuredModels
        )

        let result = try await applyProviderConfigMutation(providerId: id) { existingProvider, config in
            let missingAllowlistEntries = Self.missingAllowlistEntries(
                from: config,
                desired: desiredAllowlistEntries
            )
            if let existingProvider,
               Self.providerConfigMatches(existingProvider, target: providerEntry),
               missingAllowlistEntries.isEmpty
            {
                return .skip
            }
            return .set(provider: providerEntry, allowlistEntries: missingAllowlistEntries)
        }

        if result?.restart == true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isConnected && gatewayStatus == .running {
                try? await connect()
            }
        }

        await refreshStatus()
        try await fetchConfiguredProviders()
        providerReadinessOverrides.removeValue(forKey: id)
        return configuredModels.count
    }

    /// Migrates legacy Kimi Coding provider base URLs from Moonshot Anthropic endpoints
    /// to OpenClaw's canonical `https://api.kimi.com/coding` endpoint.
    @discardableResult
    public func migrateLegacyKimiCodingProviderEndpointIfNeeded() async throws -> Bool {
        let result = try await applyProviderConfigMutation(providerId: "kimi-coding") { existingProvider, _ in
            guard let existingProvider else {
                return .skip
            }

            var providerEntry = Self.normalizeJSONValue(existingProvider) as? [String: Any] ?? [:]
            guard let rawBaseURL = providerEntry["baseUrl"] as? String else {
                return .skip
            }

            let trimmedBaseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBaseURL.isEmpty,
                  Self.isLegacyKimiCodingEndpoint(trimmedBaseURL)
            else {
                return .skip
            }

            providerEntry["baseUrl"] = Self.kimiCodingCanonicalBaseURL
            return .set(provider: providerEntry, allowlistEntries: [:])
        }

        if result?.restart == true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isConnected && gatewayStatus == .running {
                try? await connect()
            }
        }

        if result != nil {
            providerReadinessOverrides.removeValue(forKey: "kimi-coding")
        }
        return result != nil
    }

    /// Migrates legacy MiniMax provider configs from OpenAI-style `/v1` endpoints
    /// to OpenClaw's canonical Anthropic-compatible endpoint.
    @discardableResult
    public func migrateLegacyMiniMaxProviderEndpointIfNeeded() async throws -> Bool {
        let result = try await applyProviderConfigMutation(providerId: "minimax") { existingProvider, _ in
            guard let existingProvider else {
                return .skip
            }

            var providerEntry = Self.normalizeJSONValue(existingProvider) as? [String: Any] ?? [:]
            guard let rawBaseURL = providerEntry["baseUrl"] as? String else {
                return .skip
            }

            let trimmedBaseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawAPI = (providerEntry["api"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""

            let canonicalBaseURL = Self.canonicalProviderBaseURL(
                providerId: "minimax",
                baseURL: trimmedBaseURL
            )
            let canonicalAPI = Self.canonicalProviderAPICompatibility(
                providerId: "minimax",
                baseURL: canonicalBaseURL,
                apiCompatibility: rawAPI
            )

            guard canonicalBaseURL != trimmedBaseURL || canonicalAPI != rawAPI else {
                return .skip
            }

            providerEntry["baseUrl"] = canonicalBaseURL
            providerEntry["api"] = canonicalAPI
            return .set(provider: providerEntry, allowlistEntries: [:])
        }

        if result?.restart == true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isConnected && gatewayStatus == .running {
                try? await connect()
            }
        }

        if result != nil {
            providerReadinessOverrides.removeValue(forKey: "minimax")
        }
        return result != nil
    }

    public func updateProviderAPIKey(id: String, apiKey: String) async throws {
        let providerID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            throw NSError(
                domain: "OpenClawManager",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Provider ID is required."]
            )
        }
        guard !normalizedAPIKey.isEmpty else {
            throw NSError(
                domain: "OpenClawManager",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "API key cannot be empty."]
            )
        }

        let result = try await applyProviderConfigMutation(providerId: providerID) { existingProvider, _ in
            guard let existingProvider else {
                throw NSError(
                    domain: "OpenClawManager",
                    code: 15,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Provider '\(providerID)' is not configured. Add it first."
                    ]
                )
            }

            var providerEntry = Self.normalizeJSONValue(existingProvider) as? [String: Any] ?? [:]
            let existingKey = (providerEntry["apiKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existingKey == normalizedAPIKey {
                return .skip
            }

            providerEntry["apiKey"] = normalizedAPIKey
            return .set(provider: providerEntry, allowlistEntries: [:])
        }

        if result?.restart == true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !isConnected && gatewayStatus == .running {
                try? await connect()
            }
        }

        await refreshStatus()
        try await fetchConfiguredProviders()
        providerReadinessOverrides.removeValue(forKey: providerID)
    }

    public func removeProvider(id: String) async throws {
        let result = try await applyProviderConfigMutation(providerId: id) { existingProvider, _ in
            guard existingProvider != nil else {
                return .skip
            }
            return .remove
        }

        if result?.restart == true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        await refreshStatus()
        try await fetchConfiguredProviders()
        providerReadinessOverrides.removeValue(forKey: id)
    }

    public func fetchConfiguredProviders() async throws {
        do {
            _ = try await migrateLegacyMiniMaxProviderEndpointIfNeeded()
        } catch {
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.providers.minimaxMigration.failed",
                context: ["error": error.localizedDescription]
            )
        }

        do {
            _ = try await migrateLegacyKimiCodingProviderEndpointIfNeeded()
        } catch {
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.providers.kimiCodingMigration.failed",
                context: ["error": error.localizedDescription]
            )
        }

        let configResult = try await gatewayConfigGetFull()
        guard let config = configResult.config else {
            configuredProviders = []
            providerReadinessOverrides = [:]
            return
        }

        guard let modelsSection = config["models"]?.value as? [String: OpenClawProtocol.AnyCodable],
              let providersSection = modelsSection["providers"]?.value as? [String: OpenClawProtocol.AnyCodable]
        else {
            configuredProviders = []
            providerReadinessOverrides = [:]
            return
        }

        var providers: [ProviderInfo] = []
        for (key, value) in providersSection {
            guard let providerDict = value.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            let modelCount = availableModels.filter { $0.provider == key }.count
            let name = key.capitalized

            let apiKeyValue = providerDict["apiKey"]?.value as? String
            let hasApiKey: Bool = {
                guard let apiKeyValue = apiKeyValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !apiKeyValue.isEmpty
                else {
                    return false
                }
                if Self.isLocalPlaceholderAPIKey(apiKeyValue, providerId: key) {
                    return false
                }
                return true
            }()

            let api = providerDict["api"]?.value as? String ?? ""
            let baseURL = providerDict["baseUrl"]?.value as? String
            let needsKey = Self.providerNeedsAPIKey(
                providerId: key,
                api: api,
                baseURL: baseURL
            )
            let readinessReason: ProviderReadinessReason = {
                if let override = providerReadinessOverrides[key], override != .ready {
                    return override
                }

                let normalizedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if normalizedBaseURL.isEmpty || URL(string: normalizedBaseURL) == nil {
                    return .invalidConfig
                }
                if needsKey && !hasApiKey {
                    return .noKey
                }
                if modelCount == 0 {
                    return .noModels
                }
                return .ready
            }()

            providers.append(
                ProviderInfo(
                    id: key,
                    name: name,
                    modelCount: modelCount,
                    hasApiKey: hasApiKey,
                    needsKey: needsKey,
                    readinessReason: readinessReason
                )
            )
        }
        configuredProviders = providers.sorted { $0.id < $1.id }
        let configuredIDs = Set(configuredProviders.map(\.id))
        providerReadinessOverrides = providerReadinessOverrides.filter { configuredIDs.contains($0.key) }
    }

    public func isProviderReady(forModelId modelId: String) -> Bool {
        providerReadinessReason(forModelId: modelId).isReady
    }

    /// Canonicalizes a model selection ID into a gateway-safe reference.
    /// Example: `foundation` -> `osaurus/foundation` when the model is scoped to the Osaurus provider.
    public func canonicalModelReference(for selectedModelId: String) -> String {
        let trimmed = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selectedModelId }

        // Already provider-qualified.
        if trimmed.contains("/") {
            return trimmed
        }

        let matches = availableModels.filter { $0.id == trimmed }
        guard !matches.isEmpty else {
            return trimmed
        }

        let readyProviderIDs = Set(configuredProviders.filter(\.isReady).map(\.id))
        let resolvedProvider: String? =
            matches.first(where: { readyProviderIDs.contains($0.provider) && !$0.provider.isEmpty })?.provider
            ?? matches.first(where: { !$0.provider.isEmpty })?.provider

        guard let resolvedProvider else {
            return trimmed
        }
        return "\(resolvedProvider)/\(trimmed)"
    }

    public func providerReadinessReason(forModelId modelId: String) -> ProviderReadinessReason {
        let stripped: String = {
            if modelId.hasPrefix(OpenClawModelService.modelPrefix) {
                return String(modelId.dropFirst(OpenClawModelService.modelPrefix.count))
            }
            if modelId.hasPrefix(OpenClawModelService.sessionPrefix) {
                let sessionKey = String(modelId.dropFirst(OpenClawModelService.sessionPrefix.count))
                if let runtimeModel = activeSessions.first(where: { $0.key == sessionKey })?.model,
                   !runtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return runtimeModel
                }
            }
            return modelId
        }()

        let normalizedSelection = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerHintAndModelID: (provider: String?, modelID: String) = {
            guard let slashIndex = normalizedSelection.firstIndex(of: "/"),
                  slashIndex > normalizedSelection.startIndex
            else {
                return (nil, normalizedSelection)
            }

            let provider = normalizedSelection[..<slashIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let model = normalizedSelection[normalizedSelection.index(after: slashIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty, !model.isEmpty else {
                return (nil, normalizedSelection)
            }
            return (provider, model)
        }()

        let model = availableModels.first(where: { candidate in
            let candidateID = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateProvider = candidate.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let providerHint = providerHintAndModelID.provider else {
                return candidateID == providerHintAndModelID.modelID
            }
            return candidateProvider == providerHint
                && candidateID == providerHintAndModelID.modelID
        })

        guard let model else {
            if let providerHint = providerHintAndModelID.provider,
               let provider = configuredProviders.first(where: {
                   $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == providerHint
               })
            {
                if let override = providerReadinessOverrides[provider.id], override != .ready {
                    return override
                }
                return provider.readinessReason
            }
            if let override = providerReadinessOverrides.values.first(where: { !$0.isReady }) {
                return override
            }
            if let blocked = configuredProviders.first(where: { !$0.isReady }) {
                return blocked.readinessReason
            }
            return .noModels
        }

        guard let provider = configuredProviders.first(where: { $0.id == model.provider }) else {
            return .invalidConfig
        }

        if let override = providerReadinessOverrides[provider.id], override != .ready {
            return override
        }
        return provider.readinessReason
    }

    public func providerReadinessMessage(forModelId modelId: String) -> String {
        Self.providerReadinessMessage(for: providerReadinessReason(forModelId: modelId))
    }

    public static func providerReadinessMessage(for reason: ProviderReadinessReason) -> String {
        switch reason {
        case .ready:
            return "Provider is ready."
        case .noKey:
            return "The selected provider is missing an API key. Add a key in OpenClaw > Providers and retry."
        case .unreachable:
            return "The selected provider endpoint is unreachable. Check the base URL/network and retry."
        case .noModels:
            return "No models are available for the selected provider. Sync/discover models and retry."
        case .invalidConfig:
            return "The selected provider configuration is invalid. Update base URL/API settings and retry."
        }
    }

    private static func providerNeedsAPIKey(
        providerId: String,
        api: String,
        baseURL: String?
    ) -> Bool {
        let normalizedProviderId = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAPI = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedAPI == "ollama" {
            return false
        }

        if normalizedProviderId == "vllm" {
            return false
        }

        if normalizedAPI == "openai-completions" || normalizedAPI == "anthropic-messages" {
            if let baseURL, isLikelyLocalEndpoint(baseURL) {
                return false
            }
        }

        return true
    }

    private static func providerConfigEntry(
        from config: [String: OpenClawProtocol.AnyCodable]?,
        providerId: String
    ) -> [String: OpenClawProtocol.AnyCodable]? {
        guard let config,
              let models = config["models"]?.value as? [String: OpenClawProtocol.AnyCodable],
              let providers = models["providers"]?.value as? [String: OpenClawProtocol.AnyCodable],
              let provider = providers[providerId]?.value as? [String: OpenClawProtocol.AnyCodable]
        else {
            return nil
        }
        return provider
    }

    private static func providerConfigMatches(
        _ existing: [String: OpenClawProtocol.AnyCodable],
        target: [String: Any]
    ) -> Bool {
        let existingObject = normalizeJSONValue(existing)
        let targetObject = normalizeJSONValue(target)
        guard let existingData = canonicalJSONData(for: existingObject),
              let targetData = canonicalJSONData(for: targetObject)
        else {
            return false
        }
        return existingData == targetData
    }

    private static func normalizeJSONValue(_ value: Any) -> Any {
        if let wrapped = value as? OpenClawProtocol.AnyCodable {
            return normalizeJSONValue(wrapped.value)
        }
        if let dict = value as? [String: OpenClawProtocol.AnyCodable] {
            return dict.reduce(into: [String: Any]()) { partialResult, element in
                partialResult[element.key] = normalizeJSONValue(element.value.value)
            }
        }
        if let array = value as? [OpenClawProtocol.AnyCodable] {
            return array.map { normalizeJSONValue($0.value) }
        }
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { partialResult, element in
                partialResult[element.key] = normalizeJSONValue(element.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { normalizeJSONValue($0) }
        }
        return value
    }

    private static func canonicalJSONData(for object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func isStaleBaseHashError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("basehash")
            || message.contains("base hash")
            || message.contains("stale")
            || message.contains("hash mismatch")
            || message.contains("config changed")
            || message.contains("precondition")
            || message.contains("conflict")
    }

    private func ensureOsaurusLocalServerReadyIfNeeded(
        providerId: String,
        baseURL: String
    ) async {
        guard Self.isOsaurusLocalProviderEndpoint(providerId: providerId, baseURL: baseURL) else {
            return
        }

        if await osaurusLocalHealthCheck() {
            return
        }

        let started = await startOsaurusLocalServerIfAvailable()
        guard started else { return }

        for attempt in 0..<Self.osaurusLocalServerBootstrapAttempts {
            if await osaurusLocalHealthCheck() {
                return
            }
            guard attempt < Self.osaurusLocalServerBootstrapAttempts - 1 else { break }
            try? await Task.sleep(
                nanoseconds: Self.osaurusLocalServerBootstrapDelayNanoseconds
            )
        }
    }

    private func osaurusLocalHealthCheck() async -> Bool {
        if let hooks = Self.gatewayHooks, let localHealthCheck = hooks.osaurusLocalHealthCheck {
            return await localHealthCheck()
        }

        guard let url = URL(string: "http://127.0.0.1:1337/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    private func startOsaurusLocalServerIfAvailable() async -> Bool {
        if let hooks = Self.gatewayHooks, let localStart = hooks.osaurusLocalStart {
            await localStart()
            return true
        }

        guard let appDelegate = AppDelegate.shared else {
            return false
        }

        await appDelegate.serverController.startServer()
        return true
    }

    private static func isOsaurusLocalProviderEndpoint(providerId: String, baseURL: String) -> Bool {
        let normalizedProviderId = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedProviderId == "osaurus" else {
            return false
        }

        guard let components = URLComponents(string: baseURL),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return false
        }

        let isLocalHost = host == "127.0.0.1" || host == "localhost" || host == "::1"
        let port = components.port ?? 1337
        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasExpectedPath = path.isEmpty || path == "/" || path == "/v1"

        return isLocalHost && port == 1337 && hasExpectedPath
    }

    private static func isLikelyLocalEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else {
            return false
        }

        if host == "localhost" || host == "::1" || host == "0.0.0.0" {
            return true
        }
        if host.hasPrefix("127.") || host.hasSuffix(".local") {
            return true
        }
        if isPrivateIPv4Host(host) {
            return true
        }
        return false
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              let third = Int(parts[2]),
              let fourth = Int(parts[3]),
              (0...255).contains(first),
              (0...255).contains(second),
              (0...255).contains(third),
              (0...255).contains(fourth)
        else {
            return false
        }

        if first == 10 {
            return true
        }
        if first == 172 && (16...31).contains(second) {
            return true
        }
        if first == 192 && second == 168 {
            return true
        }
        if first == 169 && second == 254 {
            return true
        }
        return false
    }

    private func gatewayDiscoverProviderModels(
        baseUrl: String,
        apiKey: String?
    ) async throws -> [ProviderSeedModel] {
        if let hooks = Self.gatewayHooks, let discoverProviderModels = hooks.discoverProviderModels {
            return try await discoverProviderModels(baseUrl, apiKey)
        }
        return try await discoverProviderModels(baseUrl: baseUrl, apiKey: apiKey)
    }

    private func discoverProviderModels(
        baseUrl: String,
        apiKey: String?,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) async throws -> [ProviderSeedModel] {
        guard let url = Self.providerModelsEndpointURL(baseUrl: baseUrl) else {
            throw ProviderDiscoveryError.invalidURL(baseUrl)
        }

        let localEndpoint = Self.isLikelyLocalEndpoint(baseUrl)
        let retryDelaysMs = localEndpoint ? [0, 150, 400, 900] : [0]
        var lastError: ProviderDiscoveryError?

        for (index, delayMs) in retryDelaysMs.enumerated() {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = localEndpoint ? 4 : 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await fetch(request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderDiscoveryError.invalidResponse
                }

                guard (200...299).contains(http.statusCode) else {
                    let detail = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ProviderDiscoveryError.httpFailure(
                        statusCode: http.statusCode,
                        detail: detail?.isEmpty == true ? nil : detail
                    )
                }

                return try Self.parseProviderModelSeeds(from: data)
            } catch let discoveryError as ProviderDiscoveryError {
                lastError = discoveryError
                guard index < retryDelaysMs.count - 1,
                    Self.shouldRetryProviderDiscovery(discoveryError)
                else {
                    throw discoveryError
                }
            } catch {
                let mapped = Self.mapProviderDiscoveryError(error, endpoint: url.absoluteString)
                lastError = mapped
                guard index < retryDelaysMs.count - 1,
                    Self.shouldRetryProviderDiscovery(mapped)
                else {
                    throw mapped
                }
            }
        }

        throw lastError ?? .unreachable(url.absoluteString)
    }

    private static func providerModelsEndpointURL(baseUrl: String) -> URL? {
        guard var components = URLComponents(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = trimmedPath.isEmpty ? "/models" : "/\(trimmedPath)/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func parseProviderModelSeeds(from data: Data) throws -> [ProviderSeedModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderDiscoveryError.malformedPayload
        }

        let candidates: [Any]
        if let dataModels = root["data"] as? [Any] {
            candidates = dataModels
        } else if let legacyModels = root["models"] as? [Any] {
            candidates = legacyModels
        } else {
            throw ProviderDiscoveryError.malformedPayload
        }

        var seen = Set<String>()
        var models: [ProviderSeedModel] = []
        models.reserveCapacity(candidates.count)

        for candidate in candidates {
            let entry: [String: Any]
            if let dict = candidate as? [String: Any] {
                entry = dict
            } else if let modelId = candidate as? String {
                entry = ["id": modelId, "name": modelId]
            } else {
                continue
            }

            let id =
                (entry["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (entry["model"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (entry["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            guard !id.isEmpty else { continue }
            guard seen.insert(id).inserted else { continue }

            let name =
                (entry["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? id
            let reasoning = (entry["reasoning"] as? Bool) ?? inferReasoningSupport(from: id)
            let contextWindow = parseInt(entry["contextWindow"] ?? entry["context_window"] ?? entry["contextLength"])
            let maxTokens = parseInt(
                entry["maxTokens"]
                    ?? entry["max_tokens"]
                    ?? entry["maxOutputTokens"]
                    ?? entry["max_completion_tokens"]
            )
            models.append(
                ProviderSeedModel(
                    id: id,
                    name: name.isEmpty ? id : name,
                    reasoning: reasoning,
                    contextWindow: contextWindow,
                    maxTokens: maxTokens
                )
            )
        }

        return models
    }

    private static func mapProviderDiscoveryError(_ error: Error, endpoint: String) -> ProviderDiscoveryError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .requestTimeout(endpoint)
            case NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost:
                return .unreachable(endpoint)
            default:
                return .unreachable(endpoint)
            }
        }
        return .unreachable(endpoint)
    }

    private static func shouldRetryProviderDiscovery(_ error: ProviderDiscoveryError) -> Bool {
        switch error {
        case .requestTimeout, .unreachable, .invalidResponse:
            return true
        case .httpFailure(let statusCode, _):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .invalidURL, .malformedPayload, .noModelsFound:
            return false
        }
    }

    private static func readinessReason(for discoveryError: ProviderDiscoveryError) -> ProviderReadinessReason {
        switch discoveryError {
        case .requestTimeout, .unreachable:
            return .unreachable
        case .noModelsFound:
            return .noModels
        case .invalidURL, .invalidResponse, .httpFailure, .malformedPayload:
            return .invalidConfig
        }
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value > 0 ? value : nil
        }
        if let value = raw as? Double {
            let intValue = Int(value)
            return intValue > 0 ? intValue : nil
        }
        if let value = raw as? String, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed > 0 ? parsed : nil
        }
        return nil
    }

    private static func inferReasoningSupport(from modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return lower.contains("reason")
            || lower.contains("think")
            || lower.contains("r1")
            || lower.hasPrefix("o1")
            || lower.hasPrefix("o3")
            || lower.hasPrefix("o4")
    }

    private static func configuredProviderModels(
        providerId: String,
        baseURL: String,
        apiCompatibility: String,
        discoveredModels: [ProviderSeedModel]
    ) -> [ProviderSeedModel] {
        if !discoveredModels.isEmpty {
            return discoveredModels
        }

        let normalizedProviderID = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedAPI = apiCompatibility
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedProviderID {
        case "moonshot":
            guard normalizedAPI == "openai-completions",
                  isMoonshotEndpoint(baseURL)
            else {
                return discoveredModels
            }

            return [
                ProviderSeedModel(
                    id: "kimi-k2.5",
                    name: "Kimi K2.5",
                    reasoning: false,
                    contextWindow: 256_000,
                    maxTokens: 8_192
                )
            ]
        case "kimi-coding":
            guard normalizedAPI == "anthropic-messages",
                  isKimiCodingEndpoint(baseURL)
            else {
                return discoveredModels
            }

            return [
                ProviderSeedModel(
                    id: "k2p5",
                    name: "Kimi K2.5",
                    reasoning: true
                )
            ]
        default:
            return discoveredModels
        }
    }

    private static func isMoonshotEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.lowercased()
        else {
            return false
        }
        return host == "api.moonshot.ai"
            || host == "api.moonshot.cn"
            || host.hasSuffix(".moonshot.ai")
            || host.hasSuffix(".moonshot.cn")
    }

    private static func isKimiCodingEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return false
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Canonical endpoint used by OpenClaw/pi-ai for Kimi Coding.
        if host == "api.kimi.com" || host.hasSuffix(".kimi.com") {
            return normalizedPath == "/coding"
                || normalizedPath == "/coding/"
                || normalizedPath.hasPrefix("/coding/")
        }

        // Backward-compatibility with older Moonshot Anthropic-style endpoint.
        if isMoonshotEndpoint(rawURL) {
            return normalizedPath == "/anthropic"
                || normalizedPath == "/anthropic/"
                || normalizedPath.hasPrefix("/anthropic/")
        }

        return false
    }

    private static func isLegacyKimiCodingEndpoint(_ rawURL: String) -> Bool {
        guard isMoonshotEndpoint(rawURL),
              let components = URLComponents(string: rawURL)
        else {
            return false
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kimiCodingLegacyPaths.contains(normalizedPath) {
            return true
        }
        return normalizedPath.hasPrefix("/anthropic/")
    }

    private static func isMinimaxHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedHost == "api.minimax.io"
            || normalizedHost.hasSuffix(".minimax.io")
            || normalizedHost == "api.minimaxi.com"
            || normalizedHost.hasSuffix(".minimaxi.com")
    }

    private static func minimaxCanonicalBaseURL(for host: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost == "api.minimaxi.com" || normalizedHost.hasSuffix(".minimaxi.com") {
            return "https://api.minimaxi.com/anthropic"
        }
        return "https://api.minimax.io/anthropic"
    }

    private static func isLegacyMinimaxEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host,
              isMinimaxHost(host)
        else {
            return false
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedPath.isEmpty || normalizedPath == "/" {
            return true
        }
        if normalizedPath == "/v1"
            || normalizedPath == "/v1/"
            || normalizedPath.hasPrefix("/v1/")
        {
            return true
        }
        return false
    }

    private static func isMinimaxAnthropicEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host,
              isMinimaxHost(host)
        else {
            return false
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedPath == "/anthropic"
            || normalizedPath == "/anthropic/"
            || normalizedPath.hasPrefix("/anthropic/")
    }

    private static func canonicalProviderBaseURL(providerId: String, baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerId == "kimi-coding" || providerId == "minimax" else {
            return trimmed
        }

        switch providerId {
        case "kimi-coding":
            if isLegacyKimiCodingEndpoint(trimmed) {
                return kimiCodingCanonicalBaseURL
            }
            return trimmed
        case "minimax":
            guard let components = URLComponents(string: trimmed),
                  let host = components.host,
                  isMinimaxHost(host)
            else {
                return trimmed
            }
            if isLegacyMinimaxEndpoint(trimmed) || isMinimaxAnthropicEndpoint(trimmed) {
                return minimaxCanonicalBaseURL(for: host)
            }
            return trimmed
        default:
            return trimmed
        }
    }

    private static func canonicalProviderAPICompatibility(
        providerId: String,
        baseURL: String,
        apiCompatibility: String
    ) -> String {
        let trimmed = apiCompatibility.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerId == "minimax" else {
            return trimmed
        }
        guard isLegacyMinimaxEndpoint(baseURL) || isMinimaxAnthropicEndpoint(baseURL) else {
            return trimmed
        }
        return "anthropic-messages"
    }

    private static func desiredAllowlistEntries(
        providerId: String,
        configuredModels: [ProviderSeedModel]
    ) -> [String: [String: Any]] {
        let normalizedProviderID = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedProviderID {
        case "moonshot":
            guard let model = configuredModels.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }) else {
                return [:]
            }

            let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelRef = "\(normalizedProviderID)/\(modelID)"
            return [modelRef: ["alias": "Kimi"]]
        case "kimi-coding":
            var entries: [String: [String: Any]] = [:]
            for model in configuredModels {
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty else { continue }

                let alias: String?
                switch modelID.lowercased() {
                case "k2p5":
                    alias = "Kimi K2.5"
                default:
                    alias = nil
                }

                guard let alias else { continue }
                entries["\(normalizedProviderID)/\(modelID)"] = ["alias": alias]
            }
            return entries
        default:
            return [:]
        }
    }

    private static func missingAllowlistEntries(
        from config: [String: OpenClawProtocol.AnyCodable]?,
        desired: [String: [String: Any]]
    ) -> [String: [String: Any]] {
        guard !desired.isEmpty else {
            return [:]
        }

        let configuredModelsSection: [String: OpenClawProtocol.AnyCodable]? = {
            guard let config,
                  let agentsSection = config["agents"]?.value as? [String: OpenClawProtocol.AnyCodable],
                  let defaultsSection = agentsSection["defaults"]?.value as? [String: OpenClawProtocol.AnyCodable],
                  let modelsSection = defaultsSection["models"]?.value as? [String: OpenClawProtocol.AnyCodable]
            else {
                return nil
            }
            return modelsSection
        }()

        return desired.reduce(into: [String: [String: Any]]()) { partialResult, entry in
            if configuredModelsSection?[entry.key] == nil {
                partialResult[entry.key] = entry.value
            }
        }
    }

    private static func localProviderPlaceholderAPIKey(for providerID: String) -> String {
        let sanitized = providerID
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if sanitized.isEmpty {
            return "local-provider"
        }
        return "\(sanitized)-local"
    }

    private static func isLocalPlaceholderAPIKey(_ apiKey: String, providerId: String) -> Bool {
        let normalizedProviderID = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedKey = apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedKey == localProviderPlaceholderAPIKey(for: normalizedProviderID)
    }

    public func markAllChannelNotificationsRead() {
        // Product policy: unread is only cleared by explicit user action.
        notificationService.markAllAsRead()
    }

    public func pauseNotificationPolling() {
        notificationService.pauseListening()
    }

    public func resumeNotificationPolling() {
        notificationService.resumeListening()
    }

    public func setHeartbeat(enabled: Bool) async throws {
        do {
            try await gatewaySetHeartbeats(enabled: enabled)
            heartbeatEnabled = enabled
            if let heartbeatInfo = try? await gatewayHeartbeatStatus() {
                heartbeatEnabled = heartbeatInfo.enabled ?? enabled
                heartbeatLastTimestamp = heartbeatInfo.lastHeartbeatAt
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func updateConfiguration(_ config: OpenClawConfiguration) {
        configuration = config
        saveConfiguration()

        if configuration.autoSyncMCPBridge {
            scheduleMCPBridgeAutoSync(reason: "configuration updated", debounce: false)
        } else {
            mcpBridgeAutoSyncTask?.cancel()
            mcpBridgeAutoSyncTask = nil
        }

        if !configuration.isEnabled {
            phase = .notConfigured
            disconnect()
            return
        }

        if gatewayStatus == .running {
            phase = isConnected ? .connected : .gatewayRunning
        } else {
            phase = .configured
        }
    }

    public func saveConfiguration() {
        OpenClawConfigurationStore.save(configuration)
    }

    public func generateAuthToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let token = String((0..<48).compactMap { _ in alphabet.randomElement() })
        _ = OpenClawKeychain.saveToken(token)
        return token
    }

    /// Syncs keychain auth with the most authoritative local gateway credential,
    /// clears any stale SDK device token, then reconnects. Local credential
    /// priority is: device-auth file, paired registry, legacy config, then
    /// launch-agent environment token.
    public func syncTokenFromGatewayConfig() async throws {
        guard synchronizeLocalGatewayToken(clearSDKDeviceToken: true) else {
            throw NSError(
                domain: "OpenClawManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "No valid device token found. Re-pair with: openclaw devices rotate"]
            )
        }
        try await connect()
    }

    public func channelMeta(for channelId: String) -> ChannelMeta? {
        channelStatus?.channelMeta.first(where: { $0.id == channelId })
    }

    public func channelAccounts(for channelId: String) -> [ChannelAccountSnapshot] {
        channelStatus?.channelAccounts[channelId] ?? []
    }

    public func channelDetailLabel(for channelId: String) -> String? {
        channelMeta(for: channelId)?.detailLabel ?? channelStatus?.channelDetailLabels[channelId]
    }

    public func channelDefaultAccountId(for channelId: String) -> String? {
        channelStatus?.channelDefaultAccountId[channelId]
    }

    private func disconnectInternal() async {
        await cancelPendingAuthFailureToast(reason: "disconnect")
        await cancelPendingReconnectToast(reason: "disconnect")
        reconnectToastShownForCurrentCycle = false
        heartbeatStatusMethodUnsupported = false
        skillsBinsRoleUnauthorized = false
        stopHealthMonitoring()
        if let id = eventListenerID {
            await OpenClawGatewayConnection.shared.removeEventListener(id)
            eventListenerID = nil
        }
        await OpenClawGatewayConnection.shared.disconnect()
        heartbeatEnabled = true
        heartbeatLastTimestamp = nil
        connectionState = .disconnected
        channels = []
        channelStatus = nil
        availableModels = []
        configuredProviders = []
        providerReadinessOverrides = [:]
        cronStatus = nil
        cronJobs = []
        cronRunsByJobID = [:]
        skillsAgents = []
        selectedSkillsAgentId = nil
        skillsReport = nil
        skillsBins = []
        connectedClients = []
        activeSessions = []
        lastHealth = nil
        trackedPID = nil
        runToSessionKey = [:]
        resetHealthFailureTracking()
        notificationService.stopListening()

        if configuration.isEnabled {
            phase = gatewayStatus == .running ? .gatewayRunning : .configured
        } else {
            phase = .notConfigured
        }
        postConnectionChanged()
    }

    private func installEventListener() async {
        if let id = eventListenerID {
            await OpenClawGatewayConnection.shared.removeEventListener(id)
            eventListenerID = nil
        }
        let id = await OpenClawGatewayConnection.shared.addEventListener { [weak self] push in
            guard case let .event(frame) = push else { return }
            await MainActor.run {
                self?.activityStore.processEventFrame(frame)
                self?.ingestActiveSessionEvent(frame)
                self?.notificationService.ingestEvent(frame)
                self?.scheduleEventDrivenRefreshIfNeeded(frame)
            }
        }
        eventListenerID = id
    }

    private func scheduleEventDrivenRefreshIfNeeded(_ frame: EventFrame) {
        let eventName = frame.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard eventName == "channels.status.update" || eventName == "sessions.update" else {
            return
        }
        guard gatewayEventRefreshTask == nil else { return }

        gatewayEventRefreshTask = Task { [weak self] in
            defer {
                self?.gatewayEventRefreshTask = nil
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.isConnected else { return }
            await self.refreshStatus()
        }
    }

    private func installConnectionStateListener() async {
        if let existingID = gatewayConnectionListenerID {
            await OpenClawGatewayConnection.shared.removeConnectionStateListener(existingID)
        }

        let id = await OpenClawGatewayConnection.shared.addConnectionStateListener { [weak self] state in
            await self?.handleConnectionState(state)
        }
        gatewayConnectionListenerID = id
    }

    private func installMCPProviderStatusListener() {
        if let observer = mcpProviderStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        mcpProviderStatusObserver = NotificationCenter.default.addObserver(
            forName: .mcpProviderStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleMCPBridgeAutoSync(reason: "provider status changed")
            }
        }
    }

    private func emitToastEvent(_ event: ToastEvent) {
        toastEventSink(event)
    }

    private func cancelPendingReconnectToast(reason: String) async {
        guard pendingReconnectToastTask != nil || pendingReconnectToastAttempt != nil else { return }
        pendingReconnectToastTask?.cancel()
        pendingReconnectToastTask = nil
        let attempt = pendingReconnectToastAttempt
        pendingReconnectToastAttempt = nil
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.connection.reconnectToast.cancelled",
            context: [
                "reason": reason,
                "attempt": attempt.map(String.init) ?? "<none>",
            ]
        )
    }

    private func scheduleDeferredReconnectToast(attempt: Int) async {
        if pendingReconnectToastAttempt == attempt, pendingReconnectToastTask != nil {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.reconnectToast.duplicateSuppressed",
                context: ["attempt": "\(attempt)"]
            )
            return
        }

        if pendingReconnectToastTask != nil || pendingReconnectToastAttempt != nil {
            await cancelPendingReconnectToast(reason: "reschedule")
        }

        let delayNs = Self.effectiveReconnectToastDelayNanoseconds
        pendingReconnectToastAttempt = attempt
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.connection.reconnectToast.scheduled",
            context: [
                "attempt": "\(attempt)",
                "delayMs": "\(delayNs / 1_000_000)",
            ]
        )

        pendingReconnectToastTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                return
            }
            await self?.flushPendingReconnectToast(expectedAttempt: attempt)
        }
    }

    private func flushPendingReconnectToast(expectedAttempt: Int) async {
        guard pendingReconnectToastAttempt == expectedAttempt else { return }
        pendingReconnectToastTask = nil
        pendingReconnectToastAttempt = nil

        let shouldEmit: Bool = switch connectionState {
        case .reconnecting(let attempt):
            attempt == expectedAttempt
        default:
            false
        }

        if shouldEmit {
            reconnectToastShownForCurrentCycle = true
            emitToastEvent(.reconnecting(attempt: expectedAttempt))
            await emitStartupDiagnostic(
                level: .info,
                event: "openclaw.connection.reconnectToast.emitted",
                context: [
                    "attempt": "\(expectedAttempt)",
                    "connectionState": connectionStateLabel(connectionState),
                ]
            )
        } else {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.reconnectToast.suppressed",
                context: [
                    "attempt": "\(expectedAttempt)",
                    "connectionState": connectionStateLabel(connectionState),
                ]
            )
        }
    }

    private func cancelPendingAuthFailureToast(reason: String) async {
        guard pendingAuthFailureToastTask != nil || pendingAuthFailureToastMessage != nil else { return }
        pendingAuthFailureToastTask?.cancel()
        pendingAuthFailureToastTask = nil
        let message = pendingAuthFailureToastMessage
        pendingAuthFailureToastMessage = nil
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.connection.authFailureToast.cancelled",
            context: [
                "reason": reason,
                "message": message ?? "<none>",
            ]
        )
    }

    private func scheduleDeferredAuthFailureToast(message: String) async {
        if pendingAuthFailureToastMessage == message, pendingAuthFailureToastTask != nil {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.authFailureToast.duplicateSuppressed",
                context: ["message": message]
            )
            return
        }

        if pendingAuthFailureToastTask != nil || pendingAuthFailureToastMessage != nil {
            await cancelPendingAuthFailureToast(reason: "reschedule")
        }

        let delayNs = Self.effectiveAuthFailureToastDelayNanoseconds
        pendingAuthFailureToastMessage = message
        await emitStartupDiagnostic(
            level: .warning,
            event: "openclaw.connection.authFailureToast.scheduled",
            context: [
                "message": message,
                "delayMs": "\(delayNs / 1_000_000)",
            ]
        )

        pendingAuthFailureToastTask = Task { [weak self, message] in
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                return
            }
            await self?.flushPendingAuthFailureToast(expectedMessage: message)
        }
    }

    private func flushPendingAuthFailureToast(expectedMessage: String) async {
        guard pendingAuthFailureToastMessage == expectedMessage else { return }
        pendingAuthFailureToastTask = nil
        pendingAuthFailureToastMessage = nil

        let shouldEmit = switch connectionState {
        case .failed(let message):
            Self.isAuthFailureMessage(message)
        default:
            false
        }

        if shouldEmit {
            emitToastEvent(.failed(expectedMessage))
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.connection.authFailureToast.emitted",
                context: [
                    "message": expectedMessage,
                    "connectionState": connectionStateLabel(connectionState),
                ]
            )
        } else {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.authFailureToast.suppressed",
                context: [
                    "message": expectedMessage,
                    "connectionState": connectionStateLabel(connectionState),
                ]
            )
        }
    }

    private static var effectiveAuthFailureToastDelayNanoseconds: UInt64 {
#if DEBUG
        if let override = authFailureToastDelayNanosecondsOverride {
            return override
        }
#endif
        return authFailureToastDelayNanoseconds
    }

    private static var effectiveReconnectToastDelayNanoseconds: UInt64 {
#if DEBUG
        if let override = reconnectToastDelayNanosecondsOverride {
            return override
        }
#endif
        return reconnectToastDelayNanoseconds
    }

    private func emitStartupDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "openclaw-manager",
            event: event,
            context: context
        )
    }

    private func gatewayStatusLabel(_ status: GatewayStatus) -> String {
        switch status {
        case .stopped:
            return "stopped"
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .failed:
            return "failed"
        }
    }

    private func connectionStateLabel(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .failed:
            return "failed"
        }
    }

    private func observedGatewayConnectionStateLabel(_ state: OpenClawGatewayConnectionState) -> String {
        switch state {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .reconnected:
            return "reconnected"
        case .failed:
            return "failed"
        }
    }

    private func handleConnectionState(_ state: OpenClawGatewayConnectionState) async {
        let previousObservedState = lastObservedGatewayConnectionState
        if let previous = previousObservedState, previous == state {
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.state.duplicate",
                context: [
                    "state": observedGatewayConnectionStateLabel(state),
                    "gatewayStatus": gatewayStatusLabel(gatewayStatus),
                    "connectionState": connectionStateLabel(connectionState),
                ]
            )
            return
        }

        let previousStateLabel = previousObservedState.map(observedGatewayConnectionStateLabel) ?? "none"
        lastObservedGatewayConnectionState = state

        var diagnosticContext: [String: String] = [
            "state": observedGatewayConnectionStateLabel(state),
            "previousState": previousStateLabel,
            "gatewayStatus": gatewayStatusLabel(gatewayStatus),
        ]

        switch state {
        case .disconnected:
            await cancelPendingAuthFailureToast(reason: "state-disconnected")
            await cancelPendingReconnectToast(reason: "state-disconnected")
            reconnectToastShownForCurrentCycle = false
            if connectionState == .connected {
                emitToastEvent(.disconnected)
            }
            connectionState = .disconnected
            phase = gatewayStatus == .running ? .gatewayRunning : .configured
            stopHealthMonitoring()
            notificationService.stopListening()
            heartbeatEnabled = true
            heartbeatLastTimestamp = nil
            onboardingState = .unknown
            resetHealthFailureTracking()
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.connection.state.disconnected",
                context: diagnosticContext
            )

        case .connecting:
            await cancelPendingAuthFailureToast(reason: "state-connecting")
            await cancelPendingReconnectToast(reason: "state-connecting")
            reconnectToastShownForCurrentCycle = false
            if connectionState != .connecting {
                phase = .connecting
            }
            connectionState = .connecting
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.connection.state.connecting",
                context: diagnosticContext
            )

        case .connected:
            await cancelPendingAuthFailureToast(reason: "state-connected")
            await cancelPendingReconnectToast(reason: "state-connected")
            let suppressConnectedToastAfterReconnected: Bool = if case .some(.reconnected) = previousObservedState {
                true
            } else {
                false
            }
            connectionState = .connected
            phase = .connected
            if hasCustomGatewayURL, gatewayStatus != .running {
                gatewayStatus = .running
                postGatewayStatusChanged()
            }
            lastError = nil
            resetHealthFailureTracking()
            startHealthMonitoring()
            notificationService.startListening()
            await refreshStatus()
            await refreshOnboardingState(force: true)
            scheduleMCPBridgeAutoSync(reason: "gateway connected")
            if !suppressConnectedToastAfterReconnected {
                emitToastEvent(.connected)
            }
            reconnectToastShownForCurrentCycle = false
            diagnosticContext["connectedToastSuppressedAfterReconnected"] =
                suppressConnectedToastAfterReconnected ? "true" : "false"
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            await emitStartupDiagnostic(
                level: .info,
                event: "openclaw.connection.state.connected",
                context: diagnosticContext
            )

        case .reconnecting(let attempt):
            await cancelPendingAuthFailureToast(reason: "state-reconnecting")
            reconnectToastShownForCurrentCycle = false
            connectionState = .reconnecting(attempt: attempt)
            phase = .reconnecting(attempt: attempt)
            await scheduleDeferredReconnectToast(attempt: attempt)
            diagnosticContext["attempt"] = "\(attempt)"
            diagnosticContext["toastMode"] = "deferred"
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.connection.state.reconnecting",
                context: diagnosticContext
            )

        case .reconnected:
            await cancelPendingAuthFailureToast(reason: "state-reconnected")
            await cancelPendingReconnectToast(reason: "state-reconnected")
            connectionState = .connected
            phase = .connected
            if hasCustomGatewayURL, gatewayStatus != .running {
                gatewayStatus = .running
                postGatewayStatusChanged()
            }
            notificationService.startListening()
            let shouldEmitReconnectedToast = reconnectToastShownForCurrentCycle
            if shouldEmitReconnectedToast {
                emitToastEvent(.reconnected)
            }
            reconnectToastShownForCurrentCycle = false
            resetHealthFailureTracking()
            await refreshStatus()
            await refreshOnboardingState(force: true)
            scheduleMCPBridgeAutoSync(reason: "gateway reconnected")
            diagnosticContext["reconnectedToastEmitted"] = shouldEmitReconnectedToast ? "true" : "false"
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            await emitStartupDiagnostic(
                level: .info,
                event: "openclaw.connection.state.reconnected",
                context: diagnosticContext
            )

        case .failed(let message):
            await cancelPendingReconnectToast(reason: "state-failed")
            reconnectToastShownForCurrentCycle = false
            connectionState = .failed(message)
            phase = .connectionFailed(message)
            onboardingState = .unknown
            // Auth failures mean the gateway process is still running but rejected our
            // token. Don't mark the gateway as failed — doing so hides the "Sync Token"
            // button and shows "Start Gateway" instead, which is the wrong recovery path.
            let isAuthFailure = Self.isAuthFailureMessage(message)
            if !isAuthFailure {
                gatewayStatus = .failed(message)
            }
            lastError = message
            notificationService.stopListening()
            if isAuthFailure {
                await scheduleDeferredAuthFailureToast(message: message)
            } else {
                await cancelPendingAuthFailureToast(reason: "state-failed-non-auth")
                emitToastEvent(.failed(message))
            }
            postGatewayStatusChanged()
            diagnosticContext["connectionState"] = connectionStateLabel(connectionState)
            diagnosticContext["error"] = message
            diagnosticContext["authFailure"] = isAuthFailure ? "true" : "false"
            diagnosticContext["toastMode"] = isAuthFailure ? "deferred" : "immediate"
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.connection.state.failed",
                context: diagnosticContext
            )
        }

        postConnectionChanged()
    }

    private func startHealthMonitoring() {
        stopHealthMonitoring()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollHealth()
            }
        }
    }

    private func stopHealthMonitoring() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func pollHealth() async {
        let shouldPoll: Bool
        switch connectionState {
        case .connected, .reconnecting:
            shouldPoll = true
        default:
            shouldPoll = false
        }
        guard shouldPoll else { return }
        let pollStartedAt = Date()
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.poll.begin",
            context: [
                "connectionState": connectionStateLabel(connectionState),
                "gatewayStatus": gatewayStatusLabel(gatewayStatus),
            ]
        )
        do {
            let health = try await gatewayHealth()
            updateHealth(from: health)
            resetHealthFailureTracking()
            let elapsedMs = Int(Date().timeIntervalSince(pollStartedAt) * 1000)
            await emitStartupDiagnostic(
                level: .debug,
                event: "openclaw.poll.success",
                context: ["elapsedMs": "\(elapsedMs)"]
            )

            if let expectedPID = trackedPID,
                let currentPID = health["pid"]?.value as? Int,
                expectedPID != currentPID
            {
                trackedPID = currentPID
                connectionState = .reconnecting(attempt: 1)
                phase = .reconnecting(attempt: 1)
                postConnectionChanged()
                do {
                    try await performGatewayConnect()
                    resetHealthFailureTracking()
                    connectionState = .connected
                    phase = .connected
                    await refreshStatus()
                    postConnectionChanged()
                    await emitStartupDiagnostic(
                        level: .warning,
                        event: "openclaw.poll.pidChanged.reconnect.succeeded",
                        context: [
                            "expectedPid": "\(expectedPID)",
                            "currentPid": "\(currentPID)",
                        ]
                    )
                } catch {
                    connectionState = .failed(error.localizedDescription)
                    phase = .connectionFailed(error.localizedDescription)
                    lastError = error.localizedDescription
                    postConnectionChanged()
                    await emitStartupDiagnostic(
                        level: .error,
                        event: "openclaw.poll.pidChanged.reconnect.failed",
                        context: [
                            "expectedPid": "\(expectedPID)",
                            "currentPid": "\(currentPID)",
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
        } catch {
            guard gatewayStatus == .running else { return }
            let message = "Health check failed: \(error.localizedDescription)"
            lastError = message
            let failureAttempt = registerHealthFailure()
            let elapsedMs = Int(Date().timeIntervalSince(pollStartedAt) * 1000)
            await emitStartupDiagnostic(
                level: .warning,
                event: "openclaw.poll.failed",
                context: [
                    "attempt": "\(failureAttempt)",
                    "elapsedMs": "\(elapsedMs)",
                    "error": message,
                ]
            )

            // If the WebSocket already appears connected, try to re-establish it.
            // Treat a few consecutive failures as transient before declaring
            // a hard gateway failure.
            let shouldAttemptReconnect: Bool
            switch connectionState {
            case .connected, .reconnecting:
                shouldAttemptReconnect = true
            default:
                shouldAttemptReconnect = false
            }

            if shouldAttemptReconnect {
                connectionState = .reconnecting(attempt: failureAttempt)
                phase = .reconnecting(attempt: failureAttempt)
                postConnectionChanged()
                do {
                    try await performGatewayConnect()
                    resetHealthFailureTracking()
                    connectionState = .connected
                    phase = .connected
                    lastError = nil
                    postConnectionChanged()
                    await emitStartupDiagnostic(
                        level: .info,
                        event: "openclaw.poll.reconnect.succeeded",
                        context: [
                            "attempt": "\(failureAttempt)"
                        ]
                    )
                    return
                } catch {
                    // Fall through to failure handling below.
                    await emitStartupDiagnostic(
                        level: .warning,
                        event: "openclaw.poll.reconnect.failed",
                        context: [
                            "attempt": "\(failureAttempt)",
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }

            if failureAttempt < Self.healthFailureThreshold {
                connectionState = .reconnecting(attempt: failureAttempt)
                phase = .reconnecting(attempt: failureAttempt)
                postConnectionChanged()
                await emitStartupDiagnostic(
                    level: .warning,
                    event: "openclaw.poll.retrying",
                    context: [
                        "attempt": "\(failureAttempt)",
                        "threshold": "\(Self.healthFailureThreshold)",
                    ]
                )
                return
            }

            connectionState = .failed(message)
            gatewayStatus = .failed(message)
            phase = .gatewayFailed(message)
            postConnectionChanged()
            postGatewayStatusChanged()
            emitToastEvent(.failed(message))
            await emitStartupDiagnostic(
                level: .error,
                event: "openclaw.poll.thresholdReached",
                context: [
                    "attempt": "\(failureAttempt)",
                    "threshold": "\(Self.healthFailureThreshold)",
                    "error": message,
                ]
            )
        }
    }

    /// Reconnects the WebSocket, using the test hook when available.
    private func performGatewayConnect() async throws {
        let endpoints = try resolveGatewayEndpoints()
        let preferLocalGatewaySources = !hasCustomGatewayURL && Self.isLoopbackGatewayURL(endpoints.webSocketURL)
        if preferLocalGatewaySources {
            _ = synchronizeLocalGatewayToken(clearSDKDeviceToken: false)
        }
        let credentialResolution = resolveGatewayCredential(preferLocalGatewaySources: preferLocalGatewaySources)
        var reconnectContext: [String: String] = [
            "webSocketURL": endpoints.webSocketURL.absoluteString,
            "healthURL": endpoints.healthURL?.absoluteString ?? "<none>",
            "preferLocalCredentialSources": preferLocalGatewaySources ? "true" : "false",
            "credentialConfigured": credentialResolution.credential?.isEmpty == false ? "true" : "false",
            "credentialSource": credentialResolution.source.rawValue,
        ]
        reconnectContext.merge(credentialResolution.availability.diagnosticsContext()) { _, new in new }
        await emitStartupDiagnostic(
            level: .debug,
            event: "openclaw.reconnect.begin",
            context: reconnectContext
        )
        try await gatewayConnect(
            url: endpoints.webSocketURL,
            token: credentialResolution.credential,
            healthURL: endpoints.healthURL
        )
        await installEventListener()
    }

    private func gatewayConnect(
        url: URL,
        token: String?,
        healthURL: URL?
    ) async throws {
        if let hooks = Self.gatewayHooks, let connectHook = hooks.gatewayConnect {
            try await connectHook()
            return
        }
        try await OpenClawGatewayConnection.shared.connect(
            url: url,
            token: token,
            healthURL: healthURL
        )
    }

    private func fetchHealthOverHTTP() async throws -> [String: OpenClawProtocol.AnyCodable] {
        let endpoints = try resolveGatewayEndpoints()
        guard let url = endpoints.healthURL else {
            throw NSError(domain: "OpenClawManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid health URL."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw NSError(
                domain: "OpenClawManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Health endpoint returned a non-200 status."]
            )
        }
        // The gateway HTTP server does not expose a dedicated /health JSON endpoint —
        // any HTTP 200 confirms the process is up. Try to decode a JSON body for
        // optional fields (e.g. pid) but treat decode failures as an empty payload
        // rather than an error, since the control-UI SPA fallback may serve HTML.
        return (try? JSONDecoder().decode([String: OpenClawProtocol.AnyCodable].self, from: data)) ?? [:]
    }

    private struct GatewayEndpoints {
        let webSocketURL: URL
        let healthURL: URL?
    }

    private func resolveGatewayEndpoints() throws -> GatewayEndpoints {
        let fallbackPort = OpenClawEnvironment.gatewayPort(from: configuration)
        let trimmedURL = configuration.gatewayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedURL.isEmpty {
            guard let ws = URL(string: "ws://127.0.0.1:\(fallbackPort)/ws"),
                  let health = URL(string: "http://127.0.0.1:\(fallbackPort)/health")
            else {
                throw NSError(
                    domain: "OpenClawManager",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to build default gateway endpoint URLs."]
                )
            }
            return GatewayEndpoints(webSocketURL: ws, healthURL: health)
        }

        guard let wsURL = Self.normalizedWebSocketURL(from: trimmedURL, fallbackPort: fallbackPort) else {
            throw NSError(
                domain: "OpenClawManager",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Invalid gateway URL: \(trimmedURL)"]
            )
        }

        let trimmedHealthURL = configuration.gatewayHealthURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let healthURL: URL?
        if trimmedHealthURL.isEmpty {
            healthURL = Self.defaultHealthURL(from: wsURL)
        } else {
            guard let normalized = Self.normalizedHealthURL(from: trimmedHealthURL) else {
                throw NSError(
                    domain: "OpenClawManager",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid gateway health URL: \(trimmedHealthURL)"]
                )
            }
            healthURL = normalized
        }

        return GatewayEndpoints(webSocketURL: wsURL, healthURL: healthURL)
    }

    private func resetHealthFailureTracking() {
        consecutiveHealthFailures = 0
        lastHealthFailureAt = nil
    }

    private func registerHealthFailure(now: Date = .init()) -> Int {
        if let lastHealthFailureAt,
           now.timeIntervalSince(lastHealthFailureAt) > Self.healthFailureWindowSeconds
        {
            consecutiveHealthFailures = 0
        }
        consecutiveHealthFailures += 1
        lastHealthFailureAt = now
        return consecutiveHealthFailures
    }

    private static func normalizedWebSocketURL(from raw: String, fallbackPort: Int) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let rawScheme = components.scheme?.lowercased()
        else {
            return nil
        }

        switch rawScheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            return nil
        }

        if components.port == nil {
            components.port = fallbackPort > 0 ? fallbackPort : nil
        }
        if components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || components.path == "/" {
            components.path = "/ws"
        }
        return components.url
    }

    private static func normalizedHealthURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased()
        else {
            return nil
        }
        switch scheme {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }
        return components.url
    }

    private static func defaultHealthURL(from webSocketURL: URL) -> URL? {
        guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else {
            return nil
        }
        switch scheme {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            return nil
        }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func channelInfo(from payload: [String: OpenClawProtocol.AnyCodable]) -> ChannelInfo {
        ChannelInfo(
            id: (payload["id"]?.value as? String) ?? UUID().uuidString,
            name: (payload["name"]?.value as? String) ?? "Unknown",
            systemImage: (payload["systemImage"]?.value as? String)
                ?? "antenna.radiowaves.left.and.right",
            isLinked: boolValue(payload["isLinked"]?.value),
            isConnected: boolValue(payload["isConnected"]?.value)
        )
    }

    private func boolValue(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? Int { return value != 0 }
        if let value = raw as? String {
            return ["1", "true", "yes", "y", "linked", "connected"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        return false
    }

    private func updateHealth(from payload: [String: OpenClawProtocol.AnyCodable]) {
        let uptimeMs = doubleValue(payload["uptimeMs"]?.value) ?? 0
        let memoryMB = doubleValue(payload["memoryMB"]?.value)
            ?? doubleValue(payload["memoryMb"]?.value)
            ?? 0
        let activeRuns = payload["activeRuns"]?.value as? Int ?? 0
        let version = payload["version"]?.value as? String ?? "unknown"
        let pid = payload["pid"]?.value as? Int

        if let pid {
            trackedPID = trackedPID ?? pid
        }

        lastHealth = OpenClawGatewayHealth(
            uptime: uptimeMs / 1000,
            memoryMB: memoryMB,
            activeRuns: activeRuns,
            version: version,
            pid: pid,
            timestamp: Date()
        )
    }

    private func ingestActiveSessionEvent(_ frame: EventFrame) {
        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return
        }
        let eventMeta = frame.eventmeta ?? [:]
        let stream = stringValue(payload["stream"]?.value)
            ?? stringValue(eventMeta["stream"]?.value)
        let runId = stringValue(payload["runId"]?.value)
            ?? stringValue(eventMeta["runId"]?.value)
            ?? stringValue(eventMeta["runid"]?.value)
        guard let stream, let runId else { return }

        let streamName = stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable] ?? [:]
        let explicitSessionKey = stringValue(eventMeta["sessionKey"]?.value)
            ?? stringValue(eventMeta["sessionkey"]?.value)
            ?? stringValue(payload["sessionKey"]?.value)
            ?? stringValue(payload["sessionkey"]?.value)
            ?? stringValue(data["sessionKey"]?.value)
            ?? stringValue(data["sessionkey"]?.value)
        if let explicitSessionKey, !explicitSessionKey.isEmpty {
            runToSessionKey[runId] = explicitSessionKey
        }

        guard let sessionKey = runToSessionKey[runId], !sessionKey.isEmpty else { return }
        let timestamp = parseEventTimestamp(payload["ts"]?.value) ?? Date()
        let metadata = OpenClawSessionManager.shared.sessions.first(where: { $0.key == sessionKey })
        let sessionTitle = normalizedTitle(metadata?.title, fallback: sessionKey)
        let sessionModel = normalizedString(metadata?.model) ?? stringValue(data["model"]?.value)

        switch streamName {
        case "lifecycle":
            let phase = stringValue(data["phase"]?.value)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                ?? stringValue(eventMeta["phase"]?.value)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                ?? ""
            if phase == "end" || phase == "error" {
                removeActiveSession(for: sessionKey)
                runToSessionKey.removeValue(forKey: runId)
                return
            }
            upsertActiveSession(
                for: sessionKey,
                title: sessionTitle,
                model: sessionModel,
                status: .thinking,
                usage: resolveUsage(data: data, metadata: metadata),
                updatedAt: timestamp
            )

        case "tool":
            let phase = stringValue(data["phase"]?.value)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                ?? ""
            if phase == "result" {
                upsertActiveSession(
                    for: sessionKey,
                    title: sessionTitle,
                    model: sessionModel,
                    status: .responding,
                    usage: resolveUsage(data: data, metadata: metadata),
                    updatedAt: timestamp
                )
                return
            }

            let toolName = normalizedString(stringValue(data["name"]?.value)) ?? "unknown"
            upsertActiveSession(
                for: sessionKey,
                title: sessionTitle,
                model: sessionModel,
                status: .usingTool(toolName),
                usage: resolveUsage(data: data, metadata: metadata),
                updatedAt: timestamp
            )

        case "assistant":
            upsertActiveSession(
                for: sessionKey,
                title: sessionTitle,
                model: sessionModel,
                status: .responding,
                usage: resolveUsage(data: data, metadata: metadata),
                updatedAt: timestamp
            )

        case "thinking":
            upsertActiveSession(
                for: sessionKey,
                title: sessionTitle,
                model: sessionModel,
                status: .thinking,
                usage: resolveUsage(data: data, metadata: metadata),
                updatedAt: timestamp
            )

        default:
            break
        }
    }

    private func upsertActiveSession(
        for key: String,
        title: String,
        model: String?,
        status: ActiveSessionStatus,
        usage: ActiveSessionUsage?,
        updatedAt: Date
    ) {
        let existing = activeSessions.first(where: { $0.key == key })
        let merged = ActiveSessionInfo(
            key: key,
            title: title,
            model: normalizedString(model) ?? existing?.model,
            status: status,
            usage: usage ?? existing?.usage,
            updatedAt: updatedAt
        )

        if let index = activeSessions.firstIndex(where: { $0.key == key }) {
            activeSessions[index] = merged
        } else {
            activeSessions.append(merged)
        }
        activeSessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func removeActiveSession(for key: String) {
        activeSessions.removeAll { $0.key == key }
    }

    private func parseEventTimestamp(_ raw: Any?) -> Date? {
        if let ms = intValue(raw), ms > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let value = doubleValue(raw), value > 0 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return nil
    }

    private func resolveUsage(
        data: [String: OpenClawProtocol.AnyCodable],
        metadata: OpenClawSessionManager.GatewaySession?
    ) -> ActiveSessionUsage? {
        var input: Int? = intValue(data["inputTokens"]?.value) ?? intValue(data["input"]?.value)
        var output: Int? = intValue(data["outputTokens"]?.value) ?? intValue(data["output"]?.value)
        var total: Int? = intValue(data["totalTokens"]?.value) ?? intValue(data["total"]?.value)

        if let usage = data["usage"]?.value as? [String: OpenClawProtocol.AnyCodable] {
            input = input
                ?? intValue(usage["input"]?.value)
                ?? intValue(usage["inputTokens"]?.value)
            output = output
                ?? intValue(usage["output"]?.value)
                ?? intValue(usage["outputTokens"]?.value)
            total = total
                ?? intValue(usage["total"]?.value)
                ?? intValue(usage["totalTokens"]?.value)
        }

        if total == nil, let contextTokens = metadata?.contextTokens {
            total = contextTokens
        }

        if input == nil, output == nil, total == nil {
            return nil
        }
        return ActiveSessionUsage(inputTokens: input, outputTokens: output, totalTokens: total)
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? Double {
            return Int(value)
        }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let value = raw as? String {
            return value
        }
        return String(describing: raw)
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func normalizedTitle(_ value: String?, fallback: String) -> String {
        normalizedString(value) ?? fallback
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private func gatewayChannelsStatus() async throws -> [GatewayPayload] {
        if let hooks = Self.gatewayHooks {
            return try await hooks.channelsStatus()
        }
        return try await OpenClawGatewayConnection.shared.channelsStatus()
    }

    private func gatewayChannelsStatusDetailed() async throws -> ChannelsStatusResult? {
        if let hooks = Self.gatewayHooks {
            if let detailed = hooks.channelsStatusDetailed {
                return try await detailed()
            }
            return nil
        }
        return try await OpenClawGatewayConnection.shared.channelsStatusDetailed()
    }

    private func channelInfos(from snapshot: ChannelsStatusResult) -> [ChannelInfo] {
        var ids = snapshot.channelOrder
        let knownIDs = Set(ids)
        let discoveredIDs = snapshot.channelAccounts.keys.sorted().filter { !knownIDs.contains($0) }
        ids.append(contentsOf: discoveredIDs)

        let metaByID = Dictionary(uniqueKeysWithValues: snapshot.channelMeta.map { ($0.id, $0) })
        return ids.map { id in
            let accounts = snapshot.channelAccounts[id] ?? []
            let linked = accounts.contains { $0.linked || $0.configured }
            let connected = accounts.contains { $0.connected || $0.running }
            let name = metaByID[id]?.label ?? snapshot.channelLabels[id] ?? id.capitalized
            let systemImage =
                metaByID[id]?.systemImage
                ?? snapshot.channelSystemImages[id]
                ?? "antenna.radiowaves.left.and.right"
            return ChannelInfo(
                id: id,
                name: name,
                systemImage: systemImage,
                isLinked: linked,
                isConnected: connected
            )
        }
    }

    private func gatewayModelsList() async throws -> [OpenClawProtocol.ModelChoice] {
        if let hooks = Self.gatewayHooks {
            return try await hooks.modelsList()
        }
        return try await OpenClawGatewayConnection.shared.modelsListFull()
    }

    private func gatewayHealth() async throws -> GatewayPayload {
        if let hooks = Self.gatewayHooks {
            return try await hooks.health()
        }
        return try await OpenClawGatewayConnection.shared.health()
    }

    private func gatewayHeartbeatStatus() async throws -> OpenClawHeartbeatStatus {
        if heartbeatStatusMethodUnsupported {
            return OpenClawHeartbeatStatus(enabled: nil, lastHeartbeatAt: nil)
        }

        do {
            if let hooks = Self.gatewayHooks, let heartbeatStatus = hooks.heartbeatStatus {
                return try await heartbeatStatus()
            }
            return try await OpenClawGatewayConnection.shared.heartbeatStatus()
        } catch {
            if Self.isUnsupportedGatewayMethodError(error, method: "heartbeat.status") {
                if !heartbeatStatusMethodUnsupported {
                    await emitStartupDiagnostic(
                        level: .warning,
                        event: "openclaw.connection.capability.heartbeatStatus.unsupported",
                        context: ["error": error.localizedDescription]
                    )
                }
                heartbeatStatusMethodUnsupported = true
                return OpenClawHeartbeatStatus(enabled: nil, lastHeartbeatAt: nil)
            }
            throw error
        }
    }

    private func gatewaySetHeartbeats(enabled: Bool) async throws {
        if let hooks = Self.gatewayHooks, let setHeartbeats = hooks.setHeartbeats {
            try await setHeartbeats(enabled)
            return
        }
        try await OpenClawGatewayConnection.shared.setHeartbeats(enabled: enabled)
    }

    private func gatewayCronStatus() async throws -> OpenClawCronStatus {
        if let hooks = Self.gatewayHooks, let cronStatus = hooks.cronStatus {
            return try await cronStatus()
        }
        return try await OpenClawGatewayConnection.shared.cronStatus()
    }

    private func gatewayCronList() async throws -> [OpenClawCronJob] {
        if let hooks = Self.gatewayHooks, let cronList = hooks.cronList {
            return try await cronList()
        }
        return try await OpenClawGatewayConnection.shared.cronList()
    }

    private func gatewayCronRuns(jobId: String, limit: Int) async throws -> [OpenClawCronRunLogEntry] {
        if let hooks = Self.gatewayHooks, let cronRuns = hooks.cronRuns {
            return try await cronRuns(jobId, limit)
        }
        return try await OpenClawGatewayConnection.shared.cronRuns(jobId: jobId, limit: limit)
    }

    private func gatewayCronRun(jobId: String) async throws {
        if let hooks = Self.gatewayHooks, let cronRun = hooks.cronRun {
            try await cronRun(jobId)
            return
        }
        try await OpenClawGatewayConnection.shared.cronRun(jobId: jobId)
    }

    private func gatewayCronSetEnabled(jobId: String, enabled: Bool) async throws {
        if let hooks = Self.gatewayHooks, let cronSetEnabled = hooks.cronSetEnabled {
            try await cronSetEnabled(jobId, enabled)
            return
        }
        try await OpenClawGatewayConnection.shared.cronSetEnabled(jobId: jobId, enabled: enabled)
    }

    private func gatewayAgentsList() async throws -> OpenClawGatewayAgentsListResponse {
        if let hooks = Self.gatewayHooks, let agentsList = hooks.agentsList {
            return try await agentsList()
        }
        return try await OpenClawGatewayConnection.shared.agentsList()
    }

    private func gatewayAgentsFilesList(agentId: String) async throws -> OpenClawAgentFilesListResponse {
        if let hooks = Self.gatewayHooks, let agentsFilesList = hooks.agentsFilesList {
            return try await agentsFilesList(agentId)
        }
        return try await OpenClawGatewayConnection.shared.agentsFilesList(agentId: agentId)
    }

    private func gatewayAgentsFileGet(agentId: String, name: String) async throws -> OpenClawAgentFileGetResponse {
        if let hooks = Self.gatewayHooks, let agentsFileGet = hooks.agentsFileGet {
            return try await agentsFileGet(agentId, name)
        }
        return try await OpenClawGatewayConnection.shared.agentsFileGet(agentId: agentId, name: name)
    }

    private func gatewayAgentsFileSet(
        agentId: String,
        name: String,
        content: String
    ) async throws -> OpenClawAgentFileSetResponse {
        if let hooks = Self.gatewayHooks, let agentsFileSet = hooks.agentsFileSet {
            return try await agentsFileSet(agentId, name, content)
        }
        return try await OpenClawGatewayConnection.shared.agentsFileSet(
            agentId: agentId,
            name: name,
            content: content
        )
    }

    private func gatewaySkillsStatus(agentId: String? = nil) async throws -> OpenClawSkillStatusReport {
        if let hooks = Self.gatewayHooks, let skillsStatus = hooks.skillsStatus {
            return try await skillsStatus()
        }
        return try await OpenClawGatewayConnection.shared.skillsStatus(agentId: agentId)
    }

    private func gatewaySkillsBins() async throws -> [String] {
        if skillsBinsRoleUnauthorized {
            return []
        }

        do {
            if let hooks = Self.gatewayHooks, let skillsBins = hooks.skillsBins {
                return try await skillsBins()
            }
            return try await OpenClawGatewayConnection.shared.skillsBins()
        } catch {
            if Self.isGatewayRoleUnauthorizedError(error) {
                if !skillsBinsRoleUnauthorized {
                    await emitStartupDiagnostic(
                        level: .warning,
                        event: "openclaw.connection.capability.skillsBins.unauthorizedRole",
                        context: ["error": error.localizedDescription]
                    )
                }
                skillsBinsRoleUnauthorized = true
                return []
            }
            throw error
        }
    }

    private func gatewaySkillsInstall(
        name: String,
        installId: String,
        timeoutMs: Int?
    ) async throws -> OpenClawSkillInstallResult {
        if let hooks = Self.gatewayHooks, let skillsInstall = hooks.skillsInstall {
            return try await skillsInstall(name, installId, timeoutMs)
        }
        return try await OpenClawGatewayConnection.shared.skillsInstall(
            name: name,
            installId: installId,
            timeoutMs: timeoutMs
        )
    }

    private func gatewaySkillsUpdate(
        skillKey: String,
        enabled: Bool?,
        apiKey: String?,
        env: [String: String]?
    ) async throws -> OpenClawSkillUpdateResult {
        if let hooks = Self.gatewayHooks, let skillsUpdateDetailed = hooks.skillsUpdateDetailed {
            return try await skillsUpdateDetailed(skillKey, enabled, apiKey, env)
        }
        // Preserve existing test hook behavior for enabled-only updates.
        if apiKey == nil, env == nil, let hooks = Self.gatewayHooks, let skillsUpdate = hooks.skillsUpdate {
            return try await skillsUpdate(skillKey, enabled)
        }
        return try await OpenClawGatewayConnection.shared.skillsUpdate(
            skillKey: skillKey,
            enabled: enabled,
            apiKey: apiKey,
            env: env
        )
    }

    private func gatewaySystemPresence() async throws -> [OpenClawPresenceEntry] {
        if let hooks = Self.gatewayHooks, let systemPresence = hooks.systemPresence {
            return try await systemPresence()
        }
        return try await OpenClawGatewayConnection.shared.systemPresence()
    }

    private func gatewayConfigGetFull() async throws -> ConfigGetResult {
        if let hooks = Self.gatewayHooks, let configGetFull = hooks.configGetFull {
            return try await configGetFull()
        }
        return try await OpenClawGatewayConnection.shared.configGetFull()
    }

    private func gatewayConfigPatch(raw: String, baseHash: String) async throws -> ConfigPatchResult {
        if let hooks = Self.gatewayHooks, let configPatch = hooks.configPatch {
            return try await configPatch(raw, baseHash)
        }
        return try await OpenClawGatewayConnection.shared.configPatch(raw: raw, baseHash: baseHash)
    }

    private func gatewayChannelsLogout(channelId: String, accountId: String?) async throws {
        if let hooks = Self.gatewayHooks, let channelsLogout = hooks.channelsLogout {
            try await channelsLogout(channelId, accountId)
            return
        }
        try await OpenClawGatewayConnection.shared.channelsLogout(channelId: channelId, accountId: accountId)
    }

    private func resolveTargetAgentId(_ agentId: String?) async throws -> String {
        if let explicit = normalizedString(agentId) {
            return explicit
        }
        if let selected = normalizedString(selectedSkillsAgentId) {
            return selected
        }
        let response = try await gatewayAgentsList()
        return response.defaultId
    }

    private func resolveMCPBridgeProviderEntries(
        override providerEntriesOverride: [OpenClawMCPBridge.ProviderEntry]?
    ) -> [OpenClawMCPBridge.ProviderEntry] {
        if let providerEntriesOverride {
            return providerEntriesOverride
        }
        let providerManager = MCPProviderManager.shared
        return providerManager.configuration.enabledProviders.map { provider in
            var headers = provider.resolvedHeaders()
            let hasAuthorizationHeader = headers.keys.contains {
                $0.caseInsensitiveCompare("Authorization") == .orderedSame
            }
            if !hasAuthorizationHeader,
               let token = provider.getToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty
            {
                headers["Authorization"] = "Bearer \(token)"
            }

            return OpenClawMCPBridge.ProviderEntry(
                name: provider.name,
                url: provider.url,
                headers: headers
            )
        }
    }

    private func scheduleMCPBridgeAutoSync(reason: String, debounce: Bool = true) {
        guard configuration.autoSyncMCPBridge else { return }
        guard isConnected else { return }
        guard !mcpBridgeIsSyncing else { return }

        mcpBridgeAutoSyncTask?.cancel()
        mcpBridgeAutoSyncTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.mcpBridgeAutoSyncDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.performMCPBridgeAutoSync(reason: reason)
        }
    }

    private func performMCPBridgeAutoSync(reason: String) async {
        guard configuration.autoSyncMCPBridge else { return }
        guard isConnected else { return }
        guard !mcpBridgeIsSyncing else { return }
        // In tests, avoid falling through to live gateway calls when only partial
        // hooks are installed for unrelated assertions.
        if let hooks = Self.gatewayHooks,
           hooks.skillsUpdateDetailed == nil,
           hooks.skillsUpdate == nil
        {
            return
        }

        do {
            _ = try await syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: nil,
                outputURLOverride: nil,
                mode: .automatic,
                allowUnownedOverwrite: false
            )
        } catch {
            guard mcpBridgeLastSyncErrorState == nil else { return }
            setMCPBridgeSyncErrorState(
                code: .automaticSyncSkipped,
                message: "Automatic MCP sync skipped (\(reason)): \(error.localizedDescription)",
                retryable: true,
                mode: .automatic
            )
        }
    }

#if DEBUG
    static func _testSetGatewayHooks(_ hooks: GatewayHooks?) {
        gatewayHooks = hooks
    }

    static func _testSetLocalTokenSyncHook(
        _ hook: (@Sendable (_ clearSDKDeviceToken: Bool) -> Bool)?
    ) {
        localTokenSyncHook = hook
    }

    static func _testSetToastSink(_ sink: @escaping @MainActor (ToastEvent) -> Void) {
        shared.toastEventSink = sink
    }

    static func _testResetToastSink() {
        shared.toastEventSink = OpenClawManager.emitDefaultToastEvent
    }

    static func _testSetAuthFailureToastDelayNanoseconds(_ value: UInt64?) {
        authFailureToastDelayNanosecondsOverride = value
    }

    static func _testSetReconnectToastDelayNanoseconds(_ value: UInt64?) {
        reconnectToastDelayNanosecondsOverride = value
    }

    func _testHandleConnectionState(_ state: OpenClawGatewayConnectionState) async {
        await handleConnectionState(state)
    }

    func _testEmitToast(_ event: ToastEvent) {
        emitToastEvent(event)
    }

    func _testPollHealth() async {
        await pollHealth()
    }

    func _testSetConnectionState(
        _ state: ConnectionState,
        gatewayStatus: GatewayStatus = .running
    ) {
        self.connectionState = state
        self.gatewayStatus = gatewayStatus
        self.resetHealthFailureTracking()
        switch state {
        case .connected:
            phase = .connected
        case .connecting:
            phase = .connecting
        case .reconnecting(let attempt):
            phase = .reconnecting(attempt: attempt)
        case .failed(let message):
            phase = .connectionFailed(message)
        case .disconnected:
            phase = gatewayStatus == .running ? .gatewayRunning : .configured
        }
        if state != .connected {
            onboardingState = .unknown
        }
    }

    func _testSetProviderState(
        availableModels: [OpenClawProtocol.ModelChoice],
        configuredProviders: [ProviderInfo],
        readinessOverrides: [String: ProviderReadinessReason] = [:]
    ) {
        self.availableModels = availableModels
        self.configuredProviders = configuredProviders
        self.providerReadinessOverrides = readinessOverrides
    }

    func _testDiscoverProviderModels(
        baseUrl: String,
        apiKey: String?,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> [ProviderSeedModel] {
        try await discoverProviderModels(
            baseUrl: baseUrl,
            apiKey: apiKey,
            fetch: fetch
        )
    }

    func _testSetConfiguration(_ config: OpenClawConfiguration) {
        self.configuration = config
    }

    func _testResetConnectionObservation() async {
        lastObservedGatewayConnectionState = nil
        await cancelPendingAuthFailureToast(reason: "test-reset")
        await cancelPendingReconnectToast(reason: "test-reset")
        reconnectToastShownForCurrentCycle = false
        heartbeatStatusMethodUnsupported = false
        skillsBinsRoleUnauthorized = false
        onboardingState = .unknown
    }

    nonisolated static func _testShouldAttemptLocalAuthRecovery(
        message: String,
        endpoint: URL,
        hasCustomGatewayURL: Bool
    ) -> Bool {
        shouldAttemptLocalAuthRecovery(
            message: message,
            endpoint: endpoint,
            hasCustomGatewayURL: hasCustomGatewayURL
        )
    }

    static func _testGatewayCredentialSourceOrder(
        keychainAuth: String?,
        keychainDevice: String?,
        launchAgent: String?,
        deviceAuthFile: String?,
        pairedRegistry: String?,
        legacyConfig: String?,
        preferLocalGatewaySources: Bool
    ) -> [String] {
        buildGatewayCredentialCandidates(
            keychainAuth: keychainAuth,
            keychainDevice: keychainDevice,
            launchAgent: launchAgent,
            deviceAuthFile: deviceAuthFile,
            pairedRegistry: pairedRegistry,
            legacyConfig: legacyConfig,
            preferLocalGatewaySources: preferLocalGatewaySources
        )
        .candidates
        .map { $0.source.rawValue }
    }
#endif

    // MARK: - Device Token Helpers

    private static func readPlistGatewayToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/ai.openclaw.gateway.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: String],
              let token = env["OPENCLAW_GATEWAY_TOKEN"],
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func readDeviceAuthToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".openclaw/identity/device-auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let operator_ = tokens["operator"] as? [String: Any],
              let token = operator_["token"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func readPairedDeviceToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let deviceURL = home.appendingPathComponent(".openclaw/identity/device.json")
        guard let deviceData = try? Data(contentsOf: deviceURL),
              let deviceJson = try? JSONSerialization.jsonObject(with: deviceData) as? [String: Any],
              let deviceId = deviceJson["deviceId"] as? String
        else { return nil }
        let pairedURL = home.appendingPathComponent(".openclaw/devices/paired.json")
        guard let pairedData = try? Data(contentsOf: pairedURL),
              let pairedJson = try? JSONSerialization.jsonObject(with: pairedData) as? [String: Any],
              let device = pairedJson[deviceId] as? [String: Any],
              let tokens = device["tokens"] as? [String: Any],
              let operator_ = tokens["operator"] as? [String: Any],
              let token = operator_["token"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    private static func readLegacyGatewayConfigToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent(".openclaw/openclaw.json"),
            home.appendingPathComponent(".openclaw/clawdbot.json"),
            home.appendingPathComponent(".clawdbot/clawdbot.json"),
        ]
        for url in candidates {
            guard
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let gateway = json["gateway"] as? [String: Any]
            else { continue }

            let token: String? =
                (gateway["auth"] as? [String: Any])?["token"] as? String
                ?? gateway["deviceToken"] as? String
            if let token, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private enum GatewayCredentialSource: String {
        case localLaunchAgent = "local-launch-agent-plist"
        case localDeviceAuth = "local-device-auth-file"
        case localPairedRegistry = "local-paired-registry"
        case localLegacyConfig = "local-legacy-config"
        case keychainAuth = "keychain-auth"
        case keychainDeviceAuth = "keychain-device-auth"
        case none = "none"
    }

    private struct GatewayCredentialAvailability {
        let keychainAuthPresent: Bool
        let keychainDeviceAuthPresent: Bool
        let launchAgentCredentialPresent: Bool
        let deviceAuthFileCredentialPresent: Bool
        let pairedRegistryCredentialPresent: Bool
        let legacyConfigCredentialPresent: Bool

        func diagnosticsContext() -> [String: String] {
            [
                "keychainAuthPresent": keychainAuthPresent ? "true" : "false",
                "keychainDeviceAuthPresent": keychainDeviceAuthPresent ? "true" : "false",
                "launchAgentCredentialPresent": launchAgentCredentialPresent ? "true" : "false",
                "deviceAuthFileCredentialPresent": deviceAuthFileCredentialPresent ? "true" : "false",
                "pairedRegistryCredentialPresent": pairedRegistryCredentialPresent ? "true" : "false",
                "legacyConfigCredentialPresent": legacyConfigCredentialPresent ? "true" : "false",
            ]
        }
    }

    private struct GatewayCredentialResolution {
        let credential: String?
        let source: GatewayCredentialSource
        let availability: GatewayCredentialAvailability
    }

    private struct GatewayCredentialCandidate {
        let credential: String
        let source: GatewayCredentialSource
    }

    private struct GatewayCredentialCandidates {
        let candidates: [GatewayCredentialCandidate]
        let availability: GatewayCredentialAvailability
    }

    private static func readAuthoritativeLocalGatewayCredential() -> (value: String, source: GatewayCredentialSource)? {
        if let value = readDeviceAuthToken() { return (value, .localDeviceAuth) }
        if let value = readPairedDeviceToken() { return (value, .localPairedRegistry) }
        if let value = readLegacyGatewayConfigToken() { return (value, .localLegacyConfig) }
        if let value = readPlistGatewayToken() { return (value, .localLaunchAgent) }
        return nil
    }

    private static func normalizedGatewayCredential(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func isLoopbackGatewayURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    @discardableResult
    private func synchronizeLocalGatewayToken(clearSDKDeviceToken: Bool) -> Bool {
#if DEBUG
        if let hook = Self.localTokenSyncHook {
            return hook(clearSDKDeviceToken)
        }
#endif
        if clearSDKDeviceToken {
            let identity = DeviceIdentityStore.loadOrCreate()
            DeviceAuthStore.clearToken(deviceId: identity.deviceId, role: "operator")
            _ = OpenClawKeychain.deleteDeviceToken()
        }

        guard let credential = Self.readAuthoritativeLocalGatewayCredential(), !credential.value.isEmpty else {
            return false
        }
        if OpenClawKeychain.getToken() != credential.value {
            _ = OpenClawKeychain.saveToken(credential.value)
        }
        return true
    }

    private func resolveGatewayCredentialCandidates(
        preferLocalGatewaySources: Bool = false
    ) -> GatewayCredentialCandidates {
        Self.buildGatewayCredentialCandidates(
            keychainAuth: OpenClawKeychain.getToken(),
            keychainDevice: OpenClawKeychain.getDeviceToken(),
            launchAgent: Self.readPlistGatewayToken(),
            deviceAuthFile: Self.readDeviceAuthToken(),
            pairedRegistry: Self.readPairedDeviceToken(),
            legacyConfig: Self.readLegacyGatewayConfigToken(),
            preferLocalGatewaySources: preferLocalGatewaySources
        )
    }

    private static func buildGatewayCredentialCandidates(
        keychainAuth: String?,
        keychainDevice: String?,
        launchAgent: String?,
        deviceAuthFile: String?,
        pairedRegistry: String?,
        legacyConfig: String?,
        preferLocalGatewaySources: Bool
    ) -> GatewayCredentialCandidates {
        let normalizedKeychainAuth = normalizedGatewayCredential(keychainAuth)
        let normalizedKeychainDevice = normalizedGatewayCredential(keychainDevice)
        let normalizedLaunchAgent = normalizedGatewayCredential(launchAgent)
        let normalizedDeviceAuthFile = normalizedGatewayCredential(deviceAuthFile)
        let normalizedPairedRegistry = normalizedGatewayCredential(pairedRegistry)
        let normalizedLegacyConfig = normalizedGatewayCredential(legacyConfig)

        let availability = GatewayCredentialAvailability(
            keychainAuthPresent: normalizedKeychainAuth != nil,
            keychainDeviceAuthPresent: normalizedKeychainDevice != nil,
            launchAgentCredentialPresent: normalizedLaunchAgent != nil,
            deviceAuthFileCredentialPresent: normalizedDeviceAuthFile != nil,
            pairedRegistryCredentialPresent: normalizedPairedRegistry != nil,
            legacyConfigCredentialPresent: normalizedLegacyConfig != nil
        )

        let orderedCandidates: [(String?, GatewayCredentialSource)] = if preferLocalGatewaySources {
            [
                (normalizedDeviceAuthFile, .localDeviceAuth),
                (normalizedPairedRegistry, .localPairedRegistry),
                (normalizedLegacyConfig, .localLegacyConfig),
                (normalizedLaunchAgent, .localLaunchAgent),
                (normalizedKeychainDevice, .keychainDeviceAuth),
                (normalizedKeychainAuth, .keychainAuth),
            ]
        } else {
            [
                (normalizedKeychainAuth, .keychainAuth),
                (normalizedKeychainDevice, .keychainDeviceAuth),
                (normalizedDeviceAuthFile, .localDeviceAuth),
                (normalizedPairedRegistry, .localPairedRegistry),
                (normalizedLegacyConfig, .localLegacyConfig),
                (normalizedLaunchAgent, .localLaunchAgent),
            ]
        }

        var seen = Set<String>()
        var resolved: [GatewayCredentialCandidate] = []
        for (value, source) in orderedCandidates {
            guard let value else { continue }
            guard seen.insert(value).inserted else { continue }
            resolved.append(GatewayCredentialCandidate(credential: value, source: source))
        }

        return GatewayCredentialCandidates(candidates: resolved, availability: availability)
    }

    private func resolveGatewayCredential(
        preferLocalGatewaySources: Bool = false
    ) -> GatewayCredentialResolution {
        let resolved = resolveGatewayCredentialCandidates(preferLocalGatewaySources: preferLocalGatewaySources)
        if let first = resolved.candidates.first {
            return GatewayCredentialResolution(
                credential: first.credential,
                source: first.source,
                availability: resolved.availability
            )
        }
        return GatewayCredentialResolution(credential: nil, source: .none, availability: resolved.availability)
    }

    private nonisolated static func shouldAttemptLocalAuthRecovery(
        message: String,
        endpoint: URL,
        hasCustomGatewayURL: Bool
    ) -> Bool {
        guard !hasCustomGatewayURL, isLoopbackGatewayURL(endpoint) else {
            return false
        }
        return isAuthFailureMessage(message)
    }

    private func shouldAttemptLocalAuthRecovery(for message: String, endpoint: URL) -> Bool {
        Self.shouldAttemptLocalAuthRecovery(
            message: message,
            endpoint: endpoint,
            hasCustomGatewayURL: hasCustomGatewayURL
        )
    }

    private nonisolated static func isAuthFailureMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("device token mismatch")
            || lower.contains("device_token_mismatch")
            || lower.contains("token mismatch")
            || lower.contains("authentication failed")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("reconfigure credentials")
            || lower.contains("auth failed")
    }

    private nonisolated static func isUnsupportedGatewayMethodError(_ error: Error, method: String) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("unknown method") && lower.contains(method.lowercased())
    }

    private nonisolated static func isGatewayRoleUnauthorizedError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("unauthorized role")
            || (lower.contains("unauthorized") && lower.contains("role"))
    }

    private func resolveGatewayToken(preferLocalGatewaySources: Bool = false) -> String? {
        resolveGatewayCredential(preferLocalGatewaySources: preferLocalGatewaySources).credential
    }

    private func postGatewayStatusChanged() {
        NotificationCenter.default.post(name: .openClawGatewayStatusChanged, object: nil)
    }

    private func postModelsChanged() {
        NotificationCenter.default.post(name: .openClawModelsChanged, object: nil)
    }

    private func postConnectionChanged() {
        NotificationCenter.default.post(name: .openClawConnectionChanged, object: nil)
    }
}
