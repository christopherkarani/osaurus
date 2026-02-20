//
//  OpenClawModelService.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol

enum OpenClawModelServiceError: LocalizedError {
    case unsupportedModel(String?)
    case missingUserMessage
    case gatewayError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model):
            return "Unsupported OpenClaw model identifier: \(model ?? "<nil>")"
        case .missingUserMessage:
            return "OpenClaw chat.send requires a user message."
        case .gatewayError(let message):
            return "OpenClaw gateway error: \(message)"
        }
    }
}

actor OpenClawModelService: ModelService {
    struct ChatEventPayload: Decodable {
        let runId: String
        let state: String
        let message: OpenClawProtocol.AnyCodable?
        let errorMessage: String?
    }

    struct AgentEventPayload: Decodable {
        let runId: String
        let stream: String
        let data: [String: OpenClawProtocol.AnyCodable]
    }

    static let shared = OpenClawModelService()

    static let sessionPrefix = "openclaw:"
    static let modelPrefix = "openclaw-model:"

    nonisolated let id = "openclaw"

    private let connection: OpenClawGatewayConnection
    private let availabilityProvider: @Sendable () -> Bool

    init(
        connection: OpenClawGatewayConnection = .shared,
        availabilityProvider: @escaping @Sendable () -> Bool = { true }
    ) {
        self.connection = connection
        self.availabilityProvider = availabilityProvider
    }

    nonisolated func isAvailable() -> Bool {
        availabilityProvider()
    }

    nonisolated func handles(requestedModel: String?) -> Bool {
        guard let requestedModel else { return false }
        return requestedModel.hasPrefix(Self.sessionPrefix) || requestedModel.hasPrefix(Self.modelPrefix)
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: []
        )

        var combined = ""
        for try await delta in stream {
            combined += delta
        }
        return combined
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters _: GenerationParameters,
        requestedModel: String?,
        stopSequences _: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let (runId, eventStream) = try await startGatewayRun(
            messages: messages,
            requestedModel: requestedModel
        )

        return AsyncThrowingStream { continuation in
            Task {
                for await frame in eventStream {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    guard let chat = Self.decodeChatEvent(frame), chat.runId == runId else { continue }

                    switch chat.state {
                    case "delta":
                        if let text = Self.extractChatText(chat.message), !text.isEmpty {
                            continuation.yield(text)
                        }
                    case "final", "aborted":
                        continuation.finish()
                        return
                    case "error":
                        continuation.finish(
                            throwing: OpenClawModelServiceError.gatewayError(
                                chat.errorMessage ?? "unknown error"
                            )
                        )
                        return
                    default:
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    @MainActor
    func streamRunIntoTurn(
        messages: [ChatMessage],
        requestedModel: String?,
        turn: ChatTurn,
        onSync: (() -> Void)? = nil
    ) async throws {
        let (runId, eventStream) = try await startGatewayRun(
            messages: messages,
            requestedModel: requestedModel
        )

        let processor = OpenClawEventProcessor(
            onSequenceGap: { [connection, runId] expectedSeq, receivedSeq in
                Task {
                    await connection.registerSequenceGap(
                        runId: runId,
                        expectedSeq: expectedSeq,
                        receivedSeq: receivedSeq
                    )
                }
            }
        )
        processor.startRun(runId: runId, turn: turn)

        for await frame in eventStream {
            if Task.isCancelled {
                processor.endRun(turn: turn)
                throw CancellationError()
            }

            processor.processEvent(frame, turn: turn)
            onSync?()

            if let terminal = Self.terminalState(for: frame, runId: runId) {
                processor.endRun(turn: turn)
                switch terminal {
                case .success:
                    return
                case .failure(let message):
                    throw OpenClawModelServiceError.gatewayError(message)
                }
            }
        }

        processor.endRun(turn: turn)
    }

    private func startGatewayRun(
        messages: [ChatMessage],
        requestedModel: String?
    ) async throws -> (runId: String, events: AsyncStream<EventFrame>) {
        guard let sessionKey = extractSessionKey(from: requestedModel) else {
            throw OpenClawModelServiceError.unsupportedModel(requestedModel)
        }
        guard let message = latestUserMessage(in: messages) else {
            throw OpenClawModelServiceError.missingUserMessage
        }

        let response = try await connection.chatSend(
            message: message,
            sessionKey: sessionKey,
            clientRunId: UUID().uuidString
        )
        let runId = response.runId
        let events = await connection.subscribeToEvents(runId: runId)
        return (runId, events)
    }

    private func latestUserMessage(in messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == "user" {
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func extractSessionKey(from requestedModel: String?) -> String? {
        guard let requestedModel else { return nil }

        if requestedModel.hasPrefix(Self.sessionPrefix) {
            let key = String(requestedModel.dropFirst(Self.sessionPrefix.count))
            return key.isEmpty ? nil : key
        }

        // Runtime routing must use openclaw:<sessionKey>. openclaw-model:<modelId> is
        // only a pre-session selection token and must be converted before send.
        return nil
    }

    private static func decodeChatEvent(_ frame: EventFrame) -> ChatEventPayload? {
        guard frame.event.lowercased().contains("chat"),
            let payload = frame.payload
        else {
            return nil
        }
        return try? GatewayPayloadDecoding.decode(payload, as: ChatEventPayload.self)
    }

    private static func decodeAgentEvent(_ frame: EventFrame) -> AgentEventPayload? {
        guard frame.event.lowercased().contains("agent"),
            let payload = frame.payload
        else {
            return nil
        }
        return try? GatewayPayloadDecoding.decode(payload, as: AgentEventPayload.self)
    }

    private static func extractChatText(_ message: OpenClawProtocol.AnyCodable?) -> String? {
        guard let messageDictionary = message?.value as? [String: OpenClawProtocol.AnyCodable],
            let contentArray = messageDictionary["content"]?.value as? [OpenClawProtocol.AnyCodable]
        else {
            return nil
        }

        var pieces: [String] = []
        for entry in contentArray {
            guard let dictionary = entry.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            if let text = dictionary["text"]?.value as? String, !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }

    private enum TerminalState {
        case success
        case failure(String)
    }

    private static func terminalState(for frame: EventFrame, runId: String) -> TerminalState? {
        if let chat = decodeChatEvent(frame), chat.runId == runId {
            switch chat.state {
            case "final", "aborted":
                return .success
            case "error":
                return .failure(chat.errorMessage ?? "unknown error")
            default:
                break
            }
        }

        if let agent = decodeAgentEvent(frame), agent.runId == runId {
            if agent.stream == "error" {
                let message = (agent.data["message"]?.value as? String)
                    ?? (agent.data["error"]?.value as? String)
                    ?? "unknown error"
                return .failure(message)
            }
            if agent.stream == "lifecycle" {
                let phase = (agent.data["phase"]?.value as? String)?.lowercased() ?? ""
                if phase == "end" {
                    return .success
                }
                if phase == "error" {
                    let message = (agent.data["error"]?.value as? String)
                        ?? (agent.data["message"]?.value as? String)
                        ?? "unknown error"
                    return .failure(message)
                }
            }
        }

        return nil
    }
}
