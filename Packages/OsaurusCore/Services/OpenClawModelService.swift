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
    private struct ChatTextPayload {
        let snapshot: String?
        let delta: String?
    }

    private enum SnapshotTransition {
        case append(String)
        case unchanged
        case regressed
        case rewritten
    }

    struct ChatEventPayload: Decodable {
        var runId: String?
        let state: String
        let message: OpenClawProtocol.AnyCodable?
        let errorMessage: String?
    }

    struct AgentEventPayload: Decodable {
        var runId: String?
        var stream: String?
        var data: [String: OpenClawProtocol.AnyCodable]?
    }

    struct EventMeta {
        let channel: String?
        let runId: String?
        let stream: String?
        let phase: String?
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
        let (runId, sessionKey, eventStream) = try await startGatewayRun(
            messages: messages,
            requestedModel: requestedModel
        )
        let service = self

        return AsyncThrowingStream { continuation in
            Task {
                var previousChatTextSnapshot = ""
                for await frame in eventStream {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if let chat = Self.decodeChatEvent(frame),
                        chat.runId == runId,
                        chat.state == "delta"
                    {
                        let payload = Self.extractChatTextPayload(chat.message)

                        // Preferred path: explicit incremental delta from gateway.
                        if let explicitDelta = payload.delta, !explicitDelta.isEmpty {
                            continuation.yield(explicitDelta)
                            if let snapshot = payload.snapshot, !snapshot.isEmpty {
                                previousChatTextSnapshot = snapshot
                            } else {
                                previousChatTextSnapshot += explicitDelta
                            }
                        } else if let snapshot = payload.snapshot, !snapshot.isEmpty {
                            let previousSnapshot = previousChatTextSnapshot
                            switch Self.normalizeSnapshotTransition(
                                snapshot,
                                previousSnapshot: &previousChatTextSnapshot
                            ) {
                            case .append(let delta):
                                if !delta.isEmpty {
                                    continuation.yield(delta)
                                }
                            case .unchanged:
                                break
                            case .regressed:
                                await service.emitNonPrefixSnapshotTelemetry(
                                    event: "chat.delta.snapshot_regressed",
                                    runId: runId,
                                    previousSnapshot: previousSnapshot,
                                    nextSnapshot: snapshot
                                )
                            case .rewritten:
                                await service.emitNonPrefixSnapshotTelemetry(
                                    event: "chat.delta.snapshot_rewritten",
                                    runId: runId,
                                    previousSnapshot: previousSnapshot,
                                    nextSnapshot: snapshot
                                )
                            }
                        }
                    }

                    if let terminal = Self.terminalState(for: frame, runId: runId) {
                        switch terminal {
                        case .success:
                            continuation.finish()
                        case .failure(let message):
                            let resolved = await service.resolveGatewayFailureMessage(
                                primary: message,
                                sessionKey: sessionKey
                            )
                            continuation.finish(
                                throwing: OpenClawModelServiceError.gatewayError(resolved)
                            )
                        }
                        return
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
        let (runId, sessionKey, eventStream) = try await startGatewayRun(
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
            },
            onSync: onSync
        )
        processor.startRun(runId: runId, turn: turn)
        OpenClawManager.shared.pauseNotificationPolling()
        defer { OpenClawManager.shared.resumeNotificationPolling() }

        for await frame in eventStream {
            if Task.isCancelled {
                processor.endRun(turn: turn)
                throw CancellationError()
            }

            processor.processEvent(frame, turn: turn)

            if let terminal = Self.terminalState(for: frame, runId: runId) {
                processor.endRun(turn: turn)
                switch terminal {
                case .success:
                    return
                case .failure(let message):
                    let resolved = await resolveGatewayFailureMessage(
                        primary: message,
                        sessionKey: sessionKey
                    )
                    throw OpenClawModelServiceError.gatewayError(resolved)
                }
            }
        }

        processor.endRun(turn: turn)
    }

    private func startGatewayRun(
        messages: [ChatMessage],
        requestedModel: String?
    ) async throws -> (runId: String, sessionKey: String, events: AsyncStream<EventFrame>) {
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
        return (runId, sessionKey, events)
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

    private func resolveGatewayFailureMessage(primary: String?, sessionKey: String) async -> String {
        let normalizedPrimary = Self.normalizedGatewayErrorMessage(primary)
        if let normalizedPrimary,
            !Self.isGenericGatewayFailureMessage(normalizedPrimary)
        {
            return normalizedPrimary
        }

        if let historyMessage = await historyDerivedErrorMessage(sessionKey: sessionKey) {
            return historyMessage
        }

        return normalizedPrimary ?? "unknown error"
    }

    private func historyDerivedErrorMessage(sessionKey: String) async -> String? {
        guard !sessionKey.isEmpty else { return nil }
        guard let history = try? await connection.chatHistory(sessionKey: sessionKey, limit: 8),
            let messages = history.messages,
            !messages.isEmpty
        else {
            return nil
        }

        for message in messages.reversed() {
            if let extracted = Self.historyErrorMessage(from: message) {
                return extracted
            }
        }
        return nil
    }

    private static func historyErrorMessage(from message: OpenClawProtocol.AnyCodable) -> String? {
        guard let dictionary = message.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }
        guard let role = normalizedString(dictionary["role"]?.value as? String)?.lowercased(),
            role == "assistant"
        else {
            return nil
        }

        if let explicitError = normalizedString(dictionary["errorMessage"]?.value as? String)
            ?? normalizedString(dictionary["error"]?.value as? String)
        {
            return explicitError
        }

        let stopReason = normalizedString(dictionary["stopReason"]?.value as? String)?.lowercased()
            ?? normalizedString(dictionary["stop_reason"]?.value as? String)?.lowercased()
        guard stopReason == "error" else {
            return nil
        }

        guard let contentItems = dictionary["content"]?.value as? [OpenClawProtocol.AnyCodable] else {
            return nil
        }

        for item in contentItems {
            guard let content = item.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            if let text = normalizedString(content["errorMessage"]?.value as? String)
                ?? normalizedString(content["error"]?.value as? String)
                ?? normalizedString(content["text"]?.value as? String)
            {
                return text
            }
        }

        return nil
    }

    private static func normalizedGatewayErrorMessage(_ raw: String?) -> String? {
        normalizedString(raw)
    }

    private static func isGenericGatewayFailureMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "unknown error"
            || normalized == "openclaw run failed"
            || normalized == "openclaw run failed."
    }

    private static func decodeChatEvent(_ frame: EventFrame) -> ChatEventPayload? {
        let meta = decodeEventMeta(frame)
        guard eventChannel(for: frame, meta: meta) == "chat",
            let payload = frame.payload
        else {
            return nil
        }
        guard var decoded = try? GatewayPayloadDecoding.decode(payload, as: ChatEventPayload.self) else {
            return nil
        }
        if decoded.runId == nil {
            decoded.runId = meta.runId
        }
        return decoded
    }

    private static func decodeAgentEvent(_ frame: EventFrame) -> AgentEventPayload? {
        let meta = decodeEventMeta(frame)
        guard eventChannel(for: frame, meta: meta) == "agent",
            let payload = frame.payload
        else {
            return nil
        }
        guard var decoded = try? GatewayPayloadDecoding.decode(payload, as: AgentEventPayload.self) else {
            return nil
        }
        if decoded.runId == nil {
            decoded.runId = meta.runId
        }
        if decoded.stream == nil {
            decoded.stream = meta.stream
        }
        return decoded
    }

    private static func extractChatTextPayload(_ message: OpenClawProtocol.AnyCodable?) -> ChatTextPayload {
        guard let messageDictionary = message?.value as? [String: OpenClawProtocol.AnyCodable],
            let contentArray = messageDictionary["content"]?.value as? [OpenClawProtocol.AnyCodable]
        else {
            return ChatTextPayload(snapshot: nil, delta: nil)
        }

        var snapshotPieces: [String] = []
        var deltaPieces: [String] = []
        for entry in contentArray {
            guard let dictionary = entry.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            if let text = dictionary["text"]?.value as? String, !text.isEmpty {
                snapshotPieces.append(text)
            }
            if let delta = dictionary["delta"]?.value as? String, !delta.isEmpty {
                deltaPieces.append(delta)
            }
        }
        return ChatTextPayload(
            snapshot: snapshotPieces.isEmpty ? nil : snapshotPieces.joined(),
            delta: deltaPieces.isEmpty ? nil : deltaPieces.joined()
        )
    }

    private static func normalizeSnapshotTransition(
        _ snapshot: String,
        previousSnapshot: inout String
    ) -> SnapshotTransition {
        if previousSnapshot.isEmpty {
            previousSnapshot = snapshot
            return .append(snapshot)
        }

        if snapshot == previousSnapshot {
            return .unchanged
        }

        if snapshot.hasPrefix(previousSnapshot) {
            let delta = String(snapshot.dropFirst(previousSnapshot.count))
            previousSnapshot = snapshot
            return delta.isEmpty ? .unchanged : .append(delta)
        }

        if previousSnapshot.hasPrefix(snapshot) {
            previousSnapshot = snapshot
            return .regressed
        }

        previousSnapshot = snapshot
        return .rewritten
    }

    private func emitNonPrefixSnapshotTelemetry(
        event: String,
        runId: String,
        previousSnapshot: String,
        nextSnapshot: String
    ) async {
        let context: [String: String] = [
            "runId": runId,
            "previousLength": "\(previousSnapshot.count)",
            "nextLength": "\(nextSnapshot.count)",
            "previousPrefixOfNext": nextSnapshot.hasPrefix(previousSnapshot) ? "true" : "false",
            "nextPrefixOfPrevious": previousSnapshot.hasPrefix(nextSnapshot) ? "true" : "false",
        ]

        await StartupDiagnostics.shared.emit(
            level: .warning,
            component: "openclaw.stream",
            event: event,
            context: context
        )
        print(
            "[Osaurus][OpenClawStream] \(event) run=\(runId) prevLen=\(previousSnapshot.count) nextLen=\(nextSnapshot.count)"
        )
    }

    private enum TerminalState {
        case success
        case failure(String?)
    }

    private static func decodeEventMeta(_ frame: EventFrame) -> EventMeta {
        let eventMeta = frame.eventmeta
        let channel = normalizedString(eventMeta?["channel"]?.value as? String)?.lowercased()
        let runId = normalizedString(eventMeta?["runId"]?.value as? String)
            ?? normalizedString(eventMeta?["runid"]?.value as? String)
        let stream = normalizedString(eventMeta?["stream"]?.value as? String)?.lowercased()
        let phase = normalizedString(eventMeta?["phase"]?.value as? String)?.lowercased()
        return EventMeta(channel: channel, runId: runId, stream: stream, phase: phase)
    }

    private static func eventChannel(for frame: EventFrame, meta: EventMeta) -> String {
        if let channel = meta.channel {
            return channel
        }
        let eventName = frame.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if eventName == "chat" || eventName.hasPrefix("chat.") || eventName.contains("chat") {
            return "chat"
        }
        if eventName == "agent" || eventName.hasPrefix("agent.") || eventName.contains("agent") {
            return "agent"
        }
        return eventName
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func terminalState(for frame: EventFrame, runId: String) -> TerminalState? {
        if let chat = decodeChatEvent(frame), chat.runId == runId {
            switch chat.state {
            case "final", "aborted":
                return .success
            case "error":
                return .failure(chat.errorMessage)
            default:
                break
            }
        }

        if let agent = decodeAgentEvent(frame), agent.runId == runId {
            let stream = normalizedString(agent.stream)?.lowercased() ?? decodeEventMeta(frame).stream
            let data = agent.data ?? [:]
            if stream == "error" {
                let message = (data["message"]?.value as? String)
                    ?? (data["error"]?.value as? String)
                return .failure(message)
            }
            if stream == "lifecycle" {
                let phase = (data["phase"]?.value as? String)?.lowercased()
                    ?? decodeEventMeta(frame).phase
                    ?? ""
                if phase == "end" {
                    return .success
                }
                if phase == "error" {
                    let message = (data["error"]?.value as? String)
                        ?? (data["message"]?.value as? String)
                    return .failure(message)
                }
            }
        }

        return nil
    }
}
