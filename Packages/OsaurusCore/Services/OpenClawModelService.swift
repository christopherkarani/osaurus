//
//  OpenClawModelService.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol
import Terra

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

    private enum PayloadDeltaResolution {
        case append(String)
        case unchanged
        case regressed(previous: String, next: String)
        case rewritten(previous: String, next: String)
    }

    private struct AuthFailureDebugSnapshot {
        let sessionKey: String
        let modelRef: String?
        let providerId: String?
        let providerAPI: String?
        let providerBaseURL: String?
        let providerHasAPIKey: Bool?
        let hasEnvKimi: Bool
        let hasEnvMoonshot: Bool
        let hasConfiguredKimiCodingProvider: Bool
        let hasConfiguredMoonshotProvider: Bool
        let hint: String?
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
#if DEBUG
    nonisolated(unsafe) static var lifecycleFinalizationGraceNanosecondsOverride: UInt64?
#endif
    private static let defaultLifecycleFinalizationGraceNanoseconds: UInt64 = 2_500_000_000

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
        let (runId, sessionKey, eventStream) = try await Terra.withAgentInvocationSpan(
            agent: .init(name: "openclaw.model.stream.bootstrap", id: nil)
        ) { scope in
            let result = try await startGatewayRun(
                messages: messages,
                requestedModel: requestedModel
            )
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.run.id": .string(result.runId),
                "osaurus.openclaw.session.key": .string(result.sessionKey),
            ])
            return result
        }
        let service = self
        let requestedModelValue = requestedModel ?? ""
        let messageCount = messages.count

        return AsyncThrowingStream { continuation in
            let producerTask = Task {
                _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.model.stream", id: runId)) {
                    scope in
                    scope.setAttributes([
                        Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                        Terra.Keys.Terra.openClawGateway: .bool(true),
                        Terra.Keys.GenAI.providerName: .string("openclaw"),
                        "osaurus.openclaw.run.id": .string(runId),
                        "osaurus.openclaw.session.key": .string(sessionKey),
                        "osaurus.openclaw.requested_model": .string(requestedModelValue),
                        "osaurus.openclaw.messages.count": .int(messageCount),
                    ])

                    var previousAssistantSnapshot = ""
                    var hasObservedAgentLifecycleStart = false
                    var sawChatFinal = false
                    var lifecycleFallbackTask: Task<Void, Never>?

                    func cancelLifecycleFallback() {
                        lifecycleFallbackTask?.cancel()
                        lifecycleFallbackTask = nil
                    }

                    func scheduleLifecycleFallback() {
                        cancelLifecycleFallback()
                        lifecycleFallbackTask = Task {
                            try? await Task.sleep(nanoseconds: Self.lifecycleFinalizationGraceNanoseconds)
                            guard !Task.isCancelled else { return }
                            continuation.finish()
                        }
                    }

                    defer { cancelLifecycleFallback() }

                    for await frame in eventStream {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        if let chat = Self.decodeChatEvent(frame), chat.runId == runId {
                            // Short runs may only carry assistant text in `chat.final`.
                            // Consume both `delta` and terminal chat payload text.
                            if chat.state == "delta" || chat.state == "final" || chat.state == "aborted" {
                                if chat.state == "final" || chat.state == "aborted" {
                                    sawChatFinal = true
                                }

                                let payload = Self.extractChatTextPayload(chat.message)

                                switch Self.resolvePayloadDelta(
                                    payload,
                                    previousSnapshot: &previousAssistantSnapshot
                                ) {
                                case .append(let delta):
                                    continuation.yield(delta)
                                case .unchanged:
                                    break
                                case .regressed(let previousSnapshot, let nextSnapshot):
                                    await service.emitNonPrefixSnapshotTelemetry(
                                        event: "chat.\(chat.state).snapshot_regressed",
                                        runId: runId,
                                        previousSnapshot: previousSnapshot,
                                        nextSnapshot: nextSnapshot
                                    )
                                case .rewritten(let previousSnapshot, let nextSnapshot):
                                    await service.emitNonPrefixSnapshotTelemetry(
                                        event: "chat.\(chat.state).snapshot_rewritten",
                                        runId: runId,
                                        previousSnapshot: previousSnapshot,
                                        nextSnapshot: nextSnapshot
                                    )
                                }

                                if sawChatFinal && hasObservedAgentLifecycleStart {
                                    scheduleLifecycleFallback()
                                }
                            }
                        }

                        if let agent = Self.decodeAgentEvent(frame), agent.runId == runId {
                            let stream = Self.normalizedString(agent.stream)?.lowercased()
                                ?? Self.decodeEventMeta(frame).stream
                            if stream == "lifecycle" {
                                let phase = (agent.data?["phase"]?.value as? String)?.lowercased()
                                    ?? Self.decodeEventMeta(frame).phase
                                    ?? ""
                                if phase == "start" {
                                    hasObservedAgentLifecycleStart = true
                                }
                            }
                            if let payload = Self.extractAgentAssistantTextPayload(agent) {
                                // Agent assistant updates are often where OpenClaw emits
                                // post-tool response text in Work mode.
                                switch Self.resolvePayloadDelta(
                                    payload,
                                    previousSnapshot: &previousAssistantSnapshot
                                ) {
                                case .append(let delta):
                                    continuation.yield(delta)
                                case .unchanged:
                                    break
                                case .regressed(let previousSnapshot, let nextSnapshot):
                                    await service.emitNonPrefixSnapshotTelemetry(
                                        event: "agent.assistant.snapshot_regressed",
                                        runId: runId,
                                        previousSnapshot: previousSnapshot,
                                        nextSnapshot: nextSnapshot
                                    )
                                case .rewritten(let previousSnapshot, let nextSnapshot):
                                    await service.emitNonPrefixSnapshotTelemetry(
                                        event: "agent.assistant.snapshot_rewritten",
                                        runId: runId,
                                        previousSnapshot: previousSnapshot,
                                        nextSnapshot: nextSnapshot
                                    )
                                }
                            }

                            if sawChatFinal && hasObservedAgentLifecycleStart {
                                scheduleLifecycleFallback()
                            }
                        }

                        if let terminal = Self.terminalState(
                            for: frame,
                            runId: runId,
                            preferAgentLifecycle: hasObservedAgentLifecycleStart
                        ) {
                            cancelLifecycleFallback()
                            switch terminal {
                            case .success:
                                scope.addEvent("openclaw.model.stream.success")
                                continuation.finish()
                            case .failure(let message):
                                let resolved = await service.resolveGatewayFailureMessage(
                                    primary: message,
                                    sessionKey: sessionKey
                                )
                                scope.setAttributes([
                                    "osaurus.openclaw.error.message": .string(resolved),
                                ])
                                scope.addEvent("openclaw.model.stream.failure")
                                continuation.finish(
                                    throwing: OpenClawModelServiceError.gatewayError(resolved)
                                )
                            }
                            return
                        }
                    }

                    scope.addEvent("openclaw.model.stream.end_of_events")
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                producerTask.cancel()
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
        let (runId, sessionKey, eventStream) = try await Terra.withAgentInvocationSpan(
            agent: .init(name: "openclaw.model.turn_stream.bootstrap", id: nil)
        ) { scope in
            let result = try await startGatewayRun(
                messages: messages,
                requestedModel: requestedModel
            )
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.run.id": .string(result.runId),
                "osaurus.openclaw.session.key": .string(result.sessionKey),
            ])
            return result
        }
        let requestedModelValue = requestedModel ?? ""
        let messageCount = messages.count

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
        defer {
            processor.endRun(turn: turn)
            OpenClawManager.shared.resumeNotificationPolling()
        }

        _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.model.turn_stream.start", id: runId)) {
            scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.run.id": .string(runId),
                "osaurus.openclaw.session.key": .string(sessionKey),
                "osaurus.openclaw.requested_model": .string(requestedModelValue),
                "osaurus.openclaw.messages.count": .int(messageCount),
            ])
        }

        for await frame in eventStream {
            if Task.isCancelled {
                throw CancellationError()
            }

            processor.processEvent(frame, turn: turn)

            if let terminal = Self.terminalState(for: frame, runId: runId) {
                switch terminal {
                case .success:
                    _ = await Terra.withAgentInvocationSpan(
                        agent: .init(name: "openclaw.model.turn_stream.success", id: runId)
                    ) { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                            Terra.Keys.Terra.openClawGateway: .bool(true),
                            Terra.Keys.GenAI.providerName: .string("openclaw"),
                            "osaurus.openclaw.run.id": .string(runId),
                            "osaurus.openclaw.session.key": .string(sessionKey),
                        ])
                    }
                    return
                case .failure(let message):
                    let resolved = await resolveGatewayFailureMessage(
                        primary: message,
                        sessionKey: sessionKey
                    )
                    _ = await Terra.withAgentInvocationSpan(
                        agent: .init(name: "openclaw.model.turn_stream.failure", id: runId)
                    ) { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                            Terra.Keys.Terra.openClawGateway: .bool(true),
                            Terra.Keys.GenAI.providerName: .string("openclaw"),
                            "osaurus.openclaw.run.id": .string(runId),
                            "osaurus.openclaw.session.key": .string(sessionKey),
                            "osaurus.openclaw.error.message": .string(resolved),
                        ])
                    }
                    throw OpenClawModelServiceError.gatewayError(resolved)
                }
            }
        }
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
            return await augmentAuthenticationFailureMessage(
                normalizedPrimary,
                sessionKey: sessionKey
            )
        }

        if let historyMessage = await historyDerivedErrorMessage(sessionKey: sessionKey) {
            return await augmentAuthenticationFailureMessage(
                historyMessage,
                sessionKey: sessionKey
            )
        }

        let fallback = normalizedPrimary ?? "unknown error"
        return await augmentAuthenticationFailureMessage(
            fallback,
            sessionKey: sessionKey
        )
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

    private static var lifecycleFinalizationGraceNanoseconds: UInt64 {
#if DEBUG
        lifecycleFinalizationGraceNanosecondsOverride ?? defaultLifecycleFinalizationGraceNanoseconds
#else
        defaultLifecycleFinalizationGraceNanoseconds
#endif
    }

    private func augmentAuthenticationFailureMessage(
        _ message: String,
        sessionKey: String
    ) async -> String {
        guard Self.isAuthenticationFailureMessage(message),
            let debugSnapshot = await authFailureDebugSnapshot(sessionKey: sessionKey)
        else {
            return message
        }
        return Self.appendAuthDebugDetails(message, snapshot: debugSnapshot)
    }

    private func authFailureDebugSnapshot(sessionKey: String) async -> AuthFailureDebugSnapshot? {
        guard !sessionKey.isEmpty else { return nil }

        var sessionModelRef: String?
        var sessionProviderId: String?
        if let sessions = try? await connection.sessionsList(
            limit: 200,
            includeTitles: false,
            includeLastMessage: false,
            includeGlobal: true,
            includeUnknown: true
        ) {
            if let session = sessions.first(where: { $0.key == sessionKey }) {
                sessionProviderId = Self.normalizedString(session.modelProvider)?.lowercased()
                sessionModelRef = Self.modelReference(
                    model: session.model,
                    providerId: sessionProviderId
                )
            }
        }

        let providerId = sessionProviderId ?? Self.providerId(fromModelReference: sessionModelRef)

        var providerAPI: String?
        var providerBaseURL: String?
        var providerHasAPIKey: Bool?
        var hasEnvKimi = false
        var hasEnvMoonshot = false
        var hasConfiguredKimiCodingProvider = false
        var hasConfiguredMoonshotProvider = false

        if let config = try? await connection.configGet() {
            if let envSection = config["env"]?.value as? [String: OpenClawProtocol.AnyCodable] {
                hasEnvKimi = envSection["KIMI_API_KEY"] != nil || envSection["KIMICODE_API_KEY"] != nil
                hasEnvMoonshot = envSection["MOONSHOT_API_KEY"] != nil
            }

            if let modelsSection = config["models"]?.value as? [String: OpenClawProtocol.AnyCodable],
                let providersSection = modelsSection["providers"]?.value as? [String: OpenClawProtocol.AnyCodable]
            {
                hasConfiguredKimiCodingProvider = providersSection["kimi-coding"] != nil
                hasConfiguredMoonshotProvider = providersSection["moonshot"] != nil

                if let providerId,
                    let providerConfig = providersSection[providerId]?.value as? [String: OpenClawProtocol.AnyCodable]
                {
                    providerAPI = Self.normalizedString(providerConfig["api"]?.value as? String)
                    providerBaseURL = Self.normalizedString(providerConfig["baseUrl"]?.value as? String)
                    let apiKeyValue = Self.normalizedString(providerConfig["apiKey"]?.value as? String)
                    providerHasAPIKey = apiKeyValue != nil
                }
            }
        }

        let hint = Self.authenticationFailureHint(
            providerId: providerId,
            modelRef: sessionModelRef,
            hasEnvKimi: hasEnvKimi,
            providerHasAPIKey: providerHasAPIKey,
            hasConfiguredKimiCodingProvider: hasConfiguredKimiCodingProvider,
            hasConfiguredMoonshotProvider: hasConfiguredMoonshotProvider
        )

        return AuthFailureDebugSnapshot(
            sessionKey: sessionKey,
            modelRef: sessionModelRef,
            providerId: providerId,
            providerAPI: providerAPI,
            providerBaseURL: providerBaseURL,
            providerHasAPIKey: providerHasAPIKey,
            hasEnvKimi: hasEnvKimi,
            hasEnvMoonshot: hasEnvMoonshot,
            hasConfiguredKimiCodingProvider: hasConfiguredKimiCodingProvider,
            hasConfiguredMoonshotProvider: hasConfiguredMoonshotProvider,
            hint: hint
        )
    }

    private static func isAuthenticationFailureMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("401")
            || normalized.contains("invalid authentication")
            || normalized.contains("authentication failed")
            || normalized.contains("unauthorized")
            || normalized.contains("invalid api key")
    }

    private static func providerId(fromModelReference modelRef: String?) -> String? {
        guard let modelRef = normalizedString(modelRef),
            let slashIndex = modelRef.firstIndex(of: "/"),
            slashIndex > modelRef.startIndex
        else {
            return nil
        }

        let prefix = modelRef[..<slashIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix.lowercased()
    }

    private static func modelReference(model: String?, providerId: String?) -> String? {
        guard let model = normalizedString(model) else { return nil }
        guard !model.contains("/") else { return model }
        guard let providerId = normalizedString(providerId)?.lowercased(), !providerId.isEmpty else {
            return model
        }
        return "\(providerId)/\(model)"
    }

    private static func authenticationFailureHint(
        providerId: String?,
        modelRef: String?,
        hasEnvKimi: Bool,
        providerHasAPIKey: Bool?,
        hasConfiguredKimiCodingProvider: Bool,
        hasConfiguredMoonshotProvider: Bool
    ) -> String? {
        let normalizedProvider = providerId?.lowercased()
        let normalizedModel = modelRef?.lowercased() ?? ""

        if normalizedProvider == nil,
            normalizedModel.contains("kimi")
        {
            if hasConfiguredKimiCodingProvider == false && hasConfiguredMoonshotProvider == false {
                return "No Kimi provider is configured for this session model. Add `kimi-coding` (`https://api.kimi.com/coding`) or `moonshot` (`https://api.moonshot.ai/v1`), then start a new OpenClaw session."
            }
            return "Session model is unqualified (`\(modelRef ?? "kimi")`). Use a provider-qualified model such as `moonshot/kimi-k2.5` or `kimi-coding/k2p5`, then start a new OpenClaw session."
        }

        if normalizedProvider == "moonshot",
            normalizedModel.contains("kimi")
        {
            return "If this key is from Kimi Code, switch to provider `kimi-coding` and model `k2p5` with base URL `https://api.kimi.com/coding` (`anthropic-messages`)."
        }

        if normalizedProvider == "kimi-coding",
            normalizedModel.contains("thinking")
        {
            return "For Kimi Coding keys, prefer model `kimi-coding/k2p5`. If you need thinking variants, use Moonshot (`moonshot/kimi-k2-thinking`) with a Moonshot key."
        }

        if normalizedProvider == "kimi-coding",
            hasEnvKimi == false,
            providerHasAPIKey != true
        {
            return "No Kimi key detected for `kimi-coding`. Configure `KIMI_API_KEY` (or set provider apiKey)."
        }

        return nil
    }

    private static func appendAuthDebugDetails(
        _ message: String,
        snapshot: AuthFailureDebugSnapshot
    ) -> String {
        var details: [String] = ["session=\(snapshot.sessionKey)"]
        if let modelRef = snapshot.modelRef {
            details.append("model=\(modelRef)")
        }
        if let providerId = snapshot.providerId {
            details.append("provider=\(providerId)")
        }
        if let providerAPI = snapshot.providerAPI {
            details.append("api=\(providerAPI)")
        }
        if let providerBaseURL = snapshot.providerBaseURL {
            details.append("baseUrl=\(providerBaseURL)")
        }
        if let providerHasAPIKey = snapshot.providerHasAPIKey {
            details.append("hasProviderApiKey=\(providerHasAPIKey)")
        }
        details.append("hasEnvKimi=\(snapshot.hasEnvKimi)")
        details.append("hasEnvMoonshot=\(snapshot.hasEnvMoonshot)")
        details.append("configuredKimiCoding=\(snapshot.hasConfiguredKimiCodingProvider)")
        details.append("configuredMoonshot=\(snapshot.hasConfiguredMoonshotProvider)")

        let joinedDetails = details.joined(separator: " ")
        if let hint = snapshot.hint, !hint.isEmpty {
            return "\(message) [auth-debug \(joinedDetails) hint=\(hint)]"
        }
        return "\(message) [auth-debug \(joinedDetails)]"
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

    private static func extractAgentAssistantTextPayload(_ payload: AgentEventPayload) -> ChatTextPayload? {
        let stream = normalizedString(payload.stream)?.lowercased()
        guard stream == "assistant" else { return nil }
        let data = payload.data ?? [:]
        // Preserve whitespace/newline tokens from agent assistant stream.
        // Trimming here collapses streamed formatting and glues words together.
        let snapshot = nonEmptyRawString(data["text"]?.value as? String)
        let delta = nonEmptyRawString(data["delta"]?.value as? String)
        guard snapshot != nil || delta != nil else { return nil }
        return ChatTextPayload(snapshot: snapshot, delta: delta)
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

    private static func resolvePayloadDelta(
        _ payload: ChatTextPayload,
        previousSnapshot: inout String
    ) -> PayloadDeltaResolution {
        if let snapshot = payload.snapshot, !snapshot.isEmpty {
            let previous = previousSnapshot
            switch normalizeSnapshotTransition(snapshot, previousSnapshot: &previousSnapshot) {
            case .append(let delta):
                return delta.isEmpty ? .unchanged : .append(delta)
            case .unchanged:
                return .unchanged
            case .regressed:
                return .regressed(previous: previous, next: snapshot)
            case .rewritten:
                return .rewritten(previous: previous, next: snapshot)
            }
        }

        guard let explicitDelta = payload.delta, !explicitDelta.isEmpty else {
            return .unchanged
        }

        if previousSnapshot.isEmpty {
            previousSnapshot = explicitDelta
            return .append(explicitDelta)
        }

        // Some OpenClaw payloads send cumulative snapshots in the `delta` field.
        // Convert those to true increments before yielding.
        if explicitDelta.hasPrefix(previousSnapshot) {
            let normalizedDelta = String(explicitDelta.dropFirst(previousSnapshot.count))
            previousSnapshot = explicitDelta
            return normalizedDelta.isEmpty ? .unchanged : .append(normalizedDelta)
        }

        // Ignore stale duplicate snapshots that would otherwise repeat rendered text.
        if previousSnapshot.hasPrefix(explicitDelta) {
            return .unchanged
        }

        previousSnapshot += explicitDelta
        return .append(explicitDelta)
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

    private static func nonEmptyRawString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func terminalState(
        for frame: EventFrame,
        runId: String,
        preferAgentLifecycle: Bool = false
    ) -> TerminalState? {
        if let chat = decodeChatEvent(frame), chat.runId == runId {
            switch chat.state {
            case "final", "aborted":
                // Work-mode runs can continue emitting `agent` stream events after
                // `chat.final`. Once agent events are observed, treat lifecycle end
                // as authoritative to avoid dropping late assistant updates.
                if !preferAgentLifecycle {
                    return .success
                }
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

#if DEBUG
    static func _testSetLifecycleFinalizationGraceNanoseconds(_ value: UInt64?) {
        lifecycleFinalizationGraceNanosecondsOverride = value
    }
#endif
}
