//
//  OpenClawGatewayConnection.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol

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
            return "Gateway connection is not established."
        }
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
    let host: String
    let port: Int
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
    private var listeners: [UUID: @Sendable (GatewayPush) async -> Void] = [:]
    private var connectionStateListeners: [UUID: @Sendable (OpenClawGatewayConnectionState) async -> Void] = [:]
    private var recentEventFrames: [EventFrame] = []
    private var activeRunSessionKeys: [String: String] = [:]
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
    private static let maxBufferedEventFrames = 128
    private static let reconnectBackoffSeconds = [1, 2, 4, 8, 16, 30]
    private static let maxReconnectAttempts = 5

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

    public func connect(host: String, port: Int, token: String?) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionalDisconnect = false
        connectionParameters = OpenClawConnectionParameters(host: host, port: port, token: token)
        await transitionConnectionState(.connecting)
        await shutdownChannel()

        do {
            try await performConnect(host: host, port: port, token: token)
            await transitionConnectionState(.connected)
        } catch {
            let mapped = mapError(error)
            await transitionConnectionState(.failed(mapped.localizedDescription))
            throw mapped
        }
    }

    public func disconnect() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
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

    public func modelsList() async throws -> [String] {
        let data = try await requestRaw(method: "models.list", params: nil)
        let payload = try decodePayload(method: "models.list", data: data, as: ModelsListResult.self)
        return payload.models.map(\.id)
    }

    public func configGet() async throws -> [String: OpenClawProtocol.AnyCodable] {
        let data = try await requestRaw(method: "config.get", params: nil)
        if let raw = try? decodeJSONDictionary(method: "config.get", data: data) {
            return raw
        }
        let typed = try decodePayload(method: "config.get", data: data, as: TalkConfigResult.self)
        return typed.config
    }

    public func announcePresence() async throws {
        let version =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev"
        let params: [String: OpenClawProtocol.AnyCodable] = [
            "text": OpenClawProtocol.AnyCodable("Node: Osaurus"),
            "roles": OpenClawProtocol.AnyCodable(["chat-client"]),
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

    public func refresh() async {
        let runIds = Array(activeRunSessionKeys.keys)
        for runId in runIds {
            let params: [String: OpenClawProtocol.AnyCodable] = [
                "runId": OpenClawProtocol.AnyCodable(runId),
                "timeoutMs": OpenClawProtocol.AnyCodable(0)
            ]

            guard let data = try? await requestRaw(method: "agent.wait", params: params),
                let snapshot = try? decodePayload(method: "agent.wait", data: data, as: AgentWaitResponse.self)
            else {
                continue
            }

            if snapshot.status.lowercased() != "timeout" {
                activeRunSessionKeys.removeValue(forKey: runId)
            }
        }
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
        listeners[id] = handler
        return id
    }

    public func removeEventListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func performConnect(host: String, port: Int, token: String?) async throws {
        try await assertGatewayHealth(host: host, port: port)

        let wsURL = URL(string: "ws://\(host):\(port)/ws")!
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
            try await newChannel.connect()
            channel = newChannel
            connected = true
        } catch {
            throw mapError(error)
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
        guard let connectionParameters else {
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
        for attempt in 1...Self.maxReconnectAttempts {
            guard !Task.isCancelled else { return }

            await transitionConnectionState(.reconnecting(attempt: attempt))
            let delay = Self.delaySeconds(forAttempt: attempt, immediateFirstAttempt: immediate)
            if delay > 0 {
                await sleepHook(UInt64(delay) * 1_000_000_000)
            }
            guard !Task.isCancelled else { return }

            do {
                await shutdownChannel()

                if let reconnectConnectHook {
                    try await reconnectConnectHook(parameters.host, parameters.port, parameters.token)
                    connected = true
                } else {
                    try await performConnect(host: parameters.host, port: parameters.port, token: parameters.token)
                }

                if let reconnectResyncHook {
                    await reconnectResyncHook()
                } else {
                    try? await announcePresence()
                    await refresh()
                }

                reconnectTask = nil
                await transitionConnectionState(.reconnected)
                await transitionConnectionState(.connected)
                return
            } catch {
                let mapped = mapError(error)
                if case .authFailed(let message) = mapped as? OpenClawConnectionError {
                    reconnectTask = nil
                    await transitionConnectionState(.failed(message))
                    return
                }
                if attempt == Self.maxReconnectAttempts {
                    break
                }
            }
        }

        reconnectTask = nil
        await transitionConnectionState(
            .failed("OpenClaw disconnected and failed to reconnect after \(Self.maxReconnectAttempts) attempts: \(reason)")
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

    private func transitionConnectionState(_ state: OpenClawGatewayConnectionState) async {
        connectionState = state
        for listener in connectionStateListeners.values {
            await listener(state)
        }
    }

    private func assertGatewayHealth(host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/health") else {
            throw OpenClawConnectionError.gatewayNotReachable
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw OpenClawConnectionError.gatewayNotReachable
            }
        } catch {
            throw OpenClawConnectionError.gatewayNotReachable
        }
    }

    private func requestRaw(
        method: String,
        params: [String: OpenClawProtocol.AnyCodable]?
    ) async throws -> Data {
        if let requestExecutor {
            return try await requestExecutor(method, params)
        }

        let retryDelaysMs = [0, 150, 400, 900]
        var lastError: Error = OpenClawConnectionError.noChannel

        for delay in retryDelaysMs {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }

            do {
                guard let channel else {
                    throw OpenClawConnectionError.noChannel
                }
                return try await channel.request(method: method, params: params, timeoutMs: nil)
            } catch {
                lastError = mapError(error)
            }
        }

        throw lastError
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

    private static func runId(for frame: EventFrame) -> String? {
        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }
        if let runId = payload["runId"]?.value as? String {
            return runId
        }
        if let runId = payload["runid"]?.value as? String {
            return runId
        }
        if let nested = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable],
            let runId = nested["runId"]?.value as? String
        {
            return runId
        }
        return nil
    }

    private static func sessionKey(for frame: EventFrame) -> String? {
        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }
        if let key = payload["sessionKey"]?.value as? String, !key.isEmpty {
            return key
        }
        if let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable],
            let key = data["sessionKey"]?.value as? String,
            !key.isEmpty
        {
            return key
        }
        return nil
    }

    private static func lifecyclePhase(for frame: EventFrame) -> String? {
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
            recentEventFrames.append(frame)
            if recentEventFrames.count > Self.maxBufferedEventFrames {
                recentEventFrames.removeFirst(recentEventFrames.count - Self.maxBufferedEventFrames)
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

        for listener in listeners.values {
            Task {
                await listener(push)
            }
        }
    }

    private func handleDisconnect(_ reason: String) async {
        let wasConnected = connected
        connected = false

        if !reason.isEmpty {
            for listener in listeners.values {
                Task {
                    await listener(.seqGap(expected: 0, received: 0))
                }
            }
        }

        let disposition = Self.classifyDisconnect(reason: reason, intentional: intentionalDisconnect)
        switch disposition {
        case .intentional:
            await transitionConnectionState(.disconnected)

        case .authFailure:
            reconnectTask?.cancel()
            reconnectTask = nil
            await transitionConnectionState(.failed("Gateway authentication failed. Reconfigure credentials."))

        case .slowConsumer:
            guard wasConnected else { return }
            await transitionConnectionState(.disconnected)
            await beginReconnect(after: reason, immediate: true)

        case .unexpected:
            guard wasConnected else { return }
            await transitionConnectionState(.disconnected)
            await beginReconnect(after: reason, immediate: false)
        }
    }

#if DEBUG
    func _testSetReconnectContext(host: String, port: Int, token: String?) {
        connectionParameters = OpenClawConnectionParameters(host: host, port: port, token: token)
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
