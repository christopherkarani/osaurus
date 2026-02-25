//
//  RemoteProviderService.swift
//  osaurus
//
//  Service for proxying requests to remote OpenAI-compatible API providers.
//

import Foundation

public enum RemoteProviderFailureClass: String, Sendable, Equatable {
    case misconfiguredEndpoint = "misconfigured-endpoint"
    case authFailed = "auth-failed"
    case gatewayUnavailable = "gateway-unavailable"
    case networkUnreachable = "network-unreachable"
    case invalidResponse = "invalid-response"
    case unknown = "unknown"
}

public struct RemoteProviderFailureDetails: Sendable {
    public let failureClass: RemoteProviderFailureClass
    public let message: String
    public let fixIt: String?
    public let statusCode: Int?
    public let contentType: String?
    public let bodyPreview: String?
    public let endpoint: String

    public init(
        failureClass: RemoteProviderFailureClass,
        message: String,
        fixIt: String?,
        statusCode: Int?,
        contentType: String?,
        bodyPreview: String?,
        endpoint: String
    ) {
        self.failureClass = failureClass
        self.message = message
        self.fixIt = fixIt
        self.statusCode = statusCode
        self.contentType = contentType
        self.bodyPreview = bodyPreview
        self.endpoint = endpoint
    }
}

/// Errors specific to remote provider operations
public enum RemoteProviderServiceError: LocalizedError {
    case invalidURL
    case notConnected
    case requestFailed(String)
    case discoveryFailed(RemoteProviderFailureDetails)
    case invalidResponse
    case streamingError(String)
    case noModelsAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid provider URL configuration"
        case .notConnected:
            return "Provider is not connected"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .discoveryFailed(let details):
            return details.message
        case .invalidResponse:
            return "Invalid response from provider"
        case .streamingError(let message):
            return "Streaming error: \(message)"
        case .noModelsAvailable:
            return "No models available from provider"
        }
    }
}

/// Service that proxies requests to a remote OpenAI-compatible API provider
public actor RemoteProviderService: ToolCapableService {

    public let provider: RemoteProvider
    private let providerPrefix: String
    private var availableModels: [String]
    private var session: URLSession

    public nonisolated var id: String {
        "remote-\(provider.id.uuidString)"
    }

    public init(provider: RemoteProvider, models: [String]) {
        self.provider = provider
        self.availableModels = models
        // Create a unique prefix for model names (lowercase, sanitized)
        self.providerPrefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        // Configure URLSession with provider timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = provider.timeout
        config.timeoutIntervalForResource = provider.timeout * 2
        self.session = URLSession(configuration: config)
    }

    /// Inactivity timeout for streaming: if no bytes arrive within this interval,
    /// assume the provider has stalled and end the stream.
    /// Uses the provider's configured timeout so slow models (e.g. image generation) don't get killed.
    private var streamInactivityTimeout: TimeInterval { provider.timeout }

    /// Invalidate the URLSession to release its strong delegate reference.
    /// Must be called before discarding this service instance to avoid leaking.
    public func invalidateSession() {
        session.invalidateAndCancel()
    }

    /// Update available models (called when connection refreshes)
    public func updateModels(_ models: [String]) {
        self.availableModels = models
    }

    /// Get the prefixed model names for this provider
    public func getPrefixedModels() -> [String] {
        availableModels.map { "\(providerPrefix)/\($0)" }
    }

    /// Get the raw model names without prefix
    public func getRawModels() -> [String] {
        availableModels
    }

    // MARK: - ModelService Protocol

    public nonisolated func isAvailable() -> Bool {
        return provider.enabled
    }

    public nonisolated func handles(requestedModel: String?) -> Bool {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return false
        }

        // Check if model starts with our provider prefix
        let prefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        return model.lowercased().hasPrefix(prefix + "/")
    }

    /// Extract the actual model name without provider prefix
    private func extractModelName(_ requestedModel: String?) -> String? {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return nil
        }

        // Remove provider prefix if present
        if model.lowercased().hasPrefix(providerPrefix + "/") {
            let startIndex = model.index(model.startIndex, offsetBy: providerPrefix.count + 1)
            return String(model[startIndex...])
        }

        return model
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        let request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: nil,
            toolChoice: nil
        )

        let (data, response) = try await session.data(for: try buildURLRequest(for: request))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let (content, _) = try parseResponse(data)
        return content ?? ""
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        // Add stop sequences if provided
        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = self.provider.providerType

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let producerTask = Task {
            do {
                let (bytes, response) = try await currentSession.bytes(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                // Track accumulated tool calls by index (even in streamDeltas for robustness)
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)] =
                    [:]

                // Parse SSE stream with UTF-8 decoding and inactivity timeout
                var buffer = ""
                var utf8Buffer = Data()
                let maxUtf8BufferSize = 1024
                let byteRef = ByteIteratorRef(bytes.makeAsyncIterator())

                while true {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard
                        let byte = try await Self.nextByte(
                            from: byteRef,
                            timeout: streamInactivityTimeout
                        )
                    else {
                        break
                    }

                    utf8Buffer.append(byte)
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    } else if utf8Buffer.count > maxUtf8BufferSize {
                        buffer.append(String(decoding: utf8Buffer, as: UTF8.self))
                        utf8Buffer.removeAll()
                    }

                    // Process complete lines
                    while let newlineIndex = buffer.firstIndex(where: { $0.isNewline }) {
                        let line = String(buffer[..<newlineIndex])
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])

                        // Skip empty lines
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }

                        // Parse SSE data line
                        if line.hasPrefix("data: ") {
                            let dataContent = String(line.dropFirst(6))

                            // Check for stream end (OpenAI format)
                            if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                    continuation.finish(throwing: invocation)
                                    return
                                }
                                continuation.finish()
                                return
                            }

                            // Parse JSON chunk based on provider type
                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .gemini {
                                        // Parse Gemini SSE event (each chunk is a GeminiGenerateContentResponse)
                                        let chunk = try JSONDecoder().decode(
                                            GeminiGenerateContentResponse.self,
                                            from: jsonData
                                        )

                                        if let parts = chunk.candidates?.first?.content?.parts {
                                            for part in parts {
                                                switch part {
                                                case .text(let text):
                                                    if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                        var output = text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    }
                                                case .functionCall(let funcCall):
                                                    let idx = accumulatedToolCalls.count
                                                    let argsData = try? JSONSerialization.data(
                                                        withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                    )
                                                    let argsString =
                                                        argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                    accumulatedToolCalls[idx] = (
                                                        id: "gemini-\(UUID().uuidString.prefix(8))",
                                                        name: funcCall.name,
                                                        args: argsString,
                                                        thoughtSignature: funcCall.thoughtSignature
                                                    )
                                                case .inlineData(let imageData):
                                                    if accumulatedToolCalls.isEmpty {
                                                        let markdown =
                                                            "![image](data:\(imageData.mimeType);base64,\(imageData.data))"
                                                        continuation.yield(markdown)
                                                    }
                                                case .functionResponse:
                                                    break
                                                }
                                            }
                                        }

                                        // Check for finish reason
                                        if let finishReason = chunk.candidates?.first?.finishReason {
                                            if finishReason == "SAFETY" {
                                                continuation.finish(
                                                    throwing: RemoteProviderServiceError.requestFailed(
                                                        "Content blocked by safety settings."
                                                    )
                                                )
                                                return
                                            }

                                            if finishReason == "STOP" || finishReason == "MAX_TOKENS" {
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            }
                                        }
                                    } else if providerType == .anthropic {
                                        // Parse Anthropic SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            AnthropicSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "content_block_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    ContentBlockDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .textDelta(let textDelta) = deltaEvent.delta {
                                                        var output = textDelta.text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    } else if case .inputJsonDelta(let jsonDelta) = deltaEvent.delta {
                                                        // Accumulate tool call JSON
                                                        let idx = deltaEvent.index
                                                        var current =
                                                            accumulatedToolCalls[idx] ?? (
                                                                id: nil, name: nil, args: "", thoughtSignature: nil
                                                            )
                                                        current.args += jsonDelta.partial_json
                                                        accumulatedToolCalls[idx] = current
                                                    }
                                                }
                                            case "content_block_start":
                                                if let startEvent = try? JSONDecoder().decode(
                                                    ContentBlockStartEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .toolUse(let toolBlock) = startEvent.content_block {
                                                        let idx = startEvent.index
                                                        accumulatedToolCalls[idx] = (
                                                            id: toolBlock.id, name: toolBlock.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    }
                                                }
                                            case "message_stop":
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else if providerType == .openResponses {
                                        // Parse Open Responses SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            OpenResponsesSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "response.output_text.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    OutputTextDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    var output = deltaEvent.delta
                                                    for seq in stopSequences {
                                                        if let range = output.range(of: seq) {
                                                            output = String(output[..<range.lowerBound])
                                                            continuation.yield(output)
                                                            continuation.finish()
                                                            return
                                                        }
                                                    }
                                                    continuation.yield(output)
                                                }
                                            case "response.output_item.added":
                                                if let addedEvent = try? JSONDecoder().decode(
                                                    OutputItemAddedEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .functionCall(let funcCall) = addedEvent.item {
                                                        let idx = addedEvent.output_index
                                                        accumulatedToolCalls[idx] = (
                                                            id: funcCall.call_id, name: funcCall.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    }
                                                }
                                            case "response.function_call_arguments.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    FunctionCallArgumentsDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    let idx = deltaEvent.output_index
                                                    var current =
                                                        accumulatedToolCalls[idx] ?? (
                                                            id: deltaEvent.call_id, name: nil, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    current.args += deltaEvent.delta
                                                    accumulatedToolCalls[idx] = current
                                                }
                                            case "response.completed":
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else {
                                        // OpenAI format
                                        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)

                                        // Accumulate tool calls by index FIRST (before yielding content)
                                        // This ensures we detect tool calls before deciding to yield content
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (
                                                        id: nil, name: nil, args: "", thoughtSignature: nil
                                                    )

                                                if let id = toolCall.id {
                                                    current.id = id
                                                }
                                                if let name = toolCall.function?.name {
                                                    current.name = name
                                                }
                                                if let args = toolCall.function?.arguments {
                                                    current.args += args
                                                }
                                                accumulatedToolCalls[idx] = current
                                            }
                                        }

                                        // Only yield content if no tool calls have been detected
                                        // This prevents function-call JSON from leaking into the chat UI
                                        if accumulatedToolCalls.isEmpty,
                                            let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                                        {
                                            // Check stop sequences
                                            var output = delta
                                            for seq in stopSequences {
                                                if let range = output.range(of: seq) {
                                                    output = String(output[..<range.lowerBound])
                                                    continuation.yield(output)
                                                    continuation.finish()
                                                    return
                                                }
                                            }
                                            continuation.yield(output)
                                        }

                                        // Emit tool calls on finish reason
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty,
                                            let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                        {
                                            continuation.finish(throwing: invocation)
                                            return
                                        }
                                    }
                                } catch {
                                    // Log parsing errors for debugging
                                    print(
                                        "[Osaurus] Warning: Failed to parse SSE chunk in streamDeltas: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    }
                }

                // Handle leftover buffer content (e.g. if the stream ended without a newline)
                if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
                    let line = buffer
                    if line.hasPrefix("data: ") {
                        let dataContent = String(line.dropFirst(6))

                        if let jsonData = dataContent.data(using: .utf8) {
                            do {
                                if providerType == .gemini {
                                    let chunk = try JSONDecoder().decode(
                                        GeminiGenerateContentResponse.self,
                                        from: jsonData
                                    )

                                    if let parts = chunk.candidates?.first?.content?.parts {
                                        for part in parts {
                                            switch part {
                                            case .text(let text):
                                                if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                    var output = text
                                                    for seq in stopSequences {
                                                        if let range = output.range(of: seq) {
                                                            output = String(output[..<range.lowerBound])
                                                            continuation.yield(output)
                                                            continuation.finish()
                                                            return
                                                        }
                                                    }
                                                    continuation.yield(output)
                                                }
                                            case .functionCall(let funcCall):
                                                let idx = accumulatedToolCalls.count
                                                let argsData = try? JSONSerialization.data(
                                                    withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                )
                                                let argsString =
                                                    argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                accumulatedToolCalls[idx] = (
                                                    id: "gemini-\(UUID().uuidString.prefix(8))",
                                                    name: funcCall.name,
                                                    args: argsString,
                                                    thoughtSignature: funcCall.thoughtSignature
                                                )
                                            case .inlineData(let imageData):
                                                if accumulatedToolCalls.isEmpty {
                                                    let markdown =
                                                        "![image](data:\(imageData.mimeType);base64,\(imageData.data))"
                                                    continuation.yield(markdown)
                                                }
                                            case .functionResponse:
                                                break
                                            }
                                        }
                                    }
                                }
                            } catch {
                                // Leftover buffer parse failures are non-fatal
                            }
                        }
                    }
                }

                // Emit any accumulated tool calls at stream end
                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                    continuation.finish(throwing: invocation)
                    return
                }

                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - ToolCapableService Protocol

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let (data, response) = try await session.data(for: try buildURLRequest(for: request))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let (content, toolCalls) = try parseResponse(data)

        // Check for tool calls
        if let toolCalls = toolCalls, let firstCall = toolCalls.first {
            throw ServiceToolInvocation(
                toolName: firstCall.function.name,
                jsonArguments: firstCall.function.arguments,
                toolCallId: firstCall.id,
                geminiThoughtSignature: firstCall.geminiThoughtSignature
            )
        }

        return content ?? ""
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: true,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = self.provider.providerType

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let producerTask = Task {
            do {
                let (bytes, response) = try await currentSession.bytes(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                // Track accumulated tool calls by index (supports multiple parallel tool calls)
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)] =
                    [:]

                // Track if we've seen any finish reason (for edge case handling)
                var lastFinishReason: String?

                // Accumulate yielded text content for fallback tool call detection.
                // Some models (e.g., Llama) embed tool calls inline in text instead
                // of using the structured tool_calls field.
                var accumulatedContent = ""

                // Parse SSE stream with UTF-8 decoding and inactivity timeout
                var buffer = ""
                var utf8Buffer = Data()
                let maxUtf8BufferSize = 1024
                let byteRef = ByteIteratorRef(bytes.makeAsyncIterator())

                while true {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard
                        let byte = try await Self.nextByte(
                            from: byteRef,
                            timeout: streamInactivityTimeout
                        )
                    else {
                        break
                    }

                    utf8Buffer.append(byte)
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    } else if utf8Buffer.count > maxUtf8BufferSize {
                        buffer.append(String(decoding: utf8Buffer, as: UTF8.self))
                        utf8Buffer.removeAll()
                    }

                    // Process complete lines
                    while let newlineIndex = buffer.firstIndex(where: { $0.isNewline }) {
                        let line = String(buffer[..<newlineIndex])
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])

                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let dataContent = String(line.dropFirst(6))

                            if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                    print("[Osaurus] Stream [DONE]: Emitting tool call '\(invocation.toolName)'")
                                    continuation.finish(throwing: invocation)
                                    return
                                }

                                // Fallback: detect inline tool calls in text content
                                if !accumulatedContent.isEmpty, !tools.isEmpty,
                                    let (name, args) = ToolDetection.detectInlineToolCall(
                                        in: accumulatedContent,
                                        tools: tools
                                    )
                                {
                                    print("[Osaurus] Fallback: Detected inline tool call '\(name)' in text")
                                    continuation.finish(
                                        throwing: ServiceToolInvocation(
                                            toolName: name,
                                            jsonArguments: args,
                                            toolCallId: nil
                                        )
                                    )
                                    return
                                }

                                continuation.finish()
                                return
                            }

                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .gemini {
                                        // Parse Gemini SSE event (each chunk is a GeminiGenerateContentResponse)
                                        let chunk = try JSONDecoder().decode(
                                            GeminiGenerateContentResponse.self,
                                            from: jsonData
                                        )

                                        if let parts = chunk.candidates?.first?.content?.parts {
                                            for part in parts {
                                                switch part {
                                                case .text(let text):
                                                    if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                        var output = text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                accumulatedContent += output
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        accumulatedContent += output
                                                        continuation.yield(output)
                                                    }
                                                case .functionCall(let funcCall):
                                                    let idx = accumulatedToolCalls.count
                                                    let argsData = try? JSONSerialization.data(
                                                        withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                    )
                                                    let argsString =
                                                        argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                    accumulatedToolCalls[idx] = (
                                                        id: "gemini-\(UUID().uuidString.prefix(8))",
                                                        name: funcCall.name,
                                                        args: argsString,
                                                        thoughtSignature: funcCall.thoughtSignature
                                                    )
                                                    print(
                                                        "[Osaurus] Gemini tool call detected: index=\(idx), name=\(funcCall.name)"
                                                    )
                                                case .inlineData(let imageData):
                                                    if accumulatedToolCalls.isEmpty {
                                                        let markdown =
                                                            "![image](data:\(imageData.mimeType);base64,\(imageData.data))"
                                                        continuation.yield(markdown)
                                                    }
                                                case .functionResponse:
                                                    break
                                                }
                                            }
                                        }

                                        // Check for finish reason
                                        if let finishReason = chunk.candidates?.first?.finishReason {
                                            lastFinishReason = finishReason

                                            if finishReason == "SAFETY" {
                                                continuation.finish(
                                                    throwing: RemoteProviderServiceError.requestFailed(
                                                        "Content blocked by safety settings."
                                                    )
                                                )
                                                return
                                            }

                                            if finishReason == "STOP" || finishReason == "MAX_TOKENS" {
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Gemini stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            }
                                        }
                                    } else if providerType == .anthropic {
                                        // Parse Anthropic SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            AnthropicSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "content_block_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    ContentBlockDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .textDelta(let textDelta) = deltaEvent.delta {
                                                        var output = textDelta.text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    } else if case .inputJsonDelta(let jsonDelta) = deltaEvent.delta {
                                                        // Accumulate tool call JSON
                                                        let idx = deltaEvent.index
                                                        var current =
                                                            accumulatedToolCalls[idx] ?? (
                                                                id: nil, name: nil, args: "", thoughtSignature: nil
                                                            )
                                                        current.args += jsonDelta.partial_json
                                                        accumulatedToolCalls[idx] = current
                                                    }
                                                }
                                            case "content_block_start":
                                                if let startEvent = try? JSONDecoder().decode(
                                                    ContentBlockStartEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .toolUse(let toolBlock) = startEvent.content_block {
                                                        let idx = startEvent.index
                                                        accumulatedToolCalls[idx] = (
                                                            id: toolBlock.id, name: toolBlock.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                        print(
                                                            "[Osaurus] Tool call detected: index=\(idx), name=\(toolBlock.name)"
                                                        )
                                                    }
                                                }
                                            case "message_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    MessageDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if let stopReason = deltaEvent.delta.stop_reason {
                                                        lastFinishReason = stopReason
                                                    }
                                                }
                                            case "message_stop":
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Anthropic stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else if providerType == .openResponses {
                                        // Parse Open Responses SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            OpenResponsesSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "response.output_text.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    OutputTextDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    var output = deltaEvent.delta
                                                    for seq in stopSequences {
                                                        if let range = output.range(of: seq) {
                                                            output = String(output[..<range.lowerBound])
                                                            continuation.yield(output)
                                                            continuation.finish()
                                                            return
                                                        }
                                                    }
                                                    continuation.yield(output)
                                                }
                                            case "response.output_item.added":
                                                if let addedEvent = try? JSONDecoder().decode(
                                                    OutputItemAddedEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .functionCall(let funcCall) = addedEvent.item {
                                                        let idx = addedEvent.output_index
                                                        accumulatedToolCalls[idx] = (
                                                            id: funcCall.call_id, name: funcCall.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                        print(
                                                            "[Osaurus] Open Responses tool call detected: index=\(idx), name=\(funcCall.name)"
                                                        )
                                                    }
                                                }
                                            case "response.function_call_arguments.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    FunctionCallArgumentsDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    let idx = deltaEvent.output_index
                                                    var current =
                                                        accumulatedToolCalls[idx] ?? (
                                                            id: deltaEvent.call_id, name: nil, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    current.args += deltaEvent.delta
                                                    accumulatedToolCalls[idx] = current
                                                }
                                            case "response.completed":
                                                lastFinishReason = "completed"
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Open Responses stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else {
                                        // OpenAI format
                                        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)

                                        // Handle tool call deltas FIRST - track by index for multiple parallel tool calls
                                        // This ensures we detect tool calls before deciding to yield content
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (
                                                        id: nil, name: nil, args: "", thoughtSignature: nil
                                                    )

                                                // Preserve tool call ID from the stream
                                                if let id = toolCall.id {
                                                    current.id = id
                                                }
                                                if let name = toolCall.function?.name {
                                                    current.name = name
                                                    print("[Osaurus] Tool call detected: index=\(idx), name=\(name)")
                                                }
                                                if let args = toolCall.function?.arguments {
                                                    current.args += args
                                                }
                                                accumulatedToolCalls[idx] = current
                                            }
                                        }

                                        // Only yield content if no tool calls have been detected
                                        // This prevents function-call JSON from leaking into the chat UI
                                        if accumulatedToolCalls.isEmpty,
                                            let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                                        {
                                            var output = delta
                                            for seq in stopSequences {
                                                if let range = output.range(of: seq) {
                                                    output = String(output[..<range.lowerBound])
                                                    accumulatedContent += output
                                                    continuation.yield(output)
                                                    continuation.finish()
                                                    return
                                                }
                                            }
                                            accumulatedContent += output
                                            continuation.yield(output)
                                        }

                                        // Check finish reason — emit tool calls if available
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty
                                        {
                                            lastFinishReason = finishReason
                                            if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                                print(
                                                    "[Osaurus] Emitting tool call '\(invocation.toolName)' on finish_reason '\(finishReason)'"
                                                )
                                                continuation.finish(throwing: invocation)
                                                return
                                            }
                                        }
                                    }
                                } catch {
                                    // Log parsing errors for debugging instead of silently ignoring
                                    print(
                                        "[Osaurus] Warning: Failed to parse SSE chunk: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    }
                }

                // Emit any accumulated tool call data at stream end
                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                    print(
                        "[Osaurus] Stream ended: Emitting tool call '\(invocation.toolName)' (finish_reason: \(lastFinishReason ?? "none"))"
                    )
                    continuation.finish(throwing: invocation)
                    return
                }

                // Fallback: detect inline tool calls in text content (e.g., Llama)
                if !accumulatedContent.isEmpty, !tools.isEmpty,
                    let (name, args) = ToolDetection.detectInlineToolCall(
                        in: accumulatedContent,
                        tools: tools
                    )
                {
                    print("[Osaurus] Fallback: Detected inline tool call '\(name)' in text")
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: name,
                            jsonArguments: args,
                            toolCallId: nil
                        )
                    )
                    return
                }

                continuation.finish()
            } catch {
                // Handle cancellation gracefully
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    print("[Osaurus] Stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Private Helpers

    /// Actor wrapper around a byte iterator so it can be safely used inside escaping
    /// `addTask` closures (which cannot capture `inout` parameters directly).
    private final class ByteIteratorRef: @unchecked Sendable {
        private var iterator: URLSession.AsyncBytes.AsyncIterator
        private let lock = NSLock()
        init(_ iterator: URLSession.AsyncBytes.AsyncIterator) { self.iterator = iterator }
        func next() async throws -> UInt8? {
            // Only one task ever calls next() at a time (the other is just sleeping),
            // so the lock is uncontended but satisfies Sendable requirements.
            try await iterator.next()
        }
    }

    /// Reads the next byte from a `ByteIteratorRef`, racing against an inactivity timeout.
    /// Returns `nil` if the stream ended naturally or the timeout fired.
    private static func nextByte(
        from ref: ByteIteratorRef,
        timeout: TimeInterval
    ) async throws -> UInt8? {
        try await withThrowingTaskGroup(of: UInt8?.self) { group in
            group.addTask { try await ref.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Creates a `ServiceToolInvocation` from the first accumulated tool call entry,
    /// validating the JSON arguments. Returns `nil` if there are no accumulated calls
    /// or the first entry has no name.
    private static func makeToolInvocation(
        from accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)]
    ) -> ServiceToolInvocation? {
        guard let first = accumulated.sorted(by: { $0.key < $1.key }).first,
            let name = first.value.name
        else { return nil }

        return ServiceToolInvocation(
            toolName: name,
            jsonArguments: validateToolCallJSON(first.value.args),
            toolCallId: first.value.id,
            geminiThoughtSignature: first.value.thoughtSignature
        )
    }

    /// Validates that tool call arguments JSON is well-formed.
    /// If the JSON is incomplete (e.g., stream was cut off mid-argument), attempts to repair it.
    /// Returns the original string if valid, or a best-effort repair.
    private static func validateToolCallJSON(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }

        // Quick validation: try to parse as-is
        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return trimmed
        }

        // Attempt repair: close unclosed braces/brackets
        var repaired = trimmed
        var braceCount = 0
        var bracketCount = 0
        var inString = false
        var isEscaped = false
        for ch in repaired {
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    braceCount += 1
                } else if ch == "}" {
                    braceCount -= 1
                } else if ch == "[" {
                    bracketCount += 1
                } else if ch == "]" {
                    bracketCount -= 1
                }
            }
        }

        // Close any unclosed strings
        if inString {
            repaired += "\""
        }

        // Remove trailing comma before closing
        let trimmedForComma = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedForComma.hasSuffix(",") {
            repaired = String(trimmedForComma.dropLast())
        }

        // Close unclosed brackets and braces
        for _ in 0 ..< bracketCount {
            repaired += "]"
        }
        for _ in 0 ..< braceCount {
            repaired += "}"
        }

        // Verify the repair worked
        if let data = repaired.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            print("[Osaurus] Repaired incomplete tool call JSON (\(json.count) -> \(repaired.count) chars)")
            return repaired
        }

        // Repair failed - return original and let downstream handle the error
        print("[Osaurus] Warning: Tool call JSON is malformed and could not be repaired: \(json.prefix(200))")
        return json
    }

    /// Build a chat completion request structure
    private func buildChatRequest(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        model: String,
        stream: Bool,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> RemoteChatRequest {
        return RemoteChatRequest(
            model: model,
            messages: messages,
            temperature: parameters.temperature,
            max_completion_tokens: parameters.maxTokens,
            stream: stream,
            top_p: parameters.topPOverride,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: tools,
            tool_choice: toolChoice
        )
    }

    /// Build a URLRequest for the chat completions endpoint
    private func buildURLRequest(for request: RemoteChatRequest) throws -> URLRequest {
        let url: URL

        if provider.providerType == .gemini {
            // Gemini uses model-in-URL pattern: /models/{model}:generateContent or :streamGenerateContent
            let action = request.stream ? "streamGenerateContent" : "generateContent"
            let endpoint = "/models/\(request.model):\(action)"
            guard let geminiURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            if request.stream {
                // Append ?alt=sse for SSE-formatted streaming
                guard var components = URLComponents(url: geminiURL, resolvingAgainstBaseURL: false) else {
                    throw RemoteProviderServiceError.invalidURL
                }
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
                guard let sseURL = components.url else {
                    throw RemoteProviderServiceError.invalidURL
                }
                url = sseURL
            } else {
                url = geminiURL
            }
        } else {
            let endpoint = provider.providerType.chatEndpoint
            guard let standardURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            url = standardURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set Accept header based on streaming mode
        if request.stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        // Add provider headers (including auth)
        for (key, value) in provider.resolvedHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Encode request body based on provider type
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let bodyData: Data
        switch provider.providerType {
        case .anthropic:
            let anthropicRequest = request.toAnthropicRequest()
            bodyData = try encoder.encode(anthropicRequest)
        case .openai:
            bodyData = try encoder.encode(request)
        case .openResponses:
            let openResponsesRequest = request.toOpenResponsesRequest()
            bodyData = try encoder.encode(openResponsesRequest)
        case .gemini:
            let geminiRequest = request.toGeminiRequest()
            bodyData = try encoder.encode(geminiRequest)
        }
        urlRequest.httpBody = bodyData
        return urlRequest
    }

    /// Parse response based on provider type
    private func parseResponse(_ data: Data) throws -> (content: String?, toolCalls: [ToolCall]?) {
        switch provider.providerType {
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for block in response.content {
                switch block {
                case .text(_, let text):
                    textContent += text
                case .toolUse(_, let id, let name, let input):
                    let argsData = try? JSONSerialization.data(withJSONObject: input.mapValues { $0.value })
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(
                        ToolCall(
                            id: id,
                            type: "function",
                            function: ToolCallFunction(name: name, arguments: argsString)
                        )
                    )
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .openai:
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = response.choices.first?.message.content
            let toolCalls = response.choices.first?.message.tool_calls
            return (content, toolCalls)

        case .openResponses:
            let response = try JSONDecoder().decode(OpenResponsesResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for item in response.output {
                switch item {
                case .message(let message):
                    for content in message.content {
                        if case .outputText(let text) = content {
                            textContent += text.text
                        }
                    }
                case .functionCall(let funcCall):
                    toolCalls.append(
                        ToolCall(
                            id: funcCall.call_id,
                            type: "function",
                            function: ToolCallFunction(name: funcCall.name, arguments: funcCall.arguments)
                        )
                    )
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .gemini:
            let response = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            if let parts = response.candidates?.first?.content?.parts {
                for part in parts {
                    switch part {
                    case .text(let text):
                        textContent += text
                    case .functionCall(let funcCall):
                        let argsData = try? JSONSerialization.data(
                            withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                        )
                        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.append(
                            ToolCall(
                                id: "gemini-\(UUID().uuidString.prefix(8))",
                                type: "function",
                                function: ToolCallFunction(name: funcCall.name, arguments: argsString),
                                geminiThoughtSignature: funcCall.thoughtSignature
                            )
                        )
                    case .inlineData(let imageData):
                        let markdown =
                            "![image](data:\(imageData.mimeType);base64,\(imageData.data))"
                        textContent += markdown
                    case .functionResponse:
                        break  // Not expected in responses from model
                    }
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)
        }
    }
}

// MARK: - Helper for Anthropic SSE Event Type Detection

/// Simple struct to decode Anthropic SSE event type
private struct AnthropicSSEEvent: Decodable {
    let type: String
}

// MARK: - Helper for Open Responses SSE Event Type Detection

/// Simple struct to decode Open Responses SSE event type
private struct OpenResponsesSSEEvent: Decodable {
    let type: String
}

// MARK: - Request/Response Models for Remote Provider

/// Chat request structure for remote providers (matches OpenAI format)
private struct RemoteChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Float?
    let max_completion_tokens: Int?  // OpenAI's newer parameter name
    let stream: Bool
    let top_p: Float?
    let frequency_penalty: Float?
    let presence_penalty: Float?
    var stop: [String]?
    let tools: [Tool]?
    let tool_choice: ToolChoiceOption?

    /// Convert to Anthropic Messages API request format
    func toAnthropicRequest() -> AnthropicMessagesRequest {
        var systemContent: AnthropicSystemContent? = nil
        var anthropicMessages: [AnthropicMessage] = []

        // Collect consecutive tool_result blocks to batch them into a single user message
        // Anthropic requires all tool_results for a tool_use to be in the immediately following user message
        var pendingToolResults: [AnthropicContentBlock] = []

        // Helper to flush pending tool results into a single user message
        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                anthropicMessages.append(
                    AnthropicMessage(
                        role: "user",
                        content: .blocks(pendingToolResults)
                    )
                )
                pendingToolResults = []
            }
        }

        for msg in messages {
            switch msg.role {
            case "system":
                // Flush any pending tool results before system message
                flushToolResults()
                // Collect system messages
                if let content = msg.content {
                    systemContent = .text(content)
                }

            case "user":
                // Flush any pending tool results before user message
                flushToolResults()
                // Convert user messages
                if let content = msg.content {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "user",
                            content: .text(content)
                        )
                    )
                }

            case "assistant":
                // Flush any pending tool results before assistant message
                flushToolResults()
                // Convert assistant messages, including tool calls
                var blocks: [AnthropicContentBlock] = []

                if let content = msg.content, !content.isEmpty {
                    blocks.append(.text(AnthropicTextBlock(text: content)))
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var input: [String: AnyCodableValue] = [:]

                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            input = argsDict.mapValues { AnyCodableValue($0) }
                        }

                        blocks.append(
                            .toolUse(
                                AnthropicToolUseBlock(
                                    id: toolCall.id,
                                    name: toolCall.function.name,
                                    input: input
                                )
                            )
                        )
                    }
                }

                if !blocks.isEmpty {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "assistant",
                            content: .blocks(blocks)
                        )
                    )
                }

            case "tool":
                // Collect tool results - they will be batched into a single user message
                // when we encounter a non-tool message or reach the end
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    pendingToolResults.append(
                        .toolResult(
                            AnthropicToolResultBlock(
                                type: "tool_result",
                                tool_use_id: toolCallId,
                                content: .text(content),
                                is_error: nil
                            )
                        )
                    )
                }

            default:
                // Flush any pending tool results before unknown message type
                flushToolResults()
                break
            }
        }

        // Flush any remaining tool results at the end
        flushToolResults()

        // Convert tools
        var anthropicTools: [AnthropicTool]? = nil
        if let tools = tools {
            anthropicTools = tools.map { tool in
                AnthropicTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    input_schema: tool.function.parameters
                )
            }
        }

        // Convert tool choice
        var anthropicToolChoice: AnthropicToolChoice? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                anthropicToolChoice = .auto
            case .none:
                anthropicToolChoice = AnthropicToolChoice.none
            case .function(let fn):
                anthropicToolChoice = .tool(name: fn.function.name)
            }
        }

        return AnthropicMessagesRequest(
            model: model,
            max_tokens: max_completion_tokens ?? 4096,
            system: systemContent,
            messages: anthropicMessages,
            stream: stream,
            temperature: temperature.map { Double($0) },
            top_p: top_p.map { Double($0) },
            top_k: nil,
            stop_sequences: stop,
            tools: anthropicTools,
            tool_choice: anthropicToolChoice,
            metadata: nil
        )
    }

    /// Convert to Gemini GenerateContent API request format
    func toGeminiRequest() -> GeminiGenerateContentRequest {
        var geminiContents: [GeminiContent] = []
        var systemInstruction: GeminiContent? = nil

        // Collect consecutive function responses to batch them
        var pendingFunctionResponses: [GeminiPart] = []

        // Helper to flush pending function responses into a user content
        func flushFunctionResponses() {
            if !pendingFunctionResponses.isEmpty {
                geminiContents.append(GeminiContent(role: "user", parts: pendingFunctionResponses))
                pendingFunctionResponses = []
            }
        }

        for msg in messages {
            switch msg.role {
            case "system":
                // System messages become systemInstruction
                if let content = msg.content {
                    systemInstruction = GeminiContent(parts: [.text(content)])
                }

            case "user":
                flushFunctionResponses()
                var userParts: [GeminiPart] = []

                // Add text content
                if let content = msg.content, !content.isEmpty {
                    userParts.append(.text(content))
                }

                // Add image content from contentParts
                if let parts = msg.contentParts {
                    for part in parts {
                        if case .imageUrl(let url, _) = part {
                            // Parse data URLs: "data:<mimeType>;base64,<data>"
                            if url.hasPrefix("data:"),
                                let semicolonIdx = url.firstIndex(of: ";"),
                                let commaIdx = url.firstIndex(of: ",")
                            {
                                let mimeType = String(url[url.index(url.startIndex, offsetBy: 5) ..< semicolonIdx])
                                let base64Data = String(url[url.index(after: commaIdx)...])
                                userParts.append(
                                    .inlineData(GeminiInlineData(mimeType: mimeType, data: base64Data))
                                )
                            }
                        }
                    }
                }

                if !userParts.isEmpty {
                    geminiContents.append(GeminiContent(role: "user", parts: userParts))
                }

            case "assistant":
                flushFunctionResponses()
                var parts: [GeminiPart] = []

                if let content = msg.content, !content.isEmpty {
                    parts.append(.text(content))
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var args: [String: AnyCodableValue] = [:]
                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            args = argsDict.mapValues { AnyCodableValue($0) }
                        }
                        parts.append(
                            .functionCall(
                                GeminiFunctionCall(
                                    name: toolCall.function.name,
                                    args: args,
                                    thoughtSignature: toolCall.geminiThoughtSignature
                                )
                            )
                        )
                    }
                }

                if !parts.isEmpty {
                    geminiContents.append(GeminiContent(role: "model", parts: parts))
                }

            case "tool":
                // Tool results become functionResponse parts in a user message
                if let content = msg.content {
                    // Use the tool_call_id to find the function name, or use a placeholder
                    let funcName = msg.tool_call_id ?? "function"
                    var responseData: [String: AnyCodableValue] = [:]

                    // Try to parse the content as JSON first
                    if let data = content.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        responseData = json.mapValues { AnyCodableValue($0) }
                    } else {
                        responseData["result"] = AnyCodableValue(content)
                    }

                    pendingFunctionResponses.append(
                        .functionResponse(GeminiFunctionResponse(name: funcName, response: responseData))
                    )
                }

            default:
                flushFunctionResponses()
                if let content = msg.content {
                    geminiContents.append(GeminiContent(role: "user", parts: [.text(content)]))
                }
            }
        }

        // Flush any remaining function responses
        flushFunctionResponses()

        // Convert tools
        var geminiTools: [GeminiTool]? = nil
        if let tools = tools, !tools.isEmpty {
            let declarations = tools.map { tool in
                GeminiFunctionDeclaration(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            }
            geminiTools = [GeminiTool(functionDeclarations: declarations)]
        }

        // Convert tool choice
        var toolConfig: GeminiToolConfig? = nil
        if let choice = tool_choice {
            let mode: String
            switch choice {
            case .auto:
                mode = "AUTO"
            case .none:
                mode = "NONE"
            case .function:
                mode = "ANY"
            }
            toolConfig = GeminiToolConfig(
                functionCallingConfig: GeminiFunctionCallingConfig(mode: mode)
            )
        }

        // Build generation config
        let modelLower = model.lowercased()
        let isImageCapable =
            modelLower.contains("image") || modelLower.contains("nano-banana")
        let responseModalities: [String]? = isImageCapable ? ["TEXT", "IMAGE"] : nil

        var generationConfig: GeminiGenerationConfig? = nil
        if temperature != nil || max_completion_tokens != nil || top_p != nil || stop != nil
            || responseModalities != nil
        {
            generationConfig = GeminiGenerationConfig(
                temperature: temperature.map { Double($0) },
                maxOutputTokens: max_completion_tokens,
                topP: top_p.map { Double($0) },
                topK: nil,
                stopSequences: stop,
                responseModalities: responseModalities
            )
        }

        return GeminiGenerateContentRequest(
            contents: geminiContents,
            tools: geminiTools,
            toolConfig: toolConfig,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig,
            safetySettings: nil
        )
    }

    /// Convert to Open Responses API request format
    func toOpenResponsesRequest() -> OpenResponsesRequest {
        var inputItems: [OpenResponsesInputItem] = []
        var instructions: String? = nil

        for msg in messages {
            switch msg.role {
            case "system":
                // System messages become instructions
                if let content = msg.content {
                    if let existing = instructions {
                        instructions = existing + "\n" + content
                    } else {
                        instructions = content
                    }
                }

            case "user":
                // User messages become message input items
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }

            case "assistant":
                // Assistant messages with tool calls need special handling
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    // First add any text content
                    if let content = msg.content, !content.isEmpty {
                        let msgContent = OpenResponsesMessageContent.text(content)
                        inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                    }
                    // Note: function_call items from assistant are not input items in Open Responses
                    // They would be represented as prior output from the assistant
                } else if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                }

            case "tool":
                // Tool results become function_call_output items
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    inputItems.append(
                        .functionCallOutput(
                            OpenResponsesFunctionCallOutputItem(
                                callId: toolCallId,
                                output: content
                            )
                        )
                    )
                }

            default:
                // Unknown role - treat as user message
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }
            }
        }

        // Convert tools
        var openResponsesTools: [OpenResponsesTool]? = nil
        if let tools = tools {
            openResponsesTools = tools.map { tool in
                OpenResponsesTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            }
        }

        // Convert tool choice
        var openResponsesToolChoice: OpenResponsesToolChoice? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                openResponsesToolChoice = .auto
            case .none:
                openResponsesToolChoice = OpenResponsesToolChoice.none
            case .function(let fn):
                openResponsesToolChoice = .function(name: fn.function.name)
            }
        }

        // Determine input format
        let input: OpenResponsesInput
        if inputItems.count == 1, case .message(let msg) = inputItems[0], msg.role == "user" {
            // Single user message - use text shorthand
            input = .text(msg.content.plainText)
        } else {
            input = .items(inputItems)
        }

        return OpenResponsesRequest(
            model: model,
            input: input,
            stream: stream,
            tools: openResponsesTools,
            tool_choice: openResponsesToolChoice,
            temperature: temperature,
            max_output_tokens: max_completion_tokens,
            top_p: top_p,
            instructions: instructions,
            previous_response_id: nil,
            metadata: nil
        )
    }
}

// MARK: - Static Factory for Creating Services

extension RemoteProviderService {
    /// Fetch models from a remote provider and create a service instance
    public static func fetchModels(from provider: RemoteProvider) async throws -> [String] {
        let modelsURLText = provider.url(for: "/models")?.absoluteString ?? "<invalid-url>"
        await emitModelsDiagnostic(
            level: .info,
            event: "models.fetch.begin",
            context: [
                "providerId": provider.id.uuidString,
                "providerName": provider.name,
                "providerType": provider.providerType.rawValue,
                "baseURL": provider.baseURL?.absoluteString ?? "<invalid-url>",
                "modelsURL": modelsURLText,
            ]
        )

        if provider.providerType == .anthropic {
            guard let baseURL = provider.url(for: "/models") else {
                throw RemoteProviderServiceError.invalidURL
            }
            let models = try await fetchAnthropicModels(
                baseURL: baseURL,
                headers: provider.resolvedHeaders(),
                timeout: min(provider.timeout, 30)
            )
            await emitModelsDiagnostic(
                level: .info,
                event: "models.fetch.success",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "providerType": provider.providerType.rawValue,
                    "modelsURL": modelsURLText,
                    "modelCount": "\(models.count)",
                ]
            )
            return models
        }

        // Gemini uses a different models response format
        if provider.providerType == .gemini {
            let models = try await fetchGeminiModels(from: provider)
            await emitModelsDiagnostic(
                level: .info,
                event: "models.fetch.success",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "providerType": provider.providerType.rawValue,
                    "modelsURL": modelsURLText,
                    "modelCount": "\(models.count)",
                ]
            )
            return models
        }

        // OpenAI-compatible providers use /models endpoint
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }
        let (data, httpResponse) = try await performModelsRequest(
            url: url,
            headers: provider.resolvedHeaders(),
            timeout: min(provider.timeout, 30)
        )

        let contentType = contentType(from: httpResponse)
        do {
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let modelIds = modelsResponse.data.map { $0.id }
            await emitModelsDiagnostic(
                level: .info,
                event: "models.fetch.success",
                context: [
                    "providerId": provider.id.uuidString,
                    "providerName": provider.name,
                    "providerType": provider.providerType.rawValue,
                    "modelsURL": url.absoluteString,
                    "modelCount": "\(modelIds.count)",
                    "statusCode": "\(httpResponse.statusCode)",
                    "contentType": contentType ?? "<missing>",
                    "decodeClass": "json",
                ]
            )
            return modelIds
        } catch {
            let details = classifyModelsDecodeFailure(
                url: url,
                statusCode: httpResponse.statusCode,
                contentType: contentType,
                data: data,
                decodeError: error
            )
            await emitModelsDiagnostic(
                level: .error,
                event: "models.decode.failed",
                context: diagnosticsContext(for: details)
            )
            throw RemoteProviderServiceError.discoveryFailed(details)
        }
    }

    /// Fetch models from Gemini API (different response format from OpenAI)
    private static func fetchGeminiModels(from provider: RemoteProvider) async throws -> [String] {
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }
        let (data, httpResponse) = try await performModelsRequest(
            url: url,
            headers: provider.resolvedHeaders(),
            timeout: min(provider.timeout, 30)
        )
        let contentType = contentType(from: httpResponse)

        // Parse Gemini models response
        let modelsResponse: GeminiModelsResponse
        do {
            modelsResponse = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        } catch {
            let details = classifyModelsDecodeFailure(
                url: url,
                statusCode: httpResponse.statusCode,
                contentType: contentType,
                data: data,
                decodeError: error
            )
            await emitModelsDiagnostic(
                level: .error,
                event: "models.decode.failed",
                context: diagnosticsContext(for: details)
            )
            throw RemoteProviderServiceError.discoveryFailed(details)
        }

        // Filter to models that support generateContent and strip "models/" prefix
        let models = (modelsResponse.models ?? [])
            .filter { model in
                guard let methods = model.supportedGenerationMethods else { return false }
                return methods.contains("generateContent")
            }
            .map { $0.modelId }

        guard !models.isEmpty else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        return models
    }

    /// Fetch all models from the Anthropic `/v1/models` endpoint, handling pagination.
    ///
    /// Shared between `fetchModels(from:)` and `RemoteProviderManager.testAnthropicConnection`.
    static func fetchAnthropicModels(
        baseURL: URL,
        headers: [String: String],
        timeout: TimeInterval = 30
    ) async throws -> [String] {
        var allModels: [String] = []
        var afterId: String? = nil

        while true {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw RemoteProviderServiceError.invalidURL
            }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterId = afterId {
                queryItems.append(URLQueryItem(name: "after_id", value: afterId))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw RemoteProviderServiceError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, httpResponse) = try await performModelsRequest(
                request: request,
                timeout: timeout
            )
            let contentType = contentType(from: httpResponse)

            let modelsResponse: AnthropicModelsResponse
            do {
                modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            } catch {
                let details = classifyModelsDecodeFailure(
                    url: url,
                    statusCode: httpResponse.statusCode,
                    contentType: contentType,
                    data: data,
                    decodeError: error
                )
                await emitModelsDiagnostic(
                    level: .error,
                    event: "models.decode.failed",
                    context: diagnosticsContext(for: details)
                )
                throw RemoteProviderServiceError.discoveryFailed(details)
            }
            allModels.append(contentsOf: modelsResponse.data.map { $0.id })

            if modelsResponse.has_more, let lastId = modelsResponse.last_id {
                afterId = lastId
            } else {
                break
            }
        }

        return allModels
    }

    private static func performModelsRequest(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await performModelsRequest(request: request, timeout: timeout)
    }

    private static func performModelsRequest(
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let session: URLSession
        if timeout > 0 {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            session = URLSession(configuration: config)
        } else {
            session = URLSession.shared
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let details = classifyTransportFailure(url: request.url, error: error)
            await emitModelsDiagnostic(
                level: .error,
                event: "models.request.failed",
                context: diagnosticsContext(for: details)
            )
            throw RemoteProviderServiceError.discoveryFailed(details)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let details = RemoteProviderFailureDetails(
                failureClass: .invalidResponse,
                message: "Provider returned a non-HTTP response for \(request.url?.absoluteString ?? "<unknown>").",
                fixIt: "Ensure the endpoint targets an HTTP model API URL and retry.",
                statusCode: nil,
                contentType: nil,
                bodyPreview: bodyPreview(from: data),
                endpoint: request.url?.absoluteString ?? "<unknown>"
            )
            await emitModelsDiagnostic(
                level: .error,
                event: "models.request.invalidResponse",
                context: diagnosticsContext(for: details)
            )
            throw RemoteProviderServiceError.discoveryFailed(details)
        }

        let contentType = contentType(from: httpResponse)
        await emitModelsDiagnostic(
            level: .info,
            event: "models.http.response",
            context: [
                "endpoint": request.url?.absoluteString ?? "<unknown>",
                "statusCode": "\(httpResponse.statusCode)",
                "contentType": contentType ?? "<missing>",
                "bodyPreview": bodyPreview(from: data) ?? "<empty>",
            ]
        )

        if httpResponse.statusCode >= 400 {
            let details = classifyModelsHTTPFailure(
                url: request.url ?? URL(string: "about:blank")!,
                statusCode: httpResponse.statusCode,
                contentType: contentType,
                data: data
            )
            await emitModelsDiagnostic(
                level: .error,
                event: "models.http.failed",
                context: diagnosticsContext(for: details)
            )
            throw RemoteProviderServiceError.discoveryFailed(details)
        }

        return (data, httpResponse)
    }

    static func classifyModelsHTTPFailure(
        url: URL,
        statusCode: Int,
        contentType: String?,
        data: Data
    ) -> RemoteProviderFailureDetails {
        let endpoint = url.absoluteString
        let preview = bodyPreview(from: data)
        let likelyHTML = isLikelyHTML(contentType: contentType, bodyPreview: preview)
        let openClawFix = openClawEndpointFixIt(for: url)

        if statusCode == 401 || statusCode == 403 {
            return RemoteProviderFailureDetails(
                failureClass: .authFailed,
                message: "Authentication failed while requesting \(endpoint). Verify credentials and retry.",
                fixIt: "Update the provider API key/token in the provider settings, then test connection again.",
                statusCode: statusCode,
                contentType: contentType,
                bodyPreview: preview,
                endpoint: endpoint
            )
        }

        if statusCode == 404 || statusCode == 405 || likelyHTML {
            return RemoteProviderFailureDetails(
                failureClass: .misconfiguredEndpoint,
                message:
                    "Provider endpoint appears misconfigured (HTTP \(statusCode)) while requesting \(endpoint).",
                fixIt: openClawFix
                    ?? "Check the provider base URL/path. The endpoint should return JSON from a model API (for example /v1/models).",
                statusCode: statusCode,
                contentType: contentType,
                bodyPreview: preview,
                endpoint: endpoint
            )
        }

        if (500...599).contains(statusCode) {
            return RemoteProviderFailureDetails(
                failureClass: .gatewayUnavailable,
                message:
                    "Provider gateway returned HTTP \(statusCode) while requesting \(endpoint).",
                fixIt: "Ensure the provider service is running and reachable, then retry.",
                statusCode: statusCode,
                contentType: contentType,
                bodyPreview: preview,
                endpoint: endpoint
            )
        }

        return RemoteProviderFailureDetails(
            failureClass: .unknown,
            message: extractErrorMessage(from: data, statusCode: statusCode),
            fixIt: openClawFix
                ?? "Verify the provider endpoint, credentials, and network connectivity.",
            statusCode: statusCode,
            contentType: contentType,
            bodyPreview: preview,
            endpoint: endpoint
        )
    }

    static func classifyModelsDecodeFailure(
        url: URL,
        statusCode: Int,
        contentType: String?,
        data: Data,
        decodeError: Error
    ) -> RemoteProviderFailureDetails {
        let endpoint = url.absoluteString
        let preview = bodyPreview(from: data)
        let likelyHTML = isLikelyHTML(contentType: contentType, bodyPreview: preview)
        let openClawFix = openClawEndpointFixIt(for: url)

        if likelyHTML {
            return RemoteProviderFailureDetails(
                failureClass: .misconfiguredEndpoint,
                message:
                    "Provider returned HTML/non-JSON content for \(endpoint). This usually indicates an endpoint mismatch.",
                fixIt: openClawFix
                    ?? "Point the provider to a model API endpoint that returns JSON (for example /v1/models).",
                statusCode: statusCode,
                contentType: contentType,
                bodyPreview: preview,
                endpoint: endpoint
            )
        }

        return RemoteProviderFailureDetails(
            failureClass: .invalidResponse,
            message:
                "Provider returned an invalid JSON payload for \(endpoint): \(decodeError.localizedDescription)",
            fixIt: openClawFix
                ?? "Check that the endpoint serves OpenAI/Anthropic-compatible JSON and retry.",
            statusCode: statusCode,
            contentType: contentType,
            bodyPreview: preview,
            endpoint: endpoint
        )
    }

    private static func classifyTransportFailure(url: URL?, error: Error) -> RemoteProviderFailureDetails {
        let endpoint = url?.absoluteString ?? "<unknown>"
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            return RemoteProviderFailureDetails(
                failureClass: .networkUnreachable,
                message: "Network request failed while connecting to \(endpoint): \(nsError.localizedDescription)",
                fixIt: "Check DNS/network access and ensure the host is reachable.",
                statusCode: nil,
                contentType: nil,
                bodyPreview: nil,
                endpoint: endpoint
            )
        }

        return RemoteProviderFailureDetails(
            failureClass: .unknown,
            message: "Request to \(endpoint) failed: \(error.localizedDescription)",
            fixIt: "Verify the endpoint and try again.",
            statusCode: nil,
            contentType: nil,
            bodyPreview: nil,
            endpoint: endpoint
        )
    }

    private static func diagnosticsContext(for details: RemoteProviderFailureDetails) -> [String: String] {
        var context: [String: String] = [
            "endpoint": details.endpoint,
            "failureClass": details.failureClass.rawValue,
            "message": details.message,
        ]
        if let statusCode = details.statusCode {
            context["statusCode"] = "\(statusCode)"
        }
        if let contentType = details.contentType {
            context["contentType"] = contentType
        }
        if let bodyPreview = details.bodyPreview {
            context["bodyPreview"] = bodyPreview
        }
        if let fixIt = details.fixIt {
            context["fixIt"] = fixIt
        }
        return context
    }

    private static func emitModelsDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "remote-provider",
            event: event,
            context: context
        )
    }

    private static func contentType(from response: HTTPURLResponse) -> String? {
        if let value = response.value(forHTTPHeaderField: "Content-Type"), !value.isEmpty {
            return value
        }
        return nil
    }

    private static func bodyPreview(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = String(decoding: data.prefix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return StartupDiagnostics.truncateValue(raw, maxLength: 220)
    }

    private static func isLikelyHTML(contentType: String?, bodyPreview: String?) -> Bool {
        let normalizedType = contentType?.lowercased() ?? ""
        if normalizedType.contains("text/html") || normalizedType.contains("application/xhtml") {
            return true
        }

        let trimmed = bodyPreview?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") || trimmed.hasPrefix("<head")
            || trimmed.hasPrefix("<body")
        {
            return true
        }
        if trimmed.hasPrefix("<") {
            return true
        }
        return false
    }

    private static func openClawEndpointFixIt(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let looksLikeOpenClawRoute =
            path.hasPrefix("/health")
            || path.hasPrefix("/ws")
            || path.hasPrefix("/mcp")
            || path.hasPrefix("/channels")
            || path.hasPrefix("/system")
            || path.hasPrefix("/wizard")
            || path.hasPrefix("/dashboard")
            || path == "/"

        if looksLikeOpenClawRoute || (localHosts.contains(host) && (url.port == 18789 || path == "/")) {
            return
                "This endpoint looks like an OpenClaw gateway UI/control route. Configure the provider with its model API base URL (for example .../v1) and retry."
        }
        return nil
    }

    /// Extract a human-readable error message from API error response data
    private static func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        // Try to parse as JSON error response (OpenAI/xAI format)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/xAI format: {"error": {"message": "...", "type": "...", "code": "..."}}
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String {
                    // Include error code if available for more context
                    if let code = error["code"] as? String {
                        return "\(message) (code: \(code))"
                    }
                    return message
                }
            }
            // Alternative format: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // Alternative format: {"detail": "..."}
            if let detail = json["detail"] as? String {
                return detail
            }
        }

        // Fallback to raw string if JSON parsing fails
        if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
            // Truncate very long error messages
            let truncated = rawMessage.count > 200 ? String(rawMessage.prefix(200)) + "..." : rawMessage
            return "HTTP \(statusCode): \(truncated)"
        }

        return "HTTP \(statusCode): Unknown error"
    }
}
