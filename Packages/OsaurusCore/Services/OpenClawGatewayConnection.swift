//
//  OpenClawGatewayConnection.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol
import Terra

public enum OpenClawConnectionError: LocalizedError, Sendable {
    case gatewayNotReachable
    case authFailed(String)
    case rateLimited(retryAfterMs: Int)
    case slowConsumer
    case disconnected(String)
    case noChannel

    public var errorDescription: String? {
        switch self {
        case .gatewayNotReachable:
            return "OpenClaw gateway is not reachable."
        case .authFailed(let message):
            return "Gateway authentication failed: \(message)"
        case .rateLimited(let retryAfterMs):
            return "Gateway rate-limited this client. Retry in \(retryAfterMs)ms."
        case .slowConsumer:
            return "Gateway closed the connection because the client was too slow."
        case .disconnected(let reason):
            return "Gateway disconnected: \(reason)"
        case .noChannel:
            return "Gateway connection is not established yet."
        }
    }
}

public struct ConfigGetResult: Codable, Sendable {
    public let config: [String: OpenClawProtocol.AnyCodable]?
    public let baseHash: String?

    public init(config: [String: OpenClawProtocol.AnyCodable]?, baseHash: String?) {
        self.config = config
        self.baseHash = baseHash
    }

    private enum CodingKeys: String, CodingKey {
        case config
        case baseHash
        case hash
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nestedConfig = try container.decodeIfPresent([String: OpenClawProtocol.AnyCodable].self, forKey: .config) {
            config = nestedConfig
        } else {
            // Legacy gateways may return a flattened config payload at the root,
            // with hash metadata alongside config keys.
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            var flattened: [String: OpenClawProtocol.AnyCodable] = [:]
            for key in dynamic.allKeys {
                switch key.stringValue {
                case CodingKeys.config.rawValue, CodingKeys.baseHash.rawValue, CodingKeys.hash.rawValue:
                    continue
                default:
                    if let value = try dynamic.decodeIfPresent(OpenClawProtocol.AnyCodable.self, forKey: key) {
                        flattened[key.stringValue] = value
                    }
                }
            }
            config = flattened.isEmpty ? nil : flattened
        }

        let explicitBaseHash = try container.decodeIfPresent(String.self, forKey: .baseHash)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitBaseHash, !explicitBaseHash.isEmpty {
            baseHash = explicitBaseHash
            return
        }

        let legacyHash = try container.decodeIfPresent(String.self, forKey: .hash)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacyHash, !legacyHash.isEmpty {
            baseHash = legacyHash
        } else {
            baseHash = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(config, forKey: .config)
        try container.encodeIfPresent(baseHash, forKey: .baseHash)
    }
}

public struct ConfigPatchResult: Codable, Sendable {
    public let ok: Bool
    public let path: String?
    public let restart: Bool?

    public init(ok: Bool, path: String?, restart: Bool?) {
        self.ok = ok
        self.path = path
        self.restart = restart
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case path
        case restart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        path = try container.decodeIfPresent(String.self, forKey: .path)

        if let restartBool = try? container.decode(Bool.self, forKey: .restart) {
            restart = restartBool
            return
        }

        if let restartSignal = try? container.decode([String: OpenClawProtocol.AnyCodable].self, forKey: .restart) {
            if let rawOK = restartSignal["ok"]?.value,
                let parsed = Self.parseBoolean(rawOK)
            {
                restart = parsed
            } else {
                // Newer gateways emit restart metadata objects. Presence means a restart was requested.
                restart = true
            }
            return
        }

        if let restartInt = try? container.decode(Int.self, forKey: .restart) {
            restart = restartInt != 0
            return
        }

        if let restartString = try? container.decode(String.self, forKey: .restart),
            let parsed = Self.parseBoolean(restartString)
        {
            restart = parsed
            return
        }

        restart = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(restart, forKey: .restart)
    }

    private static func parseBoolean(_ raw: Any) -> Bool? {
        if let bool = raw as? Bool {
            return bool
        }
        if let int = raw as? Int {
            return int != 0
        }
        if let double = raw as? Double {
            return double != 0
        }
        if let string = raw as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y", "on"].contains(normalized) {
                return true
            }
            if ["0", "false", "no", "n", "off"].contains(normalized) {
                return false
            }
        }
        return nil
    }
}

public struct OpenClawChatSendResponse: Codable, Sendable {
    public let runId: String
    public let status: String
}

public struct OpenClawChatHistoryResponse: Codable, Sendable {
    public let sessionKey: String
    public let sessionId: String?
    public let messages: [OpenClawProtocol.AnyCodable]?
    public let thinkingLevel: String?
    public let verboseLevel: String?
}

public struct OpenClawSessionListItem: Codable, Sendable, Identifiable {
    public let key: String
    public let displayName: String?
    public let derivedTitle: String?
    public let lastMessagePreview: String?
    public let updatedAt: Double?
    public let modelProvider: String?
    public let model: String?
    public let contextTokens: Int?

    public var id: String { key }
}

public struct OpenClawSessionsListResponse: Codable, Sendable {
    public let ts: Int?
    public let path: String?
    public let count: Int?
    public let sessions: [OpenClawSessionListItem]
}

public struct OpenClawGatewayAgentSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

public struct OpenClawGatewayAgentsListResponse: Codable, Sendable, Equatable {
    public let defaultId: String
    public let mainKey: String
    public let scope: String
    public let agents: [OpenClawGatewayAgentSummary]

    public init(
        defaultId: String,
        mainKey: String,
        scope: String,
        agents: [OpenClawGatewayAgentSummary]
    ) {
        self.defaultId = defaultId
        self.mainKey = mainKey
        self.scope = scope
        self.agents = agents
    }
}

public struct OpenClawAgentWorkspaceFile: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let missing: Bool
    public let size: Int?
    public let updatedAtMs: Int?
    public let content: String?

    public var id: String { path }

    public init(
        name: String,
        path: String,
        missing: Bool,
        size: Int?,
        updatedAtMs: Int?,
        content: String?
    ) {
        self.name = name
        self.path = path
        self.missing = missing
        self.size = size
        self.updatedAtMs = updatedAtMs
        self.content = content
    }
}

public struct OpenClawAgentFilesListResponse: Codable, Sendable, Equatable {
    public let agentId: String
    public let workspace: String
    public let files: [OpenClawAgentWorkspaceFile]

    public init(agentId: String, workspace: String, files: [OpenClawAgentWorkspaceFile]) {
        self.agentId = agentId
        self.workspace = workspace
        self.files = files
    }
}

public struct OpenClawAgentFileGetResponse: Codable, Sendable, Equatable {
    public let agentId: String
    public let workspace: String
    public let file: OpenClawAgentWorkspaceFile

    public init(agentId: String, workspace: String, file: OpenClawAgentWorkspaceFile) {
        self.agentId = agentId
        self.workspace = workspace
        self.file = file
    }
}

public struct OpenClawAgentFileSetResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let agentId: String
    public let workspace: String
    public let file: OpenClawAgentWorkspaceFile

    public init(ok: Bool, agentId: String, workspace: String, file: OpenClawAgentWorkspaceFile) {
        self.ok = ok
        self.agentId = agentId
        self.workspace = workspace
        self.file = file
    }
}

public struct OpenClawHeartbeatStatus: Codable, Sendable {
    public let enabled: Bool?
    public let lastHeartbeatAt: Date?

    public init(enabled: Bool?, lastHeartbeatAt: Date?) {
        self.enabled = enabled
        self.lastHeartbeatAt = lastHeartbeatAt
    }
}

private struct OpenClawSessionsPatchResponse: Codable, Sendable {
    let ok: Bool?
    let key: String
}

public enum OpenClawGatewayConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case reconnected
    case failed(String)
}

public enum OpenClawDisconnectDisposition: Equatable, Sendable {
    case intentional
    case slowConsumer
    case authFailure
    case unexpected
}

private struct OpenClawConnectionParameters: Sendable {
    let wsURL: URL
    let healthURL: URL?
    let token: String?
}

private struct AgentWaitResponse: Codable, Sendable {
    let runId: String
    let status: String
}

public actor OpenClawGatewayConnection {
    public typealias RequestExecutor = @Sendable (
        _ method: String,
        _ params: [String: OpenClawProtocol.AnyCodable]?
    ) async throws -> Data

    public typealias ReconnectConnectHook = @Sendable (_ host: String, _ port: Int, _ token: String?) async throws ->
        Void
    public typealias SleepHook = @Sendable (_ nanoseconds: UInt64) async -> Void
    public typealias ResyncHook = @Sendable () async -> Void

    public static let shared = OpenClawGatewayConnection()

    private var channel: GatewayChannelActor?
    private struct GatewayPushListenerRegistration {
        let handler: @Sendable (GatewayPush) async -> Void
        var pendingPushes: [GatewayPush] = []
        var isDispatching = false
    }

    private var listeners: [UUID: GatewayPushListenerRegistration] = [:]
    private var connectionStateListeners: [UUID: @Sendable (OpenClawGatewayConnectionState) async -> Void] = [:]
    private var recentEventFrames: [EventFrame] = []
    private var activeRunSessionKeys: [String: String] = [:]
    private var pendingResyncRunIDs: Set<String> = []
    private var connected = false
    private var intentionalDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var connectionParameters: OpenClawConnectionParameters?
    private var connectionState: OpenClawGatewayConnectionState = .disconnected
    private let requestExecutor: RequestExecutor?
    private let reconnectConnectHook: ReconnectConnectHook?
    private let sleepHook: SleepHook
    private let reconnectResyncHook: ResyncHook?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let maxBufferedEventFrames = 512
    private static let maxPendingPushesPerListener = 256
    private static let reconnectBackoffSeconds = [1, 2, 4, 8, 16, 30, 60]
    private static let maxBackoffSeconds = 60
    private static let diagnosticSensitiveKeyFragments = [
        "authorization",
        "api_key",
        "apikey",
        "token",
        "secret",
        "password",
        "bearer",
    ]
    private static let maxDiagnosticArrayValues = 8
    private static let maxDiagnosticObjectKeys = 16

    public init(
        requestExecutor: RequestExecutor? = nil,
        reconnectConnectHook: ReconnectConnectHook? = nil,
        sleepHook: SleepHook? = nil,
        reconnectResyncHook: ResyncHook? = nil
    ) {
        self.requestExecutor = requestExecutor
        self.reconnectConnectHook = reconnectConnectHook
        self.sleepHook = sleepHook ?? { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.reconnectResyncHook = reconnectResyncHook
    }

    public var isConnected: Bool {
        connected
    }

    public var currentConnectionState: OpenClawGatewayConnectionState {
        connectionState
    }

    public func addConnectionStateListener(
        _ handler: @escaping @Sendable (OpenClawGatewayConnectionState) async -> Void
    ) -> UUID {
        let id = UUID()
        connectionStateListeners[id] = handler
        return id
    }

    public func removeConnectionStateListener(_ id: UUID) {
        connectionStateListeners.removeValue(forKey: id)
    }

    private func emitGatewayDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String] = [:]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "openclaw-gateway-connection",
            event: event,
            context: context
        )
    }

    private static func endpointContext(wsURL: URL, healthURL: URL?) -> [String: String] {
        var context: [String: String] = [
            "webSocketURL": wsURL.absoluteString,
            "webSocketHost": wsURL.host ?? "<missing>",
            "webSocketScheme": wsURL.scheme ?? "<missing>",
            "webSocketPort": wsURL.port.map(String.init) ?? "<default>",
        ]
        context["healthURL"] = healthURL?.absoluteString ?? "<none>"
        context["isLoopback"] = shouldPreflightHealthCheck(for: wsURL) ? "true" : "false"
        return context
    }

    private static func mappedErrorKind(_ error: Error) -> String {
        guard let typed = error as? OpenClawConnectionError else {
            return String(describing: type(of: error))
        }
        switch typed {
        case .gatewayNotReachable:
            return "gateway-not-reachable"
        case .authFailed:
            return "auth-failed"
        case .rateLimited:
            return "rate-limited"
        case .slowConsumer:
            return "slow-consumer"
        case .disconnected:
            return "disconnected"
        case .noChannel:
            return "no-channel"
        }
    }

    public func connect(host: String, port: Int, token: String?) async throws {
        let wsURL = URL(string: "ws://\(host):\(port)/ws")!
        let healthURL = URL(string: "http://\(host):\(port)/health")
        try await connect(url: wsURL, token: token, healthURL: healthURL)
    }

    public func connect(
        url: URL,
        token: String?,
        healthURL: URL? = nil
    ) async throws {
        let normalizedHealthURL = healthURL ?? Self.defaultHealthURL(for: url)
        let credentialProvided = token?.isEmpty == false
        _ = try await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.connect", id: nil)) { scope in
            let connectStartedAt = Date()
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.gateway.url": .string(url.absoluteString),
                "osaurus.openclaw.gateway.health_url": .string(normalizedHealthURL?.absoluteString ?? ""),
                "osaurus.openclaw.gateway.connect.credential_provided": .bool(credentialProvided),
            ])

            do {
                try await self.connectUntraced(url: url, token: token, healthURL: normalizedHealthURL)
                scope.setAttributes([
                    "osaurus.openclaw.gateway.connect.success": .bool(true),
                    "osaurus.openclaw.gateway.connect.latency_ms": .double(
                        Date().timeIntervalSince(connectStartedAt) * 1000
                    ),
                ])
            } catch {
                scope.setAttributes([
                    "osaurus.openclaw.gateway.connect.success": .bool(false),
                    "osaurus.openclaw.gateway.connect.latency_ms": .double(
                        Date().timeIntervalSince(connectStartedAt) * 1000
                    ),
                    "osaurus.openclaw.gateway.connect.error.raw": .string(error.localizedDescription),
                    "osaurus.openclaw.gateway.connect.error.kind": .string(Self.mappedErrorKind(error)),
                ])
                throw error
            }
        }
    }

    private func connectUntraced(
        url: URL,
        token: String?,
        healthURL: URL?
    ) async throws {
        let reconnectTaskWasActive = reconnectTask != nil
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionalDisconnect = false
        connectionParameters = OpenClawConnectionParameters(
            wsURL: url,
            healthURL: healthURL,
            token: token
        )
        var beginContext = Self.endpointContext(wsURL: url, healthURL: healthURL)
        beginContext["credentialProvided"] = token?.isEmpty == false ? "true" : "false"
        beginContext["reconnectTaskWasActive"] = reconnectTaskWasActive ? "true" : "false"
        await emitGatewayDiagnostic(
            level: .info,
            event: "gateway.connect.begin",
            context: beginContext
        )
        await transitionConnectionState(.connecting)
        await shutdownChannel()

        do {
            try await performConnect(wsURL: url, healthURL: healthURL, token: token)
            await emitGatewayDiagnostic(
                level: .info,
                event: "gateway.connect.success",
                context: Self.endpointContext(wsURL: url, healthURL: healthURL)
            )
            await transitionConnectionState(.connected)
        } catch {
            let mapped = mapError(error)
            var failureContext = Self.endpointContext(wsURL: url, healthURL: healthURL)
            failureContext["rawError"] = error.localizedDescription
            failureContext["mappedError"] = mapped.localizedDescription
            failureContext["mappedErrorKind"] = Self.mappedErrorKind(mapped)
            await emitGatewayDiagnostic(
                level: .error,
                event: "gateway.connect.failed",
                context: failureContext
            )
            await transitionConnectionState(.failed(mapped.localizedDescription))
            throw mapped
        }
    }

    public func disconnect() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await emitGatewayDiagnostic(
            level: .info,
            event: "gateway.disconnect.intentional",
            context: ["hasActiveChannel": channel == nil ? "false" : "true"]
        )
        await shutdownChannel()
        await transitionConnectionState(.disconnected)
    }

    public func health() async throws -> [String: OpenClawProtocol.AnyCodable] {
        let data = try await requestRaw(method: "health", params: nil)
        return try decodeJSONDictionary(method: "health", data: data)
    }

    public func channelsStatus() async throws -> [[String: OpenClawProtocol.AnyCodable]] {
        let result = try await channelsStatusDetailed()
        let ids = result.channelOrder.isEmpty ? Array(result.channelAccounts.keys).sorted() : result.channelOrder
        let metaByID = Dictionary(uniqueKeysWithValues: result.channelMeta.map { ($0.id, $0) })

        return ids.map { id in
            let accounts = result.channelAccounts[id] ?? []
            let linked = accounts.contains { $0.linked || $0.configured }
            let connected = accounts.contains { $0.connected || $0.running }
            let name = metaByID[id]?.label ?? result.channelLabels[id] ?? id.capitalized
            let systemImage = metaByID[id]?.systemImage ?? result.channelSystemImages[id]
                ?? "antenna.radiowaves.left.and.right"

            return [
                "id": OpenClawProtocol.AnyCodable(id),
                "name": OpenClawProtocol.AnyCodable(name),
                "systemImage": OpenClawProtocol.AnyCodable(systemImage),
                "isLinked": OpenClawProtocol.AnyCodable(linked),
                "isConnected": OpenClawProtocol.AnyCodable(connected),
            ]
        }
    }

    public func channelsStatusDetailed(
        probe: Bool = false,
        timeoutMs: Int? = nil
    ) async throws -> ChannelsStatusResult {
        var params: [String: OpenClawProtocol.AnyCodable]?
        if probe || timeoutMs != nil {
            var payload: [String: OpenClawProtocol.AnyCodable] = [:]
            if probe {
                payload["probe"] = OpenClawProtocol.AnyCodable(true)
            }
            if let timeoutMs {
                payload["timeoutMs"] = OpenClawProtocol.AnyCodable(timeoutMs)
            }
            params = payload
        }

        let data = try await requestRaw(method: "channels.status", params: params)
        return try decodePayload(method: "channels.status", data: data, as: ChannelsStatusResult.self)
    }

    public func channelsLogout(channelId: String, accountId: String? = nil) async throws {
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "channel": OpenClawProtocol.AnyCodable(channelId)
        ]
        if let accountId, !accountId.isEmpty {
            params["accountId"] = OpenClawProtocol.AnyCodable(accountId)
        }
        _ = try await requestRaw(method: "channels.logout", params: params)
    }

    public func wizardStart(
        mode: String = "local",
        workspace: String?
    ) async throws -> OpenClawWizardStartResult {
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "mode": OpenClawProtocol.AnyCodable(mode)
        ]
        if let workspace, !workspace.isEmpty {
            params["workspace"] = OpenClawProtocol.AnyCodable(workspace)
        }

        let data = try await requestRaw(method: "wizard.start", params: params)
        return try decodePayload(method: "wizard.start", data: data, as: OpenClawWizardStartResult.self)
    }

    public func wizardNext(
        sessionId: String,
        stepId: String,
        value: OpenClawProtocol.AnyCodable?
    ) async throws -> OpenClawWizardNextResult {
        var answer: [String: OpenClawProtocol.AnyCodable] = [
            "stepId": OpenClawProtocol.AnyCodable(stepId)
        ]
        if let value {
            answer["value"] = value
        }

        let params: [String: OpenClawProtocol.AnyCodable] = [
            "sessionId": OpenClawProtocol.AnyCodable(sessionId),
            "answer": OpenClawProtocol.AnyCodable(answer)
        ]
        let data = try await requestRaw(method: "wizard.next", params: params)
        return try decodePayload(method: "wizard.next", data: data, as: OpenClawWizardNextResult.self)
    }

    public func wizardCancel(sessionId: String) async throws -> OpenClawWizardStatusResult {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "sessionId": OpenClawProtocol.AnyCodable(sessionId)
        ]
        let data = try await requestRaw(method: "wizard.cancel", params: params)
        return try decodePayload(method: "wizard.cancel", data: data, as: OpenClawWizardStatusResult.self)
    }

    public func wizardStatus(sessionId: String) async throws -> OpenClawWizardStatusResult {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "sessionId": OpenClawProtocol.AnyCodable(sessionId)
        ]
        let data = try await requestRaw(method: "wizard.status", params: params)
        return try decodePayload(method: "wizard.status", data: data, as: OpenClawWizardStatusResult.self)
    }

    public func modelsList() async throws -> [String] {
        let data = try await requestRaw(method: "models.list", params: nil)
        let payload = try decodePayload(method: "models.list", data: data, as: ModelsListResult.self)
        return payload.models.map(\.id)
    }

    public func modelsListFull() async throws -> [OpenClawProtocol.ModelChoice] {
        let data = try await requestRaw(method: "models.list", params: nil)
        let payload = try decodePayload(method: "models.list", data: data, as: ModelsListResult.self)
        return payload.models
    }

    public func agentsList() async throws -> OpenClawGatewayAgentsListResponse {
        let data = try await requestRaw(method: "agents.list", params: [:])
        return try decodePayload(
            method: "agents.list",
            data: data,
            as: OpenClawGatewayAgentsListResponse.self
        )
    }

    public func agentsFilesList(agentId: String) async throws -> OpenClawAgentFilesListResponse {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "agentId": OpenClawProtocol.AnyCodable(agentId)
        ]
        let data = try await requestRaw(method: "agents.files.list", params: params)
        return try decodePayload(
            method: "agents.files.list",
            data: data,
            as: OpenClawAgentFilesListResponse.self
        )
    }

    public func agentsFileGet(agentId: String, name: String) async throws -> OpenClawAgentFileGetResponse {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "agentId": OpenClawProtocol.AnyCodable(agentId),
            "name": OpenClawProtocol.AnyCodable(name)
        ]
        let data = try await requestRaw(method: "agents.files.get", params: params)
        return try decodePayload(
            method: "agents.files.get",
            data: data,
            as: OpenClawAgentFileGetResponse.self
        )
    }

    public func agentsFileSet(
        agentId: String,
        name: String,
        content: String
    ) async throws -> OpenClawAgentFileSetResponse {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "agentId": OpenClawProtocol.AnyCodable(agentId),
            "name": OpenClawProtocol.AnyCodable(name),
            "content": OpenClawProtocol.AnyCodable(content)
        ]
        let data = try await requestRaw(method: "agents.files.set", params: params)
        return try decodePayload(
            method: "agents.files.set",
            data: data,
            as: OpenClawAgentFileSetResponse.self
        )
    }

    public func skillsStatus(agentId: String? = nil) async throws -> OpenClawSkillStatusReport {
        var params: [String: OpenClawProtocol.AnyCodable]?
        if let agentId, !agentId.isEmpty {
            params = ["agentId": OpenClawProtocol.AnyCodable(agentId)]
        }
        let data = try await requestRaw(method: "skills.status", params: params)
        return try decodePayload(method: "skills.status", data: data, as: OpenClawSkillStatusReport.self)
    }

    public func skillsBins() async throws -> [String] {
        let data = try await requestRaw(method: "skills.bins", params: [:])
        let payload = try decodePayload(method: "skills.bins", data: data, as: OpenClawSkillBinsResponse.self)
        return payload.bins
    }

    public func skillsInstall(
        name: String,
        installId: String,
        timeoutMs: Int? = nil
    ) async throws -> OpenClawSkillInstallResult {
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "name": OpenClawProtocol.AnyCodable(name),
            "installId": OpenClawProtocol.AnyCodable(installId)
        ]
        if let timeoutMs {
            params["timeoutMs"] = OpenClawProtocol.AnyCodable(timeoutMs)
        }
        let data = try await requestRaw(method: "skills.install", params: params)
        return try decodePayload(method: "skills.install", data: data, as: OpenClawSkillInstallResult.self)
    }

    public func skillsUpdate(
        skillKey: String,
        enabled: Bool? = nil,
        apiKey: String? = nil,
        env: [String: String]? = nil
    ) async throws -> OpenClawSkillUpdateResult {
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "skillKey": OpenClawProtocol.AnyCodable(skillKey)
        ]
        if let enabled {
            params["enabled"] = OpenClawProtocol.AnyCodable(enabled)
        }
        if let apiKey {
            params["apiKey"] = OpenClawProtocol.AnyCodable(apiKey)
        }
        if let env, !env.isEmpty {
            params["env"] = OpenClawProtocol.AnyCodable(env)
        }
        let data = try await requestRaw(method: "skills.update", params: params)
        return try decodePayload(method: "skills.update", data: data, as: OpenClawSkillUpdateResult.self)
    }

    public func systemPresence() async throws -> [OpenClawPresenceEntry] {
        let data = try await requestRaw(method: "system-presence", params: [:])
        return try decodePayload(method: "system-presence", data: data, as: [OpenClawPresenceEntry].self)
    }

    public func configGet() async throws -> [String: OpenClawProtocol.AnyCodable] {
        let data = try await requestRaw(method: "config.get", params: nil)
        if let raw = try? decodeJSONDictionary(method: "config.get", data: data) {
            // `config.get` may return either `{ ...config }` or `{ config: {...}, ...meta }`.
            // Prefer the nested config object when present so callers always see config keys at root.
            if let nested = raw["config"]?.value as? [String: OpenClawProtocol.AnyCodable] {
                return nested
            }
            return raw
        }
        let typed = try decodePayload(method: "config.get", data: data, as: TalkConfigResult.self)
        return typed.config
    }

    public func configGetFull() async throws -> ConfigGetResult {
        let data = try await requestRaw(method: "config.get", params: nil)
        return try decodePayload(method: "config.get", data: data, as: ConfigGetResult.self)
    }

    public func configPatch(raw: String, baseHash: String) async throws -> ConfigPatchResult {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "raw": OpenClawProtocol.AnyCodable(raw),
            "baseHash": OpenClawProtocol.AnyCodable(baseHash)
        ]
        let data = try await requestRaw(method: "config.patch", params: params)
        return try decodePayload(method: "config.patch", data: data, as: ConfigPatchResult.self)
    }

    public func announcePresence() async throws {
        let version =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev"
        let operatorScopes = ["operator.admin", "operator.approvals", "operator.pairing"]
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "text": OpenClawProtocol.AnyCodable("Node: Osaurus"),
            "roles": OpenClawProtocol.AnyCodable(["chat-client"]),
            "scopes": OpenClawProtocol.AnyCodable(operatorScopes),
            "platform": OpenClawProtocol.AnyCodable("macos"),
            "version": OpenClawProtocol.AnyCodable(version),
            "mode": OpenClawProtocol.AnyCodable("chat")
        ]
        _ = try await requestRaw(method: "system-event", params: params)
    }

    public func chatSend(
        message: String,
        sessionKey: String,
        clientRunId: String?
    ) async throws -> OpenClawChatSendResponse {
        let promptSafetyCheck = Terra.SafetyCheck(
            name: "openclaw.chat.prompt",
            subject: message,
            subjectCapture: .optIn
        )
        _ = await Terra.withSafetyCheckSpan(promptSafetyCheck) { _ in true }

        let runId = clientRunId?.isEmpty == false ? clientRunId! : UUID().uuidString
        let request = ChatSendParams(
            sessionkey: sessionKey,
            message: message,
            thinking: nil,
            deliver: false,
            attachments: nil,
            timeoutms: 30_000,
            idempotencykey: runId
        )
        let params = try encodeParams(request)
        let data = try await requestRaw(method: "chat.send", params: params)
        let payload = try decodePayload(method: "chat.send", data: data, as: OpenClawChatSendResponse.self)
        activeRunSessionKeys[payload.runId] = sessionKey

        _ = await Terra.withAgentInvocationSpan(
            agent: .init(name: "openclaw.chat.send", id: sessionKey)
        ) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.message.length": .int(message.count),
                "osaurus.prompt.raw": .string(message),
                "osaurus.openclaw.run_id": .string(payload.runId),
            ])
        }
        return payload
    }

    public func chatHistory(sessionKey: String, limit: Int? = 200) async throws -> OpenClawChatHistoryResponse {
        let request = ChatHistoryParams(sessionkey: sessionKey, limit: limit)
        let params = try encodeParams(request)
        let data = try await requestRaw(method: "chat.history", params: params)
        return try decodePayload(method: "chat.history", data: data, as: OpenClawChatHistoryResponse.self)
    }

    public func sessionsList(
        limit: Int? = 50,
        includeTitles: Bool = true,
        includeLastMessage: Bool = true,
        includeGlobal: Bool = false,
        includeUnknown: Bool = false
    ) async throws -> [OpenClawSessionListItem] {
        let request = SessionsListParams(
            limit: limit,
            activeminutes: nil,
            includeglobal: includeGlobal,
            includeunknown: includeUnknown,
            includederivedtitles: includeTitles,
            includelastmessage: includeLastMessage,
            label: nil,
            spawnedby: nil,
            agentid: nil,
            search: nil
        )
        let params = try encodeParams(request)
        let data = try await requestRaw(method: "sessions.list", params: params)
        let payload = try decodePayload(method: "sessions.list", data: data, as: OpenClawSessionsListResponse.self)
        return payload.sessions
    }

    public func sessionsCreate(model: String?) async throws -> String {
        let provisionalKey = "agent:main:\(UUID().uuidString.lowercased())"
        var params: [String: OpenClawProtocol.AnyCodable] = [
            "key": OpenClawProtocol.AnyCodable(provisionalKey)
        ]
        if let model, !model.isEmpty {
            params["model"] = OpenClawProtocol.AnyCodable(model)
        }

        let data = try await requestRaw(method: "sessions.patch", params: params)
        let payload = try decodePayload(method: "sessions.patch", data: data, as: OpenClawSessionsPatchResponse.self)
        return payload.key
    }

    public func sessionsPatch(
        key: String,
        params: [String: OpenClawProtocol.AnyCodable]
    ) async throws {
        var payload = params
        payload["key"] = OpenClawProtocol.AnyCodable(key)
        _ = try await requestRaw(method: "sessions.patch", params: payload)
    }

    public func sessionsReset(key: String, reason: String?) async throws {
        let request = SessionsResetParams(
            key: key,
            reason: reason.map(OpenClawProtocol.AnyCodable.init)
        )
        let params = try encodeParams(request)
        _ = try await requestRaw(method: "sessions.reset", params: params)
    }

    public func sessionsDelete(key: String, deleteTranscript: Bool = true) async throws {
        let request = SessionsDeleteParams(key: key, deletetranscript: deleteTranscript)
        let params = try encodeParams(request)
        _ = try await requestRaw(method: "sessions.delete", params: params)
    }

    public func sessionsCompact(key: String, maxLines: Int? = nil) async throws {
        let request = SessionsCompactParams(key: key, maxlines: maxLines)
        let params = try encodeParams(request)
        _ = try await requestRaw(method: "sessions.compact", params: params)
    }

    public func heartbeatStatus() async throws -> OpenClawHeartbeatStatus {
        let data = try await requestRaw(method: "heartbeat.status", params: nil)
        let payload = try decodeJSONDictionary(method: "heartbeat.status", data: data)
        let enabled = boolValue(payload["enabled"]?.value)
        let lastHeartbeat = payload["lastHeartbeatAt"] ?? payload["lastHeartbeat"] ?? payload["lastRunAt"]
        return OpenClawHeartbeatStatus(
            enabled: enabled,
            lastHeartbeatAt: Self.heartbeatTimestamp(from: lastHeartbeat?.value)
        )
    }

    public func setHeartbeats(enabled: Bool) async throws {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "enabled": OpenClawProtocol.AnyCodable(enabled)
        ]
        _ = try await requestRaw(method: "set-heartbeats", params: params)
    }

    public func cronStatus() async throws -> OpenClawCronStatus {
        let data = try await requestRaw(method: "cron.status", params: [:])
        return try decodePayload(method: "cron.status", data: data, as: OpenClawCronStatus.self)
    }

    public func cronList(includeDisabled: Bool = true) async throws -> [OpenClawCronJob] {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "includeDisabled": OpenClawProtocol.AnyCodable(includeDisabled)
        ]
        let data = try await requestRaw(method: "cron.list", params: params)
        let payload = try decodePayload(method: "cron.list", data: data, as: OpenClawCronListResponse.self)
        return payload.jobs
    }

    public func cronRuns(jobId: String, limit: Int = 50) async throws -> [OpenClawCronRunLogEntry] {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "id": OpenClawProtocol.AnyCodable(jobId),
            "limit": OpenClawProtocol.AnyCodable(limit)
        ]
        let data = try await requestRaw(method: "cron.runs", params: params)
        let payload = try decodePayload(method: "cron.runs", data: data, as: OpenClawCronRunsResponse.self)
        return payload.entries
    }

    public func cronRun(jobId: String, mode: String = "force") async throws {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "id": OpenClawProtocol.AnyCodable(jobId),
            "mode": OpenClawProtocol.AnyCodable(mode)
        ]
        _ = try await requestRaw(method: "cron.run", params: params)
    }

    public func cronSetEnabled(jobId: String, enabled: Bool) async throws {
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "id": OpenClawProtocol.AnyCodable(jobId),
            "patch": OpenClawProtocol.AnyCodable(["enabled": enabled])
        ]
        _ = try await requestRaw(method: "cron.update", params: params)
    }

    /// Refreshes known run snapshots using `agent.wait` to catch up on missed events.
    ///
    /// Semantics:
    /// - Always inspects active runs.
    /// - Also inspects run IDs marked by sequence-gap callbacks.
    /// - Accepts an explicit run hint to close the race where lifecycle end removes
    ///   active-run state before refresh executes.
    public func refresh(runIdHint: String? = nil) async {
        var runIds = Set(activeRunSessionKeys.keys)
        runIds.formUnion(pendingResyncRunIDs)
        if let runIdHint, !runIdHint.isEmpty {
            runIds.insert(runIdHint)
        }

        for runId in runIds.sorted() {
            let params: [String: OpenClawProtocol.AnyCodable] = [
                "runId": OpenClawProtocol.AnyCodable(runId),
                "timeoutMs": OpenClawProtocol.AnyCodable(0)
            ]

            guard let data = try? await requestRaw(method: "agent.wait", params: params),
                let snapshot = try? decodePayload(method: "agent.wait", data: data, as: AgentWaitResponse.self)
            else {
                _ = await Terra.withAgentInvocationSpan(
                    agent: .init(name: "openclaw.agent.wait.refresh", id: runId)
                ) { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.refresh.has_hint": .bool(runIdHint?.isEmpty == false),
                    ])
                    scope.addEvent("openclaw.agent.wait.decode_failed")
                }
                continue
            }

            _ = await Terra.withAgentInvocationSpan(
                agent: .init(name: "openclaw.agent.wait.refresh", id: runId)
            ) { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.refresh.has_hint": .bool(runIdHint?.isEmpty == false),
                    "osaurus.openclaw.agent_wait.status": .string(snapshot.status),
                ])
            }

            pendingResyncRunIDs.remove(runId)
            if snapshot.status.lowercased() != "timeout" {
                activeRunSessionKeys.removeValue(forKey: runId)
            }
        }
    }

    /// Registers a sequence gap and immediately attempts run-scoped resync.
    /// This is used by the event processor callback path to guarantee at least
    /// one refresh pass for the affected run, even if lifecycle events race.
    public func registerSequenceGap(
        runId: String,
        expectedSeq _: Int,
        receivedSeq _: Int
    ) async {
        guard !runId.isEmpty else { return }
        pendingResyncRunIDs.insert(runId)
        await refresh(runIdHint: runId)
    }

    public func subscribeToEvents(runId: String) -> AsyncStream<EventFrame> {
        let bufferedFrames = recentEventFrames.filter { Self.runId(for: $0) == runId }
        return AsyncStream { continuation in
            for frame in bufferedFrames {
                continuation.yield(frame)
            }

            let listenerId = addEventListener { push in
                guard case .event(let frame) = push else { return }
                guard Self.runId(for: frame) == runId else { return }
                continuation.yield(frame)
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeEventListener(listenerId)
                }
            }
        }
    }

    public func addEventListener(_ handler: @escaping @Sendable (GatewayPush) async -> Void) -> UUID {
        let id = UUID()
        listeners[id] = GatewayPushListenerRegistration(handler: handler)
        return id
    }

    public func removeEventListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func performConnect(
        wsURL: URL,
        healthURL: URL?,
        token: String?
    ) async throws {
        let connectStartedAt = Date()
        await emitGatewayDiagnostic(
            level: .debug,
            event: "gateway.handshake.begin",
            context: Self.endpointContext(wsURL: wsURL, healthURL: healthURL)
        )
        if Self.shouldPreflightHealthCheck(for: wsURL), let healthURL {
            await emitGatewayDiagnostic(
                level: .debug,
                event: "gateway.preflight.begin",
                context: ["healthURL": healthURL.absoluteString]
            )
            try await assertGatewayHealth(url: healthURL)
            await emitGatewayDiagnostic(
                level: .debug,
                event: "gateway.preflight.success",
                context: ["healthURL": healthURL.absoluteString]
            )
        }

        let options = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.admin", "operator.approvals", "operator.pairing"],
            caps: ["tool-events"],
            commands: [],
            permissions: [:],
            clientId: "gateway-client",
            clientMode: "ui",
            clientDisplayName: "Osaurus",
            includeDeviceIdentity: true
        )

        let newChannel = GatewayChannelActor(
            url: wsURL,
            token: token,
            pushHandler: { [weak self] push in
                await self?.handlePush(push)
            },
            connectOptions: options,
            disconnectHandler: { [weak self] reason in
                await self?.handleDisconnect(reason)
            }
        )

        do {
            await emitGatewayDiagnostic(
                level: .debug,
                event: "gateway.websocket.connect.begin",
                context: [
                    "webSocketURL": wsURL.absoluteString,
                    "credentialProvided": token?.isEmpty == false ? "true" : "false",
                ]
            )
            try await newChannel.connect()
            channel = newChannel
            connected = true
            await emitGatewayDiagnostic(
                level: .info,
                event: "gateway.websocket.connect.success",
                context: ["webSocketURL": wsURL.absoluteString]
            )
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.connect.success", id: nil)) {
                scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.gateway.url": .string(wsURL.absoluteString),
                    "osaurus.openclaw.gateway.health_url": .string(healthURL?.absoluteString ?? ""),
                    "osaurus.openclaw.gateway.connect.latency_ms": .double(Date().timeIntervalSince(connectStartedAt) * 1000),
                    "osaurus.openclaw.gateway.connect.credential_provided": .bool(token?.isEmpty == false),
                ])
            }
        } catch {
            let mapped = mapError(error)
            await emitGatewayDiagnostic(
                level: .error,
                event: "gateway.websocket.connect.failed",
                context: [
                    "webSocketURL": wsURL.absoluteString,
                    "rawError": error.localizedDescription,
                    "mappedError": mapped.localizedDescription,
                    "mappedErrorKind": Self.mappedErrorKind(mapped),
                ]
            )
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.connect.failed", id: nil)) {
                scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.gateway.url": .string(wsURL.absoluteString),
                    "osaurus.openclaw.gateway.health_url": .string(healthURL?.absoluteString ?? ""),
                    "osaurus.openclaw.gateway.connect.latency_ms": .double(Date().timeIntervalSince(connectStartedAt) * 1000),
                    "osaurus.openclaw.gateway.connect.error.raw": .string(error.localizedDescription),
                    "osaurus.openclaw.gateway.connect.error.mapped": .string(mapped.localizedDescription),
                    "osaurus.openclaw.gateway.connect.error.kind": .string(Self.mappedErrorKind(mapped)),
                ])
            }
            throw mapped
        }
    }

    private func shutdownChannel() async {
        if let channel {
            await channel.shutdown()
        }
        self.channel = nil
        self.connected = false
    }

    private func beginReconnect(
        after reason: String,
        immediate: Bool
    ) async {
        guard reconnectTask == nil else { return }
        await emitGatewayDiagnostic(
            level: .warning,
            event: "gateway.reconnect.begin",
            context: [
                "reason": reason,
                "immediate": immediate ? "true" : "false",
            ]
        )
        guard let connectionParameters else {
            await emitGatewayDiagnostic(
                level: .error,
                event: "gateway.reconnect.missingContext",
                context: [:]
            )
            await transitionConnectionState(.failed("OpenClaw reconnect failed: missing connection context."))
            return
        }

        reconnectTask = Task {
            await self.reconnectLoop(
                parameters: connectionParameters,
                reason: reason,
                immediate: immediate
            )
        }
    }

    private func reconnectLoop(
        parameters: OpenClawConnectionParameters,
        reason: String,
        immediate: Bool
    ) async {
        await emitGatewayDiagnostic(
            level: .debug,
            event: "gateway.reconnect.loop.started",
            context: [
                "reason": reason,
                "immediate": immediate ? "true" : "false",
                "webSocketURL": parameters.wsURL.absoluteString,
            ]
        )
        var attempt = 1
        while !Task.isCancelled {
            let reconnectAttemptStartedAt = Date()
            let attemptSnapshot = attempt
            await transitionConnectionState(.reconnecting(attempt: attemptSnapshot))
            let base = Self.delaySeconds(forAttempt: attemptSnapshot, immediateFirstAttempt: immediate)
            await emitGatewayDiagnostic(
                level: .debug,
                event: "gateway.reconnect.attempt.begin",
                context: [
                    "attempt": "\(attemptSnapshot)",
                    "backoffSeconds": "\(base)",
                    "webSocketURL": parameters.wsURL.absoluteString,
                ]
            )
            if base > 0 {
                await sleepHook(Self.jitteredDelay(base: base))
            }
            guard !Task.isCancelled else { return }

            await shutdownChannel()

            var shouldIncrementAttempt = true
            do {
                if let reconnectConnectHook {
                    let hostPort = Self.hostAndPort(for: parameters.wsURL)
                    guard let hostPort else {
                        throw OpenClawConnectionError.disconnected(
                            "Reconnect failed: invalid gateway URL (\(parameters.wsURL.absoluteString))."
                        )
                    }
                    try await reconnectConnectHook(hostPort.host, hostPort.port, parameters.token)
                    connected = true
                } else {
                    try await performConnect(
                        wsURL: parameters.wsURL,
                        healthURL: parameters.healthURL,
                        token: parameters.token
                    )
                }

                if let reconnectResyncHook {
                    await reconnectResyncHook()
                } else {
                    try? await announcePresence()
                    await refresh()
                }

                reconnectTask = nil
                await emitGatewayDiagnostic(
                    level: .info,
                    event: "gateway.reconnect.success",
                    context: ["attempt": "\(attemptSnapshot)"]
                )
                _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.reconnect.success", id: nil))
                { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.gateway.reconnect.attempt": .int(attemptSnapshot),
                        "osaurus.openclaw.gateway.reconnect.latency_ms": .double(
                            Date().timeIntervalSince(reconnectAttemptStartedAt) * 1000
                        ),
                    ])
                }
                await transitionConnectionState(.reconnected)
                await transitionConnectionState(.connected)
                return
            } catch {
                let mapped = mapError(error)
                await emitGatewayDiagnostic(
                    level: .warning,
                    event: "gateway.reconnect.attempt.failed",
                    context: [
                        "attempt": "\(attemptSnapshot)",
                        "rawError": error.localizedDescription,
                        "mappedError": mapped.localizedDescription,
                        "mappedErrorKind": Self.mappedErrorKind(mapped),
                    ]
                )
                _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.reconnect.failed", id: nil))
                { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.gateway.reconnect.attempt": .int(attemptSnapshot),
                        "osaurus.openclaw.gateway.reconnect.latency_ms": .double(
                            Date().timeIntervalSince(reconnectAttemptStartedAt) * 1000
                        ),
                        "osaurus.openclaw.gateway.reconnect.error.raw": .string(error.localizedDescription),
                        "osaurus.openclaw.gateway.reconnect.error.mapped": .string(mapped.localizedDescription),
                        "osaurus.openclaw.gateway.reconnect.error.kind": .string(Self.mappedErrorKind(mapped)),
                    ])
                }
                if let clawError = mapped as? OpenClawConnectionError {
                    if case .rateLimited(let retryAfterMs) = clawError {
                        // Don't count toward attempt; just sleep for the gateway's instruction.
                        let ns = UInt64(max(retryAfterMs, 1000)) * 1_000_000
                        await emitGatewayDiagnostic(
                            level: .warning,
                            event: "gateway.reconnect.rateLimited",
                            context: [
                                "attempt": "\(attemptSnapshot)",
                                "retryAfterMs": "\(retryAfterMs)",
                            ]
                        )
                        await sleepHook(ns)
                        shouldIncrementAttempt = false
                    }
                    if case .authFailed(let message) = clawError {
                        reconnectTask = nil
                        await emitGatewayDiagnostic(
                            level: .error,
                            event: "gateway.reconnect.stopped.authFailure",
                            context: [
                                "attempt": "\(attemptSnapshot)",
                                "error": message,
                            ]
                        )
                        await transitionConnectionState(.failed(message))
                        return
                    }
                }
            }

            if shouldIncrementAttempt {
                attempt += 1
            }
        }
        reconnectTask = nil
        await emitGatewayDiagnostic(
            level: .debug,
            event: "gateway.reconnect.loop.cancelled",
            context: [:]
        )
    }

    private static func delaySeconds(
        forAttempt attempt: Int,
        immediateFirstAttempt: Bool
    ) -> Int {
        if immediateFirstAttempt && attempt == 1 {
            return 0
        }
        let index = max(0, min(attempt - 1, reconnectBackoffSeconds.count - 1))
        return reconnectBackoffSeconds[index]
    }

    /// Returns a nanosecond sleep duration equal to `base` seconds ± 25 % random jitter,
    /// clamped to a minimum of 1 second.
    private static func jitteredDelay(base: Int) -> UInt64 {
        let jitter = Double(base) * Double.random(in: -0.25...0.25)
        let clamped = max(1, Int((Double(base) + jitter).rounded()))
        return UInt64(clamped) * 1_000_000_000
    }

    private func transitionConnectionState(_ state: OpenClawGatewayConnectionState) async {
        connectionState = state
        for listener in connectionStateListeners.values {
            await listener(state)
        }
    }

    private func assertGatewayHealth(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard let status, status == 200 else {
                await emitGatewayDiagnostic(
                    level: .warning,
                    event: "gateway.preflight.failed",
                    context: [
                        "healthURL": url.absoluteString,
                        "httpStatus": status.map(String.init) ?? "<missing>",
                        "error": "non-200 status",
                    ]
                )
                throw OpenClawConnectionError.gatewayNotReachable
            }
        } catch {
            await emitGatewayDiagnostic(
                level: .warning,
                event: "gateway.preflight.failed",
                context: [
                    "healthURL": url.absoluteString,
                    "error": error.localizedDescription,
                ]
            )
            throw OpenClawConnectionError.gatewayNotReachable
        }
    }

    private static func hostAndPort(for wsURL: URL) -> (host: String, port: Int)? {
        guard let host = wsURL.host else { return nil }
        if let port = wsURL.port {
            return (host, port)
        }
        switch wsURL.scheme?.lowercased() {
        case "wss":
            return (host, 443)
        case "ws":
            return (host, 80)
        default:
            return nil
        }
    }

    private static func shouldPreflightHealthCheck(for wsURL: URL) -> Bool {
        guard let scheme = wsURL.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss"
        else {
            return false
        }
        guard let host = wsURL.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func defaultHealthURL(for wsURL: URL) -> URL? {
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func requestRaw(
        method: String,
        params: [String: OpenClawProtocol.AnyCodable]?
    ) async throws -> Data {
        if let requestExecutor {
            return try await requestExecutor(method, params)
        }
        let requestStartedAt = Date()
        return try await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.request", id: method)) {
            scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.request.method": .string(method),
                "osaurus.openclaw.request.param_count": .int(params?.count ?? 0),
                "osaurus.openclaw.request.param_keys": .string(Self.requestParamKeys(params)),
            ])
            if let paramsRaw = Self.rawTelemetryJSONString(from: params), !paramsRaw.isEmpty {
                scope.setAttributes(["osaurus.openclaw.request.params.raw": .string(paramsRaw)])
            }
            do {
                let data = try await self.requestRawRetried(method: method, params: params)
                scope.setAttributes([
                    "osaurus.openclaw.request.success": .bool(true),
                    "osaurus.openclaw.request.total_latency_ms": .double(
                        Date().timeIntervalSince(requestStartedAt) * 1000
                    ),
                    "osaurus.openclaw.response.bytes": .int(data.count),
                ])
                return data
            } catch {
                scope.setAttributes([
                    "osaurus.openclaw.request.success": .bool(false),
                    "osaurus.openclaw.request.total_latency_ms": .double(
                        Date().timeIntervalSince(requestStartedAt) * 1000
                    ),
                    "osaurus.openclaw.request.error.raw": .string(error.localizedDescription),
                    "osaurus.openclaw.request.error.kind": .string(Self.mappedErrorKind(error)),
                ])
                throw error
            }
        }
    }

    private func requestRawRetried(
        method: String,
        params: [String: OpenClawProtocol.AnyCodable]?
    ) async throws -> Data {
        let retryDelaysMs = [0, 150, 400, 900]
        var lastError: Error = OpenClawConnectionError.noChannel
        var lastRawError: Error = OpenClawConnectionError.noChannel
        let requestDebugContext = Self.requestDebugContext(method: method, params: params)
        let requestStartedAt = Date()

        if method == "sessions.patch" {
            await emitGatewayDiagnostic(
                level: .debug,
                event: "gateway.request.sessionsPatch.begin",
                context: requestDebugContext
            )
        }

        for (index, delay) in retryDelaysMs.enumerated() {
            let attempt = index + 1
            let attemptStartedAt = Date()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }

            do {
                guard let channel else {
                    throw OpenClawConnectionError.noChannel
                }
                let data = try await channel.request(method: method, params: params, timeoutMs: nil)

                _ = await Terra.withToolExecutionSpan(
                    tool: .init(name: method, type: "openclaw.rpc"),
                    call: .init(id: "rpc_\(UUID().uuidString.lowercased())")
                ) { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.request.method": .string(method),
                        "osaurus.openclaw.request.param_count": .int(params?.count ?? 0),
                        "osaurus.openclaw.request.param_keys": .string(Self.requestParamKeys(params)),
                        "osaurus.openclaw.request.attempt": .int(attempt),
                        "osaurus.openclaw.response.bytes": .int(data.count),
                        "osaurus.openclaw.request.latency_ms": .double(Date().timeIntervalSince(attemptStartedAt) * 1000),
                    ])
                    if let paramsRaw = Self.rawTelemetryJSONString(from: params), !paramsRaw.isEmpty {
                        scope.setAttributes(["osaurus.openclaw.request.params.raw": .string(paramsRaw)])
                    }
                }

                if method == "sessions.patch" {
                    var successContext = requestDebugContext
                    successContext["attempt"] = "\(attempt)"
                    successContext["maxAttempts"] = "\(retryDelaysMs.count)"
                    await emitGatewayDiagnostic(
                        level: .info,
                        event: "gateway.request.sessionsPatch.success",
                        context: successContext
                    )
                }
                return data
            } catch {
                let mappedError = mapError(error)
                lastRawError = error
                lastError = mappedError

                var attemptContext = requestDebugContext
                attemptContext["method"] = method
                attemptContext["attempt"] = "\(attempt)"
                attemptContext["maxAttempts"] = "\(retryDelaysMs.count)"
                attemptContext["retryDelayMs"] = "\(delay)"
                attemptContext["hasChannel"] = channel == nil ? "false" : "true"
                attemptContext["rawError"] = error.localizedDescription
                attemptContext["mappedError"] = mappedError.localizedDescription
                attemptContext["mappedErrorKind"] = Self.mappedErrorKind(mappedError)
                attemptContext.merge(Self.gatewayResponseDebugContext(from: error)) { _, new in new }
                await emitGatewayDiagnostic(
                    level: .warning,
                    event: "gateway.request.attempt.failed",
                    context: attemptContext
                )

                _ = await Terra.withToolExecutionSpan(
                    tool: .init(name: method, type: "openclaw.rpc"),
                    call: .init(id: "rpc_\(UUID().uuidString.lowercased())")
                ) { scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.request.method": .string(method),
                        "osaurus.openclaw.request.param_count": .int(params?.count ?? 0),
                        "osaurus.openclaw.request.param_keys": .string(Self.requestParamKeys(params)),
                        "osaurus.openclaw.request.attempt": .int(attempt),
                        "osaurus.openclaw.request.latency_ms": .double(Date().timeIntervalSince(attemptStartedAt) * 1000),
                        "osaurus.openclaw.request.error.raw": .string(error.localizedDescription),
                        "osaurus.openclaw.request.error.mapped": .string(mappedError.localizedDescription),
                        "osaurus.openclaw.request.error.kind": .string(Self.mappedErrorKind(mappedError)),
                    ])
                    if let paramsRaw = Self.rawTelemetryJSONString(from: params), !paramsRaw.isEmpty {
                        scope.setAttributes(["osaurus.openclaw.request.params.raw": .string(paramsRaw)])
                    }
                }
            }
        }

        let finalRawError = lastRawError
        let finalMappedError = lastError
        let finalRawErrorDescription = finalRawError.localizedDescription
        let finalMappedErrorDescription = finalMappedError.localizedDescription
        let finalMappedErrorKind = Self.mappedErrorKind(finalMappedError)

        _ = await Terra.withToolExecutionSpan(
            tool: .init(name: method, type: "openclaw.rpc"),
            call: .init(id: "rpc_\(UUID().uuidString.lowercased())")
        ) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.request.method": .string(method),
                "osaurus.openclaw.request.param_count": .int(params?.count ?? 0),
                "osaurus.openclaw.request.param_keys": .string(Self.requestParamKeys(params)),
                "osaurus.openclaw.request.error.raw": .string(finalRawErrorDescription),
                "osaurus.openclaw.request.error.mapped": .string(finalMappedErrorDescription),
                "osaurus.openclaw.request.error.kind": .string(finalMappedErrorKind),
                "osaurus.openclaw.request.attempts": .int(retryDelaysMs.count),
                "osaurus.openclaw.request.total_latency_ms": .double(Date().timeIntervalSince(requestStartedAt) * 1000),
            ])
            if let paramsRaw = Self.rawTelemetryJSONString(from: params), !paramsRaw.isEmpty {
                scope.setAttributes(["osaurus.openclaw.request.params.raw": .string(paramsRaw)])
            }
        }

        var finalContext = requestDebugContext
        finalContext["method"] = method
        finalContext["attempts"] = "\(retryDelaysMs.count)"
        finalContext["error"] = finalMappedErrorDescription
        finalContext["rawError"] = finalRawErrorDescription
        finalContext["mappedErrorKind"] = finalMappedErrorKind
        finalContext.merge(Self.gatewayResponseDebugContext(from: finalRawError)) { _, new in new }
        await emitGatewayDiagnostic(
            level: .warning,
            event: "gateway.request.failed",
            context: finalContext
        )
        throw finalMappedError
    }

    private static func requestDebugContext(
        method: String,
        params: [String: OpenClawProtocol.AnyCodable]?
    ) -> [String: String] {
        var context: [String: String] = [
            "method": method,
            "paramCount": "\(params?.count ?? 0)",
            "paramKeys": requestParamKeys(params),
        ]

        guard method == "sessions.patch" else {
            return context
        }

        if let key = params?["key"]?.value as? String, !key.isEmpty {
            context["sessionKey"] = key
        }
        if let model = params?["model"]?.value as? String, !model.isEmpty {
            context["model"] = model
        }
        if let sendPolicy = params?["sendPolicy"]?.value as? String, !sendPolicy.isEmpty {
            context["sendPolicy"] = sendPolicy
        }
        if let paramsJSON = diagnosticJSONString(from: params) {
            context.merge(previewContext(value: paramsJSON, keyPrefix: "params")) { _, new in new }
        }
        return context
    }

    private static func requestParamKeys(_ params: [String: OpenClawProtocol.AnyCodable]?) -> String {
        guard let params, !params.isEmpty else { return "<none>" }
        return params.keys.sorted().joined(separator: ",")
    }

    private static func gatewayResponseDebugContext(from error: Error) -> [String: String] {
        guard let responseError = error as? GatewayResponseError else {
            return [:]
        }

        var context: [String: String] = [
            "gatewayErrorCode": responseError.code,
            "gatewayErrorMessage": responseError.message,
        ]
        if let detailsJSON = diagnosticJSONString(from: responseError.details), !detailsJSON.isEmpty {
            context.merge(previewContext(value: detailsJSON, keyPrefix: "gatewayErrorDetails")) { _, new in new }
        }
        return context
    }

    private static func diagnosticJSONString(
        from params: [String: OpenClawProtocol.AnyCodable]?
    ) -> String? {
        guard let params else { return nil }
        let dictionary = params.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.value
        }
        return diagnosticJSONString(from: dictionary)
    }

    private static func diagnosticJSONString(
        from params: [String: OpenClawProtocol.AnyCodable]
    ) -> String? {
        let dictionary = params.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.value
        }
        return diagnosticJSONString(from: dictionary)
    }

    private static func diagnosticJSONString(from dictionary: [String: Any]) -> String? {
        let sanitized = sanitizedDiagnosticValue(dictionary, key: nil, depth: 0)
        guard JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
        else {
            return String(describing: sanitized)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func rawTelemetryJSONString(
        from params: [String: OpenClawProtocol.AnyCodable]?
    ) -> String? {
        guard let params else { return nil }
        let dictionary = params.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.value
        }
        guard JSONSerialization.isValidJSONObject(dictionary),
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        else {
            return String(describing: dictionary)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizedDiagnosticValue(_ raw: Any, key: String?, depth: Int) -> Any {
        if let key, isSensitiveDiagnosticKey(key) {
            return "<redacted>"
        }

        if depth >= 5 {
            return "<max-depth>"
        }

        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            return value
        case let value as [OpenClawProtocol.AnyCodable]:
            var items = value.prefix(maxDiagnosticArrayValues).map { item in
                sanitizedDiagnosticValue(item.value, key: nil, depth: depth + 1)
            }
            if value.count > maxDiagnosticArrayValues {
                items.append("...(\(value.count - maxDiagnosticArrayValues) more)")
            }
            return items
        case let value as [Any]:
            var items = value.prefix(maxDiagnosticArrayValues).map { item in
                sanitizedDiagnosticValue(item, key: nil, depth: depth + 1)
            }
            if value.count > maxDiagnosticArrayValues {
                items.append("...(\(value.count - maxDiagnosticArrayValues) more)")
            }
            return items
        case let value as [String: OpenClawProtocol.AnyCodable]:
            var sanitized: [String: Any] = [:]
            for key in value.keys.sorted().prefix(maxDiagnosticObjectKeys) {
                sanitized[key] = sanitizedDiagnosticValue(value[key]?.value as Any, key: key, depth: depth + 1)
            }
            if value.count > maxDiagnosticObjectKeys {
                sanitized["<truncatedKeys>"] = value.count - maxDiagnosticObjectKeys
            }
            return sanitized
        case let value as [String: Any]:
            var sanitized: [String: Any] = [:]
            for key in value.keys.sorted().prefix(maxDiagnosticObjectKeys) {
                sanitized[key] = sanitizedDiagnosticValue(value[key] as Any, key: key, depth: depth + 1)
            }
            if value.count > maxDiagnosticObjectKeys {
                sanitized["<truncatedKeys>"] = value.count - maxDiagnosticObjectKeys
            }
            return sanitized
        case is NSNull:
            return NSNull()
        default:
            return String(describing: raw)
        }
    }

    private static func isSensitiveDiagnosticKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return diagnosticSensitiveKeyFragments.contains { fragment in
            normalized.contains(fragment)
        }
    }

    private static func previewContext(value: String, keyPrefix: String) -> [String: String] {
        guard !value.isEmpty else { return [:] }
        if value.count <= 220 {
            return [
                "\(keyPrefix)Value": value,
                "\(keyPrefix)Length": "\(value.count)",
            ]
        }
        return [
            "\(keyPrefix)Head": String(value.prefix(220)),
            "\(keyPrefix)Tail": String(value.suffix(160)),
            "\(keyPrefix)Length": "\(value.count)",
        ]
    }

    private func encodeParams<T: Encodable>(_ value: T) throws -> [String: OpenClawProtocol.AnyCodable] {
        do {
            let data = try encoder.encode(value)
            return try decoder.decode([String: OpenClawProtocol.AnyCodable].self, from: data)
        } catch {
            throw GatewayDecodingError(method: "params.encode", message: error.localizedDescription)
        }
    }

    private func decodePayload<T: Decodable>(method: String, data: Data, as: T.Type) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GatewayDecodingError(method: method, message: error.localizedDescription)
        }
    }

    private func decodeJSONDictionary(
        method: String,
        data: Data
    ) throws -> [String: OpenClawProtocol.AnyCodable] {
        do {
            return try decoder.decode([String: OpenClawProtocol.AnyCodable].self, from: data)
        } catch {
            throw GatewayDecodingError(method: method, message: error.localizedDescription)
        }
    }

    private func boolValue(_ raw: Any?) -> Bool {
        if let bool = raw as? Bool {
            return bool
        }
        if let int = raw as? Int {
            return int != 0
        }
        if let string = raw as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y", "linked", "connected", "ready"].contains(normalized)
        }
        return false
    }

    private static func heartbeatTimestamp(from raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let interval = raw as? Double, interval > 0 {
            return Date(timeIntervalSince1970: interval)
        }
        if let interval = raw as? Int {
            return Date(timeIntervalSince1970: Double(interval))
        }
        if let timestamp = raw as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            if let interval = Double(trimmed), interval > 0 {
                return Date(timeIntervalSince1970: interval)
            }
            if let iso = ISO8601DateFormatter().date(from: trimmed) {
                return iso
            }
            if let numericDate = Double(trimmed), numericDate > 0 {
                return Date(timeIntervalSince1970: numericDate)
            }
        }
        return nil
    }

    private func mapError(_ error: Error) -> Error {
        if let typed = error as? OpenClawConnectionError {
            return typed
        }
        if let response = error as? GatewayResponseError {
            let code = response.code.uppercased()
            let message = response.message
            if code.contains("RATE") || message.lowercased().contains("rate limit") {
                let retryMs = retryAfterMs(from: response.details) ?? 60_000
                return OpenClawConnectionError.rateLimited(retryAfterMs: retryMs)
            }
            if code.contains("AUTH") || code.contains("UNAUTHORIZED") || code.contains("FORBIDDEN") {
                return OpenClawConnectionError.authFailed(message)
            }
            if message.lowercased().contains("slow consumer") {
                return OpenClawConnectionError.slowConsumer
            }
            return OpenClawConnectionError.disconnected(response.localizedDescription)
        }

        let nsError = error as NSError
        let message = nsError.localizedDescription
        let lower = message.lowercased()
        if nsError.domain == URLError.errorDomain {
            return OpenClawConnectionError.gatewayNotReachable
        }
        if lower.contains("slow consumer") {
            return OpenClawConnectionError.slowConsumer
        }
        if lower.contains("rate limit") {
            return OpenClawConnectionError.rateLimited(retryAfterMs: 60_000)
        }
        if lower.contains("auth") || lower.contains("unauthorized") || lower.contains("forbidden") {
            return OpenClawConnectionError.authFailed(message)
        }
        if lower.contains("no channel") || lower.contains("not connected") {
            return OpenClawConnectionError.noChannel
        }
        return OpenClawConnectionError.disconnected(message)
    }

    private func retryAfterMs(from details: [String: OpenClawProtocol.AnyCodable]) -> Int? {
        if let int = details["retryAfterMs"]?.value as? Int {
            return int
        }
        if let int = details["retryafterms"]?.value as? Int {
            return int
        }
        if let string = details["retryAfterMs"]?.value as? String, let int = Int(string) {
            return int
        }
        return nil
    }

    private static func stringValue(
        from dictionary: [String: OpenClawProtocol.AnyCodable]?,
        keys: [String]
    ) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key]?.value as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func runId(for frame: EventFrame) -> String? {
        if let runId = stringValue(from: frame.eventmeta, keys: ["runId", "runid"]) {
            return runId
        }

        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }
        if let runId = payload["runId"]?.value as? String, !runId.isEmpty {
            return runId
        }
        if let runId = payload["runid"]?.value as? String, !runId.isEmpty {
            return runId
        }
        if let nested = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable] {
            if let runId = nested["runId"]?.value as? String, !runId.isEmpty {
                return runId
            }
            if let runId = nested["runid"]?.value as? String, !runId.isEmpty {
                return runId
            }
        }
        return nil
    }

    private static func sessionKey(for frame: EventFrame) -> String? {
        if let key = stringValue(from: frame.eventmeta, keys: ["sessionKey", "sessionkey"]) {
            return key
        }

        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }
        if let key = payload["sessionKey"]?.value as? String, !key.isEmpty {
            return key
        }
        if let key = payload["sessionkey"]?.value as? String, !key.isEmpty {
            return key
        }
        if let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable] {
            if let key = data["sessionKey"]?.value as? String, !key.isEmpty {
                return key
            }
            if let key = data["sessionkey"]?.value as? String, !key.isEmpty {
                return key
            }
        }
        return nil
    }

    private static func lifecyclePhase(for frame: EventFrame) -> String? {
        if let stream = stringValue(from: frame.eventmeta, keys: ["stream"])?.lowercased(),
            stream == "lifecycle",
            let phase = stringValue(from: frame.eventmeta, keys: ["phase"])
        {
            return phase.lowercased()
        }

        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable],
            let stream = payload["stream"]?.value as? String,
            stream.lowercased() == "lifecycle",
            let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable],
            let phase = data["phase"]?.value as? String
        else {
            return nil
        }
        return phase.lowercased()
    }

    private static func closeCode(in reason: String) -> Int? {
        let pattern = #"(?:(?:close\s*)?code[\s:=]+)(\d{3,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsReason = reason as NSString
        let range = NSRange(location: 0, length: nsReason.length)
        guard let match = regex.firstMatch(in: reason, options: [], range: range),
            match.numberOfRanges > 1
        else {
            return nil
        }
        let value = nsReason.substring(with: match.range(at: 1))
        return Int(value)
    }

    static func classifyDisconnect(
        reason: String,
        intentional: Bool
    ) -> OpenClawDisconnectDisposition {
        if intentional {
            return .intentional
        }

        let lowered = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty {
            return .unexpected
        }

        if lowered.contains("slow consumer") {
            return .slowConsumer
        }
        if lowered.contains("auth") || lowered.contains("unauthorized") || lowered.contains("forbidden") {
            return .authFailure
        }

        let code = closeCode(in: lowered)
        switch code {
        case 1000:
            return .intentional
        case 1008:
            if lowered.contains("slow") {
                return .slowConsumer
            }
            return .authFailure
        case 1001, 1006:
            return .unexpected
        default:
            return .unexpected
        }
    }

    func _testEmitPush(_ push: GatewayPush) async {
        await handlePush(push)
    }

    private func handlePush(_ push: GatewayPush) async {
        if case let .event(frame) = push {
            if Self.runId(for: frame) != nil {
                recentEventFrames.append(frame)
                if recentEventFrames.count > Self.maxBufferedEventFrames {
                    let dropped = recentEventFrames.count - Self.maxBufferedEventFrames
                    recentEventFrames.removeFirst(dropped)
                    await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.event_buffer", id: nil))
                    { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                            Terra.Keys.Terra.openClawGateway: .bool(true),
                            "osaurus.openclaw.buffer.dropped": .int(dropped),
                            "osaurus.openclaw.buffer.limit": .int(Self.maxBufferedEventFrames),
                        ])
                    }
                    #if DEBUG
                    print("[OpenClawGatewayConnection] ⚠️ event buffer overflow — dropped \(dropped) frame(s)")
                    #endif
                }
            }

            if let runId = Self.runId(for: frame),
                let sessionKey = Self.sessionKey(for: frame)
            {
                activeRunSessionKeys[runId] = sessionKey
            }

            if let runId = Self.runId(for: frame),
                let lifecyclePhase = Self.lifecyclePhase(for: frame),
                lifecyclePhase == "end" || lifecyclePhase == "error"
            {
                activeRunSessionKeys.removeValue(forKey: runId)
            }
        }

        let listenerIDs = Array(listeners.keys)
        for id in listenerIDs {
            await enqueuePush(push, for: id)
        }
    }

    private func enqueuePush(_ push: GatewayPush, for listenerID: UUID) async {
        guard var registration = listeners[listenerID] else { return }

        if registration.pendingPushes.count >= Self.maxPendingPushesPerListener {
            let dropped = registration.pendingPushes.count - Self.maxPendingPushesPerListener + 1
            registration.pendingPushes.removeFirst(dropped)
            await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.gateway.listener_backlog", id: listenerID.uuidString))
            { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    "osaurus.openclaw.listener.dropped": .int(dropped),
                    "osaurus.openclaw.listener.backlog_limit": .int(Self.maxPendingPushesPerListener),
                ])
            }
            #if DEBUG
            print(
                "[OpenClawGatewayConnection] ⚠️ listener backlog overflow — dropped \(dropped) push(es) for listener \(listenerID.uuidString)"
            )
            #endif
        }

        registration.pendingPushes.append(push)
        let shouldStartDispatch = !registration.isDispatching
        if shouldStartDispatch {
            registration.isDispatching = true
        }
        listeners[listenerID] = registration

        guard shouldStartDispatch else { return }
        Task { [weak self] in
            await self?.drainQueuedPushes(for: listenerID)
        }
    }

    private func drainQueuedPushes(for listenerID: UUID) async {
        while true {
            guard var registration = listeners[listenerID] else { return }
            guard !registration.pendingPushes.isEmpty else {
                registration.isDispatching = false
                listeners[listenerID] = registration
                return
            }

            let push = registration.pendingPushes.removeFirst()
            let handler = registration.handler
            listeners[listenerID] = registration
            await handler(push)
        }
    }

    private func handleDisconnect(_ reason: String) async {
        let wasConnected = connected
        await shutdownChannel()

        if !reason.isEmpty {
            let listenerIDs = Array(listeners.keys)
            for id in listenerIDs {
                await enqueuePush(.disconnected(reason: reason), for: id)
            }
        }

        let disposition = Self.classifyDisconnect(reason: reason, intentional: intentionalDisconnect)
        await emitGatewayDiagnostic(
            level: .warning,
            event: "gateway.disconnect.received",
            context: [
                "reason": reason,
                "wasConnected": wasConnected ? "true" : "false",
                "intentional": intentionalDisconnect ? "true" : "false",
                "disposition": "\(disposition)",
                "closeCode": Self.closeCode(in: reason).map(String.init) ?? "<none>",
            ]
        )
        switch disposition {
        case .intentional:
            await transitionConnectionState(.disconnected)

        case .authFailure:
            reconnectTask?.cancel()
            reconnectTask = nil
            await emitGatewayDiagnostic(
                level: .error,
                event: "gateway.disconnect.authFailure",
                context: ["reason": reason]
            )
            await transitionConnectionState(.failed("Gateway authentication failed. Reconfigure credentials."))

        case .slowConsumer:
            guard wasConnected else { return }
            await emitGatewayDiagnostic(
                level: .warning,
                event: "gateway.disconnect.slowConsumer.reconnect",
                context: ["reason": reason]
            )
            await transitionConnectionState(.disconnected)
            await beginReconnect(after: reason, immediate: true)

        case .unexpected:
            guard wasConnected else { return }
            await emitGatewayDiagnostic(
                level: .warning,
                event: "gateway.disconnect.unexpected.reconnect",
                context: ["reason": reason]
            )
            await transitionConnectionState(.disconnected)
            await beginReconnect(after: reason, immediate: false)
        }
    }

#if DEBUG
    func _testSetReconnectContext(host: String, port: Int, token: String?) {
        let wsURL = URL(string: "ws://\(host):\(port)/ws")!
        let healthURL = URL(string: "http://\(host):\(port)/health")
        connectionParameters = OpenClawConnectionParameters(wsURL: wsURL, healthURL: healthURL, token: token)
    }

    func _testSetConnected(_ value: Bool) {
        connected = value
    }

    func _testTriggerDisconnect(reason: String) async {
        await handleDisconnect(reason)
    }

    func _testWaitForReconnectCompletion() async {
        if let reconnectTask {
            _ = await reconnectTask.result
        }
    }

    nonisolated static func _testClassifyDisconnect(
        reason: String,
        intentional: Bool
    ) -> OpenClawDisconnectDisposition {
        classifyDisconnect(reason: reason, intentional: intentional)
    }
#endif
}
