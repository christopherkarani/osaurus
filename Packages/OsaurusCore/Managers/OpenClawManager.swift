//
//  OpenClawManager.swift
//  osaurus
//

import Combine
import Foundation
import OpenClawKit
import OpenClawProtocol

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

@MainActor
public final class OpenClawManager: ObservableObject {
    typealias GatewayPayload = [String: OpenClawProtocol.AnyCodable]
    typealias ToastEventSink = @MainActor (ToastEvent) -> Void

    struct GatewayHooks {
        var channelsStatus: @Sendable () async throws -> [GatewayPayload]
        var channelsStatusDetailed: (@Sendable () async throws -> ChannelsStatusResult)? = nil
        var channelsLogout: (@Sendable (_ channelId: String, _ accountId: String?) async throws -> Void)? = nil
        var modelsList: @Sendable () async throws -> [String]
        var health: @Sendable () async throws -> GatewayPayload
        var heartbeatStatus: (@Sendable () async throws -> OpenClawHeartbeatStatus)?
        var setHeartbeats: (@Sendable (Bool) async throws -> Void)?
        var cronStatus: (@Sendable () async throws -> OpenClawCronStatus)? = nil
        var cronList: (@Sendable () async throws -> [OpenClawCronJob])? = nil
        var cronRuns: (@Sendable (_ jobId: String, _ limit: Int) async throws -> [OpenClawCronRunLogEntry])? = nil
        var cronRun: (@Sendable (_ jobId: String) async throws -> Void)? = nil
        var cronSetEnabled: (@Sendable (_ jobId: String, _ enabled: Bool) async throws -> Void)? = nil
        var skillsStatus: (@Sendable () async throws -> OpenClawSkillStatusReport)? = nil
        var skillsBins: (@Sendable () async throws -> [String])? = nil
        var skillsInstall: (@Sendable (_ name: String, _ installId: String, _ timeoutMs: Int?) async throws -> OpenClawSkillInstallResult)? = nil
        var skillsUpdate: (@Sendable (_ skillKey: String, _ enabled: Bool?) async throws -> OpenClawSkillUpdateResult)? = nil
        var systemPresence: (@Sendable () async throws -> [OpenClawPresenceEntry])? = nil
    }

    nonisolated(unsafe) static var gatewayHooks: GatewayHooks?

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
    @Published public private(set) var availableModels: [String] = []
    @Published public private(set) var cronStatus: OpenClawCronStatus?
    @Published public private(set) var cronJobs: [OpenClawCronJob] = []
    @Published public private(set) var cronRunsByJobID: [String: [OpenClawCronRunLogEntry]] = [:]
    @Published public private(set) var skillsReport: OpenClawSkillStatusReport?
    @Published public private(set) var skillsBins: [String] = []
    @Published public private(set) var connectedClients: [OpenClawPresenceEntry] = []
    @Published public private(set) var activeSessions: [ActiveSessionInfo] = []
    @Published public private(set) var lastHealth: OpenClawGatewayHealth?
    @Published public private(set) var lastError: String?

    public let activityStore = OpenClawActivityStore()

    private var healthMonitorTask: Task<Void, Never>?
    private var trackedPID: Int?
    private var eventListenerID: UUID?
    private var runToSessionKey: [String: String] = [:]
    private var gatewayConnectionListenerID: UUID?
    private let notificationService = OpenClawNotificationService.shared
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

    private init() {
        let loadedConfiguration = OpenClawConfigurationStore.load()
        self.configuration = loadedConfiguration
        self.phase = loadedConfiguration.isEnabled ? .configured : .notConfigured

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
            }
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
        if !configuration.isEnabled {
            configuration.isEnabled = true
            saveConfiguration()
        }

        gatewayStatus = .starting
        phase = .startingGateway
        postGatewayStatusChanged()

        if let error = await OpenClawLaunchAgent.install(
            port: OpenClawEnvironment.gatewayPort(from: configuration),
            bindMode: configuration.bindMode
        ) {
            gatewayStatus = .failed(error)
            phase = .gatewayFailed(error)
            lastError = error
            postGatewayStatusChanged()
            throw NSError(domain: "OpenClawManager", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }

        let deadline = Date().addingTimeInterval(15)
        var lastPollError: String?
        while Date() < deadline {
            do {
                let payload = try await fetchHealthOverHTTP()
                if let pid = payload["pid"]?.value as? Int {
                    trackedPID = pid
                }
                gatewayStatus = .running
                phase = isConnected ? .connected : .gatewayRunning
                lastError = nil
                postGatewayStatusChanged()
                emitToastEvent(.started)
                return
            } catch {
                lastPollError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let message = "Gateway did not respond within 15 seconds. \(lastPollError ?? "Unknown error.")"
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
        guard gatewayStatus == .running else {
            throw NSError(
                domain: "OpenClawManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Gateway is not running."]
            )
        }
        guard connectionState != .connected else { return }

        connectionState = .connecting
        phase = .connecting
        postConnectionChanged()

        do {
            try await OpenClawGatewayConnection.shared.connect(
                host: "127.0.0.1",
                port: OpenClawEnvironment.gatewayPort(from: configuration),
                token: OpenClawKeychain.getToken() ?? OpenClawKeychain.getDeviceToken()
            )
            await installEventListener()
            lastError = nil
        } catch {
            connectionState = .failed(error.localizedDescription)
            phase = .connectionFailed(error.localizedDescription)
            lastError = error.localizedDescription
            postConnectionChanged()
            throw error
        }
    }

    public func disconnect() {
        Task { [weak self] in
            await self?.disconnectInternal()
        }
    }

    public func refreshStatus() async {
        guard isConnected else { return }

        do {
            if let detailedStatus = try await gatewayChannelsStatusDetailed() {
                channelStatus = detailedStatus
                channels = channelInfos(from: detailedStatus)
                notificationService.ingestStatus(detailedStatus)
            } else {
                let channelPayload = try await gatewayChannelsStatus()
                channels = channelPayload.map(channelInfo(from:)).sorted { $0.name < $1.name }
                channelStatus = nil
            }

            let models = try await gatewayModelsList()
            if models != availableModels {
                availableModels = models
                postModelsChanged()
            }

            let health = try await gatewayHealth()
            updateHealth(from: health)
            postGatewayStatusChanged()

            if let heartbeatInfo = try? await gatewayHeartbeatStatus() {
                heartbeatEnabled = heartbeatInfo.enabled ?? heartbeatEnabled
                heartbeatLastTimestamp = heartbeatInfo.lastHeartbeatAt
            }
        } catch {
            let message = "Status refresh failed: \(error.localizedDescription)"
            lastError = message
            connectionState = .failed(message)
            phase = .connectionFailed(message)
            emitToastEvent(.failed(message))
            postConnectionChanged()
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
            skillsReport = try await gatewaySkillsStatus()
            skillsBins = try await gatewaySkillsBins()
        } catch {
            lastError = "Skills refresh failed: \(error.localizedDescription)"
        }
    }

    public func updateSkillEnabled(skillKey: String, enabled: Bool) async throws {
        _ = try await gatewaySkillsUpdate(skillKey: skillKey, enabled: enabled)
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
        cronStatus = nil
        cronJobs = []
        cronRunsByJobID = [:]
        skillsReport = nil
        skillsBins = []
        connectedClients = []
        activeSessions = []
        lastHealth = nil
        trackedPID = nil
        runToSessionKey = [:]
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
            }
        }
        eventListenerID = id
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

    private func emitToastEvent(_ event: ToastEvent) {
        toastEventSink(event)
    }

    private func handleConnectionState(_ state: OpenClawGatewayConnectionState) async {
        switch state {
        case .disconnected:
            if connectionState == .connected {
                emitToastEvent(.disconnected)
            }
            connectionState = .disconnected
            phase = gatewayStatus == .running ? .gatewayRunning : .configured
            stopHealthMonitoring()
            notificationService.stopListening()
            heartbeatEnabled = true
            heartbeatLastTimestamp = nil

        case .connecting:
            if connectionState != .connecting {
                phase = .connecting
            }
            connectionState = .connecting

        case .connected:
            connectionState = .connected
            phase = .connected
            lastError = nil
            startHealthMonitoring()
            notificationService.startListening()
            await refreshStatus()
            emitToastEvent(.connected)

        case .reconnecting(let attempt):
            connectionState = .reconnecting(attempt: attempt)
            phase = .reconnecting(attempt: attempt)
            emitToastEvent(.reconnecting(attempt: attempt))

        case .reconnected:
            connectionState = .connected
            phase = .connected
            notificationService.startListening()
            emitToastEvent(.reconnected)
            await refreshStatus()

        case .failed(let message):
            connectionState = .failed(message)
            phase = .connectionFailed(message)
            gatewayStatus = .failed(message)
            lastError = message
            notificationService.stopListening()
            emitToastEvent(.failed(message))
            postGatewayStatusChanged()
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
        guard isConnected else { return }
        do {
            let health = try await gatewayHealth()
            updateHealth(from: health)

            if let expectedPID = trackedPID,
                let currentPID = health["pid"]?.value as? Int,
                expectedPID != currentPID
            {
                trackedPID = currentPID
                connectionState = .reconnecting(attempt: 1)
                phase = .reconnecting(attempt: 1)
                postConnectionChanged()
                do {
                    try await OpenClawGatewayConnection.shared.connect(
                        host: "127.0.0.1",
                        port: OpenClawEnvironment.gatewayPort(from: configuration),
                        token: OpenClawKeychain.getToken() ?? OpenClawKeychain.getDeviceToken()
                    )
                    await installEventListener()
                    connectionState = .connected
                    phase = .connected
                    await refreshStatus()
                    postConnectionChanged()
                } catch {
                    connectionState = .failed(error.localizedDescription)
                    phase = .connectionFailed(error.localizedDescription)
                    lastError = error.localizedDescription
                    postConnectionChanged()
                }
            }
        } catch {
            if gatewayStatus == .running {
                let message = "Health check failed: \(error.localizedDescription)"
                connectionState = .failed(message)
                gatewayStatus = .failed(message)
                phase = .gatewayFailed(message)
                lastError = message
                postConnectionChanged()
                postGatewayStatusChanged()
            }
        }
    }

    private func fetchHealthOverHTTP() async throws -> [String: OpenClawProtocol.AnyCodable] {
        guard let url = URL(string: "http://127.0.0.1:\(OpenClawEnvironment.gatewayPort(from: configuration))/health")
        else {
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
        return try JSONDecoder().decode([String: OpenClawProtocol.AnyCodable].self, from: data)
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
        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable],
            let stream = payload["stream"]?.value as? String,
            let runId = payload["runId"]?.value as? String
        else {
            return
        }

        let streamName = stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable] ?? [:]
        let explicitSessionKey = stringValue(payload["sessionKey"]?.value)
            ?? stringValue(data["sessionKey"]?.value)
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

    private func gatewayModelsList() async throws -> [String] {
        if let hooks = Self.gatewayHooks {
            return try await hooks.modelsList()
        }
        return try await OpenClawGatewayConnection.shared.modelsList()
    }

    private func gatewayHealth() async throws -> GatewayPayload {
        if let hooks = Self.gatewayHooks {
            return try await hooks.health()
        }
        return try await OpenClawGatewayConnection.shared.health()
    }

    private func gatewayHeartbeatStatus() async throws -> OpenClawHeartbeatStatus {
        if let hooks = Self.gatewayHooks, let heartbeatStatus = hooks.heartbeatStatus {
            return try await heartbeatStatus()
        }
        return try await OpenClawGatewayConnection.shared.heartbeatStatus()
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

    private func gatewaySkillsStatus() async throws -> OpenClawSkillStatusReport {
        if let hooks = Self.gatewayHooks, let skillsStatus = hooks.skillsStatus {
            return try await skillsStatus()
        }
        return try await OpenClawGatewayConnection.shared.skillsStatus()
    }

    private func gatewaySkillsBins() async throws -> [String] {
        if let hooks = Self.gatewayHooks, let skillsBins = hooks.skillsBins {
            return try await skillsBins()
        }
        return try await OpenClawGatewayConnection.shared.skillsBins()
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
        enabled: Bool?
    ) async throws -> OpenClawSkillUpdateResult {
        if let hooks = Self.gatewayHooks, let skillsUpdate = hooks.skillsUpdate {
            return try await skillsUpdate(skillKey, enabled)
        }
        return try await OpenClawGatewayConnection.shared.skillsUpdate(skillKey: skillKey, enabled: enabled)
    }

    private func gatewaySystemPresence() async throws -> [OpenClawPresenceEntry] {
        if let hooks = Self.gatewayHooks, let systemPresence = hooks.systemPresence {
            return try await systemPresence()
        }
        return try await OpenClawGatewayConnection.shared.systemPresence()
    }

    private func gatewayChannelsLogout(channelId: String, accountId: String?) async throws {
        if let hooks = Self.gatewayHooks, let channelsLogout = hooks.channelsLogout {
            try await channelsLogout(channelId, accountId)
            return
        }
        try await OpenClawGatewayConnection.shared.channelsLogout(channelId: channelId, accountId: accountId)
    }

#if DEBUG
    static func _testSetGatewayHooks(_ hooks: GatewayHooks?) {
        gatewayHooks = hooks
    }

    static func _testSetToastSink(_ sink: @escaping @MainActor (ToastEvent) -> Void) {
        shared.toastEventSink = sink
    }

    static func _testResetToastSink() {
        shared.toastEventSink = OpenClawManager.emitDefaultToastEvent
    }

    func _testHandleConnectionState(_ state: OpenClawGatewayConnectionState) async {
        await handleConnectionState(state)
    }

    func _testEmitToast(_ event: ToastEvent) {
        emitToastEvent(event)
    }

    func _testSetConnectionState(
        _ state: ConnectionState,
        gatewayStatus: GatewayStatus = .running
    ) {
        self.connectionState = state
        self.gatewayStatus = gatewayStatus
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
    }
#endif

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
