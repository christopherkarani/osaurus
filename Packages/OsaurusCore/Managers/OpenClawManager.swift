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

    struct GatewayHooks {
        var channelsStatus: @Sendable () async throws -> [GatewayPayload]
        var modelsList: @Sendable () async throws -> [String]
        var health: @Sendable () async throws -> GatewayPayload
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

    public static let shared = OpenClawManager()

    @Published public private(set) var configuration: OpenClawConfiguration
    @Published public private(set) var phase: OpenClawPhase
    @Published public private(set) var gatewayStatus: GatewayStatus = .stopped
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var environmentStatus: OpenClawEnvironmentStatus = .checking
    @Published public private(set) var channels: [ChannelInfo] = []
    @Published public private(set) var availableModels: [String] = []
    @Published public private(set) var lastHealth: OpenClawGatewayHealth?
    @Published public private(set) var lastError: String?

    public let activityStore = OpenClawActivityStore()

    private var healthMonitorTask: Task<Void, Never>?
    private var trackedPID: Int?
    private var eventListenerID: UUID?

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
            connectionState = .connected
            phase = .connected
            lastError = nil
            startHealthMonitoring()
            await refreshStatus()
            postConnectionChanged()
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
            let channelPayload = try await gatewayChannelsStatus()
            channels = channelPayload.map(channelInfo(from:)).sorted { $0.name < $1.name }

            let models = try await gatewayModelsList()
            if models != availableModels {
                availableModels = models
                postModelsChanged()
            }

            let health = try await gatewayHealth()
            updateHealth(from: health)
            postGatewayStatusChanged()
        } catch {
            let message = "Status refresh failed: \(error.localizedDescription)"
            lastError = message
            connectionState = .failed(message)
            phase = .connectionFailed(message)
            postConnectionChanged()
        }
    }

    public func shutdown() async {
        await disconnectInternal()
        saveConfiguration()
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

    private func disconnectInternal() async {
        stopHealthMonitoring()
        if let id = eventListenerID {
            await OpenClawGatewayConnection.shared.removeEventListener(id)
            eventListenerID = nil
        }
        await OpenClawGatewayConnection.shared.disconnect()

        connectionState = .disconnected
        channels = []
        availableModels = []
        lastHealth = nil
        trackedPID = nil

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
            }
        }
        eventListenerID = id
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

#if DEBUG
    static func _testSetGatewayHooks(_ hooks: GatewayHooks?) {
        gatewayHooks = hooks
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
