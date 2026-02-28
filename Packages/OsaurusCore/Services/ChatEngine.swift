//
//  ChatEngine.swift
//  osaurus
//
//  Actor encapsulating model routing and generation streaming.
//

import Foundation
import Terra
import OpenTelemetryApi

// MARMilley0956K: - ThinkingTagSplitter

/// Lightweight `<think>`/`</think>` tag splitter for trace recording.
/// Mirrors the tag-detection logic in `StreamingDeltaProcessor.parseAndRoute()`
/// but carries no UI, timer, or buffering dependencies.  Safe to use from
/// any isolation domain (nonisolated, Sendable).
struct ThinkingTagSplitter: Sendable {
    private var isInsideThinking = false
    private var pendingTagBuffer = ""

    private static let openPartials = ["<think", "<thin", "<thi", "<th", "<t", "<"]
    private static let closePartials = ["</think", "</thin", "</thi", "</th", "</t", "</"]

    /// Feed a streaming delta and receive the content/thinking split.
    /// Both tuple members may be empty on any given call.
    mutating func split(_ delta: String) -> (content: String, thinking: String) {
        guard !delta.isEmpty else { return ("", "") }

        var text = pendingTagBuffer + delta
        pendingTagBuffer = ""

        var content = ""
        var thinking = ""

        while !text.isEmpty {
            if isInsideThinking {
                if let closeRange = text.range(of: "</think>", options: .caseInsensitive) {
                    thinking += String(text[..<closeRange.lowerBound])
                    text = String(text[closeRange.upperBound...])
                    isInsideThinking = false
                } else if let partial = Self.closePartials.first(where: { text.lowercased().hasSuffix($0) }) {
                    thinking += String(text.dropLast(partial.count))
                    pendingTagBuffer = String(text.suffix(partial.count))
                    text = ""
                } else {
                    thinking += text
                    text = ""
                }
            } else {
                if let openRange = text.range(of: "<think>", options: .caseInsensitive) {
                    content += String(text[..<openRange.lowerBound])
                    text = String(text[openRange.upperBound...])
                    isInsideThinking = true
                } else if let partial = Self.openPartials.first(where: { text.lowercased().hasSuffix($0) }) {
                    content += String(text.dropLast(partial.count))
                    pendingTagBuffer = String(text.suffix(partial.count))
                    text = ""
                } else {
                    content += text
                    text = ""
                }
            }
        }

        return (content, thinking)
    }

    /// Drain any remaining buffered partial tag, attributing it to the
    /// current mode (thinking or content).
    mutating func finalize() -> (content: String, thinking: String) {
        guard !pendingTagBuffer.isEmpty else { return ("", "") }
        let remaining = pendingTagBuffer
        pendingTagBuffer = ""
        if isInsideThinking {
            return ("", remaining)
        } else {
            return (remaining, "")
        }
    }
}

actor ChatEngine: Sendable, ChatEngineProtocol {
    private let services: [ModelService]
    private let installedModelsProvider: @Sendable () -> [String]

    /// Source of the inference (for logging purposes)
    private var inferenceSource: InferenceSource = .httpAPI

    init(
        services: [ModelService] = [FoundationModelService(), MLXService()],
        installedModelsProvider: @escaping @Sendable () -> [String] = {
            MLXService.getAvailableModels()
        },
        source: InferenceSource = .httpAPI
    ) {
        self.services = services
        self.installedModelsProvider = installedModelsProvider
        self.inferenceSource = source
    }
    struct EngineError: Error {}

    private func enrichMessagesWithSystemPrompt(_ messages: [ChatMessage]) async -> [ChatMessage] {
        // Check if a system prompt is already present
        if messages.contains(where: { $0.role == "system" }) {
            return messages
        }

        // If not, fetch the global system prompt
        let systemPrompt = await MainActor.run {
            ChatConfigurationStore.load().systemPrompt
        }

        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return messages }

        // Prepend the system prompt
        let systemMessage = ChatMessage(role: "system", content: trimmed)
        return [systemMessage] + messages
    }

    /// Estimate input tokens from messages (rough heuristic: ~4 chars per token)
    private func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            sum + (msg.content?.count ?? 0)
        }
        return max(1, totalChars / 4)
    }

    private func promptSnapshot(from messages: [ChatMessage]) -> String {
        messages.compactMap(\.content).joined(separator: "\n")
    }

    private nonisolated func splitThinkingAndContent(from text: String) -> (content: String, thinking: String) {
        var splitter = ThinkingTagSplitter()
        let (content, thinking) = splitter.split(text)
        let (finalContent, finalThinking) = splitter.finalize()
        return (content + finalContent, thinking + finalThinking)
    }

    private func runtimeLabel(for service: ModelService) -> String {
        if service is OpenClawModelService {
            return "openclaw_gateway"
        }
        if service is MLXService {
            return "mlx"
        }
        if service is FoundationModelService {
            return "foundation_models"
        }
        if service is RemoteProviderService {
            return "remote_provider"
        }
        return "unknown"
    }

    private nonisolated func providerLabel(for runtime: String) -> String {
        switch runtime {
        case "openclaw_gateway":
            return "openclaw"
        case "mlx":
            return "mlx"
        case "foundation_models":
            return "apple"
        case "remote_provider":
            return "remote_provider"
        default:
            return "unknown"
        }
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let messages = await enrichMessagesWithSystemPrompt(request.messages)
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        let repPenalty: Float? = {
            // Map OpenAI penalties (presence/frequency) to a simple repetition penalty if provided
            if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
            if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
            return nil
        }()
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty,
            inferenceSource: inferenceSource,
            inferenceSpanOwner: .outerEngine
        )

        // Candidate services and installed models (injected for testability)
        let services = self.services

        // Get remote provider services
        let providerServices = await getRemoteProviderServices()
        let gatewayServices = await getGatewayServices()
        let remoteServices = providerServices + gatewayServices

        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            let innerStream: AsyncThrowingStream<String, Error>

            // If tools were provided and supported, use message-based tool streaming
            if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
                let stopSequences = request.stop ?? []
                innerStream = try await toolSvc.streamWithTools(
                    messages: messages,
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: request.tool_choice,
                    requestedModel: request.model
                )
            } else {
                innerStream = try await service.streamDeltas(
                    messages: messages,
                    parameters: params,
                    requestedModel: request.model,
                    stopSequences: request.stop ?? []
                )
            }

            // Wrap stream to count tokens and log when complete
            let source = self.inferenceSource
            let inputTokens = estimateInputTokens(messages)
            let model = effectiveModel
            let temp = temperature
            let maxTok = maxTokens
            let runtime = runtimeLabel(for: service)
            let prompt = promptSnapshot(from: messages)
            let toolCount = request.tools?.count ?? 0

            return wrapStreamWithLogging(
                innerStream,
                source: source,
                model: model,
                requestedModel: request.model,
                serviceID: service.id,
                inputTokens: inputTokens,
                temperature: temp,
                maxTokens: maxTok,
                prompt: prompt,
                runtime: runtime,
                toolCount: toolCount
            )

        case .none:
            throw EngineError()
        }
    }

    /// Wraps an async stream to count output tokens and log on completion.
    /// Runs in an inherited child task so trace/task-local context remains attached.
    /// Properly handles cancellation via onTermination handler to prevent orphaned tasks.
    private nonisolated func wrapStreamWithLogging(
        _ inner: AsyncThrowingStream<String, Error>,
        source: InferenceSource,
        model: String,
        requestedModel: String?,
        serviceID: String,
        inputTokens: Int,
        temperature: Float?,
        maxTokens: Int,
        prompt: String,
        runtime: String,
        toolCount: Int
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let provider = providerLabel(for: runtime)

        // Create the producer task and store reference for cancellation.
        let producerTask = Task(priority: .userInitiated) {
            await self.runStreamingInference(
                inner: inner,
                source: source,
                model: model,
                requestedModel: requestedModel,
                serviceID: serviceID,
                inputTokens: inputTokens,
                temperature: temperature,
                maxTokens: maxTokens,
                prompt: prompt,
                runtime: runtime,
                provider: provider,
                toolCount: toolCount,
                continuation: continuation
            )
        }

        // Set up termination handler to cancel the producer task when consumer stops consuming
        continuation.onTermination = { @Sendable termination in
            switch termination {
            case .cancelled:
                print("[Osaurus][Stream] Consumer cancelled - stopping producer task")
                producerTask.cancel()
            case .finished:
                break
            @unknown default:
                producerTask.cancel()
            }
        }

        return stream
    }

    /// Internal streaming inference method that runs within the Terra span context
    private nonisolated func runStreamingInference(
        inner: AsyncThrowingStream<String, Error>,
        source: InferenceSource,
        model: String,
        requestedModel: String?,
        serviceID: String,
        inputTokens: Int,
        temperature: Float?,
        maxTokens: Int,
        prompt: String,
        runtime: String,
        provider: String,
        toolCount: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        struct StreamFailure: Error, LocalizedError, Sendable {
            let message: String
            var errorDescription: String? { message }
        }

        struct StreamRunResult: Sendable {
            let outputTokenCount: Int
            let deltaCount: Int
            let finishReason: InferenceLog.FinishReason
            let errorMsg: String?
            let toolInvocation: ServiceToolInvocation?
            let streamError: StreamFailure?
        }

        let startTime = Date()
        let sourceLabel = String(describing: source)

        print("[Osaurus][Stream] Starting stream wrapper for model: \(model)")

        let telemetryRequest = Terra.InferenceRequest(
            model: model,
            prompt: prompt,
            promptCapture: .optIn,
            maxOutputTokens: maxTokens,
            temperature: temperature.map(Double.init),
            stream: true
        )

        let result = await Terra.withStreamingInferenceSpan(telemetryRequest) { scope -> StreamRunResult in
                var outputTokenCount = 0
                var deltaCount = 0
                var finishReason: InferenceLog.FinishReason = .stop
                var errorMsg: String? = nil
                var toolInvocation: ServiceToolInvocation?
                var outputText = ""
                var thinkingText = ""
                var splitter = ThinkingTagSplitter()
                var lastDeltaTime = startTime
                var streamError: StreamFailure?

                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string(runtime),
                    Terra.Keys.GenAI.providerName: .string(provider),
                    Terra.Keys.GenAI.responseModel: .string(model),
                    "osaurus.route.service.id": .string(serviceID),
                    "osaurus.route.requested_model": .string((requestedModel?.isEmpty == false ? requestedModel : nil) ?? "default"),
                    "osaurus.route.effective_model": .string(model),
                    "osaurus.inference.source": .string(sourceLabel),
                    "osaurus.inference.mode": .string(source.telemetryModeLabel),
                    "osaurus.inference.channel": .string(source.telemetryChannelLabel),
                    "osaurus.request.tool_count": .int(toolCount),
                    "osaurus.prompt.raw": .string(prompt),
                ])
                defer {
                    scope.setAttributes([
                        Terra.Keys.GenAI.usageInputTokens: .int(inputTokens),
                        Terra.Keys.GenAI.usageOutputTokens: .int(outputTokenCount),
                        "osaurus.stream.delta_count": .int(deltaCount),
                        "osaurus.response.raw": .string(outputText),
                        "osaurus.response.thinking": .string(thinkingText),
                        "osaurus.thinking.length": .int(thinkingText.count),
                    ])
                }

                do {
                    for try await delta in inner {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        deltaCount += 1
                        let now = Date()
                        let timeSinceStart = now.timeIntervalSince(startTime)
                        let timeSinceLastDelta = now.timeIntervalSince(lastDeltaTime)
                        lastDeltaTime = now

                        if deltaCount % 50 == 1 || timeSinceLastDelta > 2.0 {
                            print(
                                "[Osaurus][Stream] Delta #\(deltaCount): +\(String(format: "%.2f", timeSinceStart))s total, gap=\(String(format: "%.3f", timeSinceLastDelta))s, len=\(delta.count)"
                            )
                        }

                        let (contentPart, thinkingPart) = splitter.split(delta)
                        outputTokenCount += max(1, delta.count / 4)
                        outputText += contentPart
                        thinkingText += thinkingPart
                        scope.recordChunk()
                        scope.recordOutputTokenCount(outputTokenCount)
                        continuation.yield(delta)
                    }

                    // Drain any partial tag buffer left in the splitter
                    let (finalContent, finalThinking) = splitter.finalize()
                    outputText += finalContent
                    thinkingText += finalThinking

                    let totalTime = Date().timeIntervalSince(startTime)
                    print(
                        "[Osaurus][Stream] Stream completed: \(deltaCount) deltas in \(String(format: "%.2f", totalTime))s"
                    )
                } catch let inv as ServiceToolInvocation {
                    print("[Osaurus][Stream] Tool invocation: \(inv.toolName)")
                    let resolvedCallId: String
                    if let existing = inv.toolCallId, !existing.isEmpty {
                        resolvedCallId = existing
                    } else {
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        resolvedCallId = "call_" + String(raw.prefix(24))
                    }
                    toolInvocation = ServiceToolInvocation(
                        toolName: inv.toolName,
                        jsonArguments: inv.jsonArguments,
                        toolCallId: resolvedCallId,
                        geminiThoughtSignature: inv.geminiThoughtSignature
                    )
                    finishReason = .toolCalls
                    scope.addEvent(
                        "osaurus.tool.invocation",
                        attributes: [
                            Terra.Keys.GenAI.toolName: .string(inv.toolName),
                            Terra.Keys.GenAI.toolCallID: .string(resolvedCallId),
                            "osaurus.tool.arguments.raw": .string(inv.jsonArguments),
                        ]
                    )
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        print("[Osaurus][Stream] Stream cancelled after \(deltaCount) deltas")
                    } else {
                        print("[Osaurus][Stream] Stream error after \(deltaCount) deltas: \(error.localizedDescription)")
                        finishReason = .error
                        errorMsg = error.localizedDescription
                        streamError = StreamFailure(message: error.localizedDescription)
                    }
                }

                return StreamRunResult(
                    outputTokenCount: outputTokenCount,
                    deltaCount: deltaCount,
                    finishReason: finishReason,
                    errorMsg: errorMsg,
                    toolInvocation: toolInvocation,
                    streamError: streamError
                )
            }

            if let invocation = result.toolInvocation {
                continuation.finish(throwing: invocation)
            } else if let streamError = result.streamError {
                continuation.finish(throwing: streamError)
            } else {
                continuation.finish()
            }

            // Log the completed inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
            if source == .chatUI {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                var toolCalls: [ToolCallLog]? = nil
                if let invocation = result.toolInvocation {
                    toolCalls = [ToolCallLog(name: invocation.toolName, arguments: invocation.jsonArguments)]
                }

                InsightsService.logInference(
                    source: source,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: result.outputTokenCount,
                    durationMs: durationMs,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    toolCalls: toolCalls,
                    finishReason: result.finishReason,
                    errorMessage: result.errorMsg
                )
            }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let startTime = Date()
        let messages = await enrichMessagesWithSystemPrompt(request.messages)
        let inputTokens = estimateInputTokens(messages)
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        let repPenalty2: Float? = {
            if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
            if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
            return nil
        }()
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty2,
            inferenceSource: inferenceSource,
            inferenceSpanOwner: .outerEngine
        )

        let services = self.services

        // Get remote provider services
        let providerServices = await getRemoteProviderServices()
        let gatewayServices = await getGatewayServices()
        let remoteServices = providerServices + gatewayServices

        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )

        let created = Int(Date().timeIntervalSince1970)
        let responseId =
            "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"

        switch route {
        case .service(let service, let effectiveModel):
            let runtime = runtimeLabel(for: service)
            let provider = providerLabel(for: runtime)
            let source = inferenceSource
            let prompt = promptSnapshot(from: messages)
            let toolCount = request.tools?.count ?? 0
            let telemetryRequest = Terra.InferenceRequest(
                model: effectiveModel,
                prompt: prompt,
                promptCapture: .optIn,
                maxOutputTokens: maxTokens,
                temperature: temperature.map(Double.init),
                stream: false
            )
            return try await Terra.withInferenceSpan(telemetryRequest) { scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string(runtime),
                    Terra.Keys.GenAI.providerName: .string(provider),
                    Terra.Keys.GenAI.responseModel: .string(effectiveModel),
                    "osaurus.route.service.id": .string(service.id),
                    "osaurus.route.requested_model": .string(request.model.isEmpty ? "default" : request.model),
                    "osaurus.route.effective_model": .string(effectiveModel),
                    Terra.Keys.GenAI.usageInputTokens: .int(inputTokens),
                    "osaurus.inference.source": .string(String(describing: source)),
                    "osaurus.inference.mode": .string(source.telemetryModeLabel),
                    "osaurus.inference.channel": .string(source.telemetryChannelLabel),
                    "osaurus.request.tool_count": .int(toolCount),
                    "osaurus.prompt.raw": .string(prompt),
                ])

                // If tools were provided and the service supports them, use the message-based API
                if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
                    let stopSequences = request.stop ?? []
                    do {
                        let text = try await toolSvc.respondWithTools(
                            messages: messages,
                            parameters: params,
                            stopSequences: stopSequences,
                            tools: tools,
                            toolChoice: request.tool_choice,
                            requestedModel: request.model
                        )
                        let telemetryOutput = splitThinkingAndContent(from: text)
                        let outputTokens = max(1, text.count / 4)
                        scope.setAttributes([
                            Terra.Keys.GenAI.usageOutputTokens: .int(outputTokens),
                            "osaurus.response.raw": .string(telemetryOutput.content),
                            "osaurus.response.thinking": .string(telemetryOutput.thinking),
                            "osaurus.thinking.length": .int(telemetryOutput.thinking.count),
                        ])
                        let choice = ChatChoice(
                            index: 0,
                            message: ChatMessage(
                                role: "assistant",
                                content: text,
                                tool_calls: nil,
                                tool_call_id: nil
                            ),
                            finish_reason: "stop"
                        )
                        let usage = Usage(
                            prompt_tokens: inputTokens,
                            completion_tokens: outputTokens,
                            total_tokens: inputTokens + outputTokens
                        )

                        // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
                        if source == .chatUI {
                            let durationMs = Date().timeIntervalSince(startTime) * 1000
                            InsightsService.logInference(
                                source: source,
                                model: effectiveModel,
                                inputTokens: inputTokens,
                                outputTokens: outputTokens,
                                durationMs: durationMs,
                                temperature: temperature,
                                maxTokens: maxTokens,
                                finishReason: .stop
                            )
                        }

                        return ChatCompletionResponse(
                            id: responseId,
                            created: created,
                            model: effectiveModel,
                            choices: [choice],
                            usage: usage,
                            system_fingerprint: nil
                        )
                    } catch let inv as ServiceToolInvocation {
                        // Convert tool invocation to OpenAI-style non-stream response
                        let callId: String = {
                            if let preserved = inv.toolCallId, !preserved.isEmpty {
                                return preserved
                            }
                            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            return "call_" + String(raw.prefix(24))
                        }()
                        scope.addEvent(
                            "osaurus.tool.invocation",
                            attributes: [
                                Terra.Keys.GenAI.toolName: .string(inv.toolName),
                                Terra.Keys.GenAI.toolCallID: .string(callId),
                                "osaurus.tool.arguments.raw": .string(inv.jsonArguments),
                            ]
                        )
                        let toolCall = ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments),
                            geminiThoughtSignature: inv.geminiThoughtSignature
                        )
                        let assistant = ChatMessage(
                            role: "assistant",
                            content: nil,
                            tool_calls: [toolCall],
                            tool_call_id: nil
                        )
                        let choice = ChatChoice(index: 0, message: assistant, finish_reason: "tool_calls")
                        let usage = Usage(prompt_tokens: inputTokens, completion_tokens: 0, total_tokens: inputTokens)

                        // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
                        if source == .chatUI {
                            let durationMs = Date().timeIntervalSince(startTime) * 1000
                            InsightsService.logInference(
                                source: source,
                                model: effectiveModel,
                                inputTokens: inputTokens,
                                outputTokens: 0,
                                durationMs: durationMs,
                                temperature: temperature,
                                maxTokens: maxTokens,
                                toolCalls: [ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)],
                                finishReason: .toolCalls
                            )
                        }

                        return ChatCompletionResponse(
                            id: responseId,
                            created: created,
                            model: effectiveModel,
                            choices: [choice],
                            usage: usage,
                            system_fingerprint: nil
                        )
                    }
                }

                // Fallback to plain generation (no tools)
                let text = try await service.generateOneShot(
                    messages: messages,
                    parameters: params,
                    requestedModel: request.model
                )
                let telemetryOutput = splitThinkingAndContent(from: text)
                let outputTokens = max(1, text.count / 4)
                scope.setAttributes([
                    Terra.Keys.GenAI.usageOutputTokens: .int(outputTokens),
                    "osaurus.response.raw": .string(telemetryOutput.content),
                    "osaurus.response.thinking": .string(telemetryOutput.thinking),
                    "osaurus.thinking.length": .int(telemetryOutput.thinking.count),
                ])
                let choice = ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: text, tool_calls: nil, tool_call_id: nil),
                    finish_reason: "stop"
                )
                let usage = Usage(
                    prompt_tokens: inputTokens,
                    completion_tokens: outputTokens,
                    total_tokens: inputTokens + outputTokens
                )

                // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
                if source == .chatUI {
                    let durationMs = Date().timeIntervalSince(startTime) * 1000
                    InsightsService.logInference(
                        source: source,
                        model: effectiveModel,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        durationMs: durationMs,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        finishReason: .stop
                    )
                }

                return ChatCompletionResponse(
                    id: responseId,
                    created: created,
                    model: effectiveModel,
                    choices: [choice],
                    usage: usage,
                    system_fingerprint: nil
                )
            }
        case .none:
            throw EngineError()
        }
    }

    // MARK: - Remote Provider Services

    /// Fetch connected remote provider services from the manager
    private func getRemoteProviderServices() async -> [ModelService] {
        return await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }
    }

    /// Fetch OpenClaw gateway service when the gateway is connected.
    private func getGatewayServices() async -> [ModelService] {
        return await MainActor.run {
            guard OpenClawManager.shared.isConnected else { return [] }
            return [OpenClawModelService.shared]
        }
    }
}
