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

private struct OpenClawSessionsPatchResponse: Codable, Sendable {
    let ok: Bool?
    let key: String
}

public actor OpenClawGatewayConnection {
    public typealias RequestExecutor = @Sendable (
        _ method: String,
        _ params: [String: OpenClawProtocol.AnyCodable]?
    ) async throws -> Data

    public static let shared = OpenClawGatewayConnection()

    private var channel: GatewayChannelActor?
    private var listeners: [UUID: @Sendable (GatewayPush) async -> Void] = [:]
    private var connected = false
    private let requestExecutor: RequestExecutor?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(requestExecutor: RequestExecutor? = nil) {
        self.requestExecutor = requestExecutor
    }

    public var isConnected: Bool {
        connected
    }

    public func connect(host: String, port: Int, token: String?) async throws {
        await disconnect()
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

        let channel = GatewayChannelActor(
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
            try await channel.connect()
            self.channel = channel
            self.connected = true
        } catch {
            throw mapError(error)
        }
    }

    public func disconnect() async {
        if let channel {
            await channel.shutdown()
        }
        self.channel = nil
        self.connected = false
    }

    public func health() async throws -> [String: OpenClawProtocol.AnyCodable] {
        let data = try await requestRaw(method: "health", params: nil)
        return try decodeJSONDictionary(method: "health", data: data)
    }

    public func channelsStatus() async throws -> [[String: OpenClawProtocol.AnyCodable]] {
        let data = try await requestRaw(method: "channels.status", params: nil)
        let result = try decodePayload(method: "channels.status", data: data, as: ChannelsStatusResult.self)

        let ids = result.channelorder.isEmpty ? Array(result.channels.keys).sorted() : result.channelorder
        return ids.map { id in
            let channelState = result.channels[id]?.value as? [String: OpenClawProtocol.AnyCodable]
            let linked = boolValue(
                channelState?["linked"]?.value
                    ?? channelState?["isLinked"]?.value
                    ?? channelState?["configured"]?.value
            )
            let connected = boolValue(
                channelState?["connected"]?.value
                    ?? channelState?["isConnected"]?.value
                    ?? channelState?["ready"]?.value
            )
            let name = (result.channellabels[id]?.value as? String) ?? id.capitalized
            let systemImage = (result.channelsystemimages?[id]?.value as? String)
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
        return try decodePayload(method: "chat.send", data: data, as: OpenClawChatSendResponse.self)
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

    public func subscribeToEvents(runId: String) -> AsyncStream<EventFrame> {
        AsyncStream { continuation in
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

    func _testEmitPush(_ push: GatewayPush) async {
        await handlePush(push)
    }

    private func handlePush(_ push: GatewayPush) async {
        for listener in listeners.values {
            Task {
                await listener(push)
            }
        }
    }

    private func handleDisconnect(_ reason: String) async {
        connected = false
        if !reason.isEmpty {
            for listener in listeners.values {
                Task {
                    await listener(.seqGap(expected: 0, received: 0))
                }
            }
        }
    }
}
