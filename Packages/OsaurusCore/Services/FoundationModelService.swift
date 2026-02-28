//
//  FoundationModelService.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation
import Terra

#if canImport(FoundationModels)
    import FoundationModels
#endif

enum FoundationModelServiceError: Error {
    case notAvailable
    case generationFailed
}

actor FoundationModelService: ToolCapableService {
    let id: String = "foundation"

    /// Returns true if the system default language model is available on this device/OS.
    static func isDefaultModelAvailable() -> Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return SystemLanguageModel.default.isAvailable
            } else {
                return false
            }
        #else
            return false
        #endif
    }

    nonisolated func isAvailable() -> Bool { Self.isDefaultModelAvailable() }

    nonisolated func handles(requestedModel: String?) -> Bool {
        let t = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.caseInsensitiveCompare("default") == .orderedSame
            || t.caseInsensitiveCompare("foundation") == .orderedSame
    }

    /// Generate a single response from the system default language model.
    /// Falls back to throwing when the framework is unavailable.
    static func generateOneShot(
        prompt: String,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        let request = Terra.InferenceRequest(
            model: "apple/foundation-model",
            prompt: prompt,
            promptCapture: .optIn,
            maxOutputTokens: maxTokens,
            temperature: Double(temperature),
            stream: false
        )
        return try await Terra.withInferenceSpan(request) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("foundation_models"),
                Terra.Keys.GenAI.providerName: .string("apple"),
                Terra.Keys.GenAI.responseModel: .string("apple/foundation-model"),
                Terra.Keys.GenAI.usageInputTokens: .int(max(1, prompt.count / 4)),
                "osaurus.prompt.raw": .string(prompt),
            ])
            #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    let session = LanguageModelSession()

                    let options = GenerationOptions(
                        sampling: nil,
                        temperature: Double(temperature),
                        maximumResponseTokens: maxTokens
                    )
                    let response = try await session.respond(to: prompt, options: options)
                    scope.setAttributes([
                        Terra.Keys.GenAI.usageOutputTokens: .int(max(1, response.content.count / 4)),
                        "osaurus.response.raw": .string(response.content),
                    ])
                    return response.content
                } else {
                    throw FoundationModelServiceError.notAvailable
                }
            #else
                throw FoundationModelServiceError.notAvailable
            #endif
        }
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        let telemetryModel = requestedModel ?? "apple/foundation-model"
        let telemetryTemperature = Double(parameters.temperature ?? 0.7)
        let telemetryMaxTokens = parameters.maxTokens
        let telemetryStopCount = stopSequences.count
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession()

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: Double(parameters.temperature ?? 0.7),
                    maximumResponseTokens: parameters.maxTokens
                )

                let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
                let producerTask = Task {
                    let request = Terra.InferenceRequest(
                        model: telemetryModel,
                        prompt: prompt,
                        promptCapture: .optIn,
                        maxOutputTokens: telemetryMaxTokens,
                        temperature: telemetryTemperature,
                        stream: true
                    )
                    _ = await Terra.withStreamingInferenceSpan(request) { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("foundation_models"),
                            Terra.Keys.GenAI.providerName: .string("apple"),
                            Terra.Keys.GenAI.responseModel: .string(telemetryModel),
                            Terra.Keys.GenAI.usageInputTokens: .int(max(1, prompt.count / 4)),
                            "osaurus.prompt.raw": .string(prompt),
                            "osaurus.request.temperature": .double(telemetryTemperature),
                            "osaurus.request.max_tokens": .int(telemetryMaxTokens),
                            "osaurus.stop_sequences.count": .int(telemetryStopCount),
                        ])

                        var previous = ""
                        do {
                            var iterator = session.streamResponse(to: prompt, options: options).makeAsyncIterator()
                            while let snapshot = try await iterator.next() {
                                // Check for task cancellation to allow early termination
                                if Task.isCancelled {
                                    continuation.finish()
                                    return
                                }
                                var current = snapshot.content
                                if !stopSequences.isEmpty,
                                    let r = stopSequences.compactMap({ current.range(of: $0)?.lowerBound }).first
                                {
                                    current = String(current[..<r])
                                }
                                let delta: String
                                if current.hasPrefix(previous) {
                                    delta = String(current.dropFirst(previous.count))
                                } else {
                                    delta = current
                                }
                                if !delta.isEmpty {
                                    continuation.yield(delta)
                                    scope.recordChunk()
                                }
                                previous = current
                            }
                            let outputLength = previous.count
                            scope.setAttributes([
                                Terra.Keys.GenAI.usageOutputTokens: .int(max(1, outputLength / 4)),
                                "osaurus.response.raw": .string(previous),
                            ])
                            scope.addEvent("foundation.stream_deltas.completed")
                            continuation.finish()
                        } catch {
                            // Handle cancellation gracefully
                            let errorMessage = error.localizedDescription
                            scope.setAttributes([
                                "osaurus.error.message": .string(errorMessage),
                            ])
                            scope.addEvent("foundation.stream_deltas.failed")
                            if Task.isCancelled {
                                continuation.finish()
                            } else {
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                }

                // Cancel producer task when consumer stops consuming
                continuation.onTermination = { @Sendable _ in
                    producerTask.cancel()
                }

                return stream
            } else {
                throw FoundationModelServiceError.notAvailable
            }
        #else
            throw FoundationModelServiceError.notAvailable
        #endif
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        return try await Self.generateOneShot(
            prompt: prompt,
            temperature: parameters.temperature ?? 0.7,
            maxTokens: parameters.maxTokens
        )
    }

    // MARK: - Tool calling bridge (OpenAI tools -> FoundationModels)

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        let telemetryModel = requestedModel ?? "apple/foundation-model"
        let spanRequest = Terra.InferenceRequest(
            model: telemetryModel,
            prompt: prompt,
            promptCapture: .optIn,
            maxOutputTokens: parameters.maxTokens,
            temperature: Double(parameters.temperature ?? 0.7),
            stream: false
        )
        return try await Terra.withInferenceSpan(spanRequest) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("foundation_models"),
                Terra.Keys.GenAI.providerName: .string("apple"),
                Terra.Keys.GenAI.responseModel: .string(telemetryModel),
                Terra.Keys.GenAI.usageInputTokens: .int(max(1, prompt.count / 4)),
                "osaurus.prompt.raw": .string(prompt),
                "osaurus.tools.count": .int(tools.count),
                "osaurus.stop_sequences.count": .int(stopSequences.count),
            ])
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let appleTools: [any FoundationModels.Tool] =
                    tools
                    .filter { self.shouldEnableTool($0, choice: toolChoice) }
                    .map { self.toAppleTool($0) }

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: Double(parameters.temperature ?? 0.7),
                    maximumResponseTokens: parameters.maxTokens
                )

                do {
                    let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
                    let response = try await session.respond(to: prompt, options: options)
                    var reply = response.content
                    if !stopSequences.isEmpty {
                        for s in stopSequences {
                            if let r = reply.range(of: s) {
                                reply = String(reply[..<r.lowerBound])
                                break
                            }
                        }
                    }
                    scope.setAttributes([
                        Terra.Keys.GenAI.usageOutputTokens: .int(max(1, reply.count / 4)),
                        "osaurus.response.raw": .string(reply),
                    ])
                    return reply
                } catch let error as LanguageModelSession.ToolCallError {
                    if let inv = error.underlyingError as? ToolInvocationError {
                        scope.addEvent(
                            "foundation.tool.invocation",
                            attributes: [
                                Terra.Keys.GenAI.toolName: .string(inv.toolName),
                                "osaurus.tool.arguments.length": .int(inv.jsonArguments.count),
                            ]
                        )
                        // Re-throw using shared ServiceToolInvocation so callers don't need Foundation type
                        throw ServiceToolInvocation(toolName: inv.toolName, jsonArguments: inv.jsonArguments)
                    }
                    throw error
                }
            } else {
                throw FoundationModelServiceError.notAvailable
            }
        #else
            throw FoundationModelServiceError.notAvailable
        #endif
        }
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        let telemetryModel = requestedModel ?? "apple/foundation-model"
        let telemetryTemperature = Double(parameters.temperature ?? 0.7)
        let telemetryMaxTokens = parameters.maxTokens
        let telemetryStopCount = stopSequences.count
        let telemetryToolCount = tools.count
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let appleTools: [any FoundationModels.Tool] =
                    tools
                    .filter { self.shouldEnableTool($0, choice: toolChoice) }
                    .map { self.toAppleTool($0) }

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: Double(parameters.temperature ?? 0.7),
                    maximumResponseTokens: parameters.maxTokens
                )

                let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
                let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
                let producerTask = Task {
                    let request = Terra.InferenceRequest(
                        model: telemetryModel,
                        prompt: prompt,
                        promptCapture: .optIn,
                        maxOutputTokens: telemetryMaxTokens,
                        temperature: telemetryTemperature,
                        stream: true
                    )
                    _ = await Terra.withStreamingInferenceSpan(request) { scope in
                        scope.setAttributes([
                            Terra.Keys.Terra.runtime: .string("foundation_models"),
                            Terra.Keys.GenAI.providerName: .string("apple"),
                            Terra.Keys.GenAI.responseModel: .string(telemetryModel),
                            Terra.Keys.GenAI.usageInputTokens: .int(max(1, prompt.count / 4)),
                            "osaurus.prompt.raw": .string(prompt),
                            "osaurus.request.temperature": .double(telemetryTemperature),
                            "osaurus.request.max_tokens": .int(telemetryMaxTokens),
                            "osaurus.stop_sequences.count": .int(telemetryStopCount),
                            "osaurus.tools.count": .int(telemetryToolCount),
                        ])

                        var previous = ""
                        do {
                            var iterator = session.streamResponse(to: prompt, options: options).makeAsyncIterator()
                            while let snapshot = try await iterator.next() {
                                // Check for task cancellation to allow early termination
                                if Task.isCancelled {
                                    continuation.finish()
                                    return
                                }
                                var current = snapshot.content
                                if !stopSequences.isEmpty,
                                    let r = stopSequences.compactMap({ current.range(of: $0)?.lowerBound }).first
                                {
                                    current = String(current[..<r])
                                }
                                let delta: String
                                if current.hasPrefix(previous) {
                                    delta = String(current.dropFirst(previous.count))
                                } else {
                                    delta = current
                                }
                                if !delta.isEmpty {
                                    continuation.yield(delta)
                                    scope.recordChunk()
                                }
                                previous = current
                            }
                            let outputLength = previous.count
                            scope.setAttributes([
                                Terra.Keys.GenAI.usageOutputTokens: .int(max(1, outputLength / 4)),
                                "osaurus.response.raw": .string(previous),
                            ])
                            scope.addEvent("foundation.stream_with_tools.completed")
                            continuation.finish()
                        } catch let error as LanguageModelSession.ToolCallError {
                            if let inv = error.underlyingError as? ToolInvocationError {
                                scope.addEvent(
                                    "foundation.tool.invocation",
                                    attributes: [
                                        Terra.Keys.GenAI.toolName: .string(inv.toolName),
                                        "osaurus.tool.arguments.length": .int(inv.jsonArguments.count),
                                    ]
                                )
                                continuation.finish(
                                    throwing: ServiceToolInvocation(
                                        toolName: inv.toolName,
                                        jsonArguments: inv.jsonArguments
                                    )
                                )
                            } else {
                                let errorMessage = error.localizedDescription
                                scope.setAttributes([
                                    "osaurus.error.message": .string(errorMessage),
                                ])
                                scope.addEvent("foundation.stream_with_tools.failed")
                                continuation.finish(throwing: error)
                            }
                        } catch {
                            // Handle cancellation gracefully
                            let errorMessage = error.localizedDescription
                            scope.setAttributes([
                                "osaurus.error.message": .string(errorMessage),
                            ])
                            scope.addEvent("foundation.stream_with_tools.failed")
                            if Task.isCancelled {
                                continuation.finish()
                            } else {
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                }

                // Cancel producer task when consumer stops consuming
                continuation.onTermination = { @Sendable _ in
                    producerTask.cancel()
                }

                return stream
            } else {
                throw FoundationModelServiceError.notAvailable
            }
        #else
            throw FoundationModelServiceError.notAvailable
        #endif
    }

    // MARK: - Private helpers

    #if canImport(FoundationModels)
        @available(macOS 26.0, *)
        private struct ToolInvocationError: Error {
            let toolName: String
            let jsonArguments: String
        }

        @available(macOS 26.0, *)
        private struct OpenAIToolAdapter: FoundationModels.Tool {
            typealias Output = String
            typealias Arguments = GeneratedContent

            let name: String
            let description: String
            let parameters: GenerationSchema
            var includesSchemaInInstructions: Bool { true }

            func call(arguments: GeneratedContent) async throws -> String {
                // Serialize arguments as JSON and throw to signal a tool call back to the server
                let json = arguments.jsonString
                throw ToolInvocationError(toolName: name, jsonArguments: json)
            }
        }

        @available(macOS 26.0, *)
        nonisolated private func toAppleTool(_ tool: Tool) -> any FoundationModels.Tool {
            let desc = tool.function.description ?? ""
            let schema: GenerationSchema = makeGenerationSchema(
                from: tool.function.parameters,
                toolName: tool.function.name,
                description: desc
            )
            return OpenAIToolAdapter(name: tool.function.name, description: desc, parameters: schema)
        }

        // Convert OpenAI JSON Schema (as JSONValue) to FoundationModels GenerationSchema
        @available(macOS 26.0, *)
        nonisolated private func makeGenerationSchema(
            from parameters: JSONValue?,
            toolName: String,
            description: String?
        ) -> GenerationSchema {
            guard let parameters else {
                return GenerationSchema(
                    type: GeneratedContent.self,
                    description: description,
                    properties: []
                )
            }
            if let root = dynamicSchema(from: parameters, name: toolName) {
                if let schema = try? GenerationSchema(root: root, dependencies: []) {
                    return schema
                }
            }
            return GenerationSchema(type: GeneratedContent.self, description: description, properties: [])
        }

        // Build a DynamicGenerationSchema recursively from a minimal subset of JSON Schema
        @available(macOS 26.0, *)
        nonisolated private func dynamicSchema(from json: JSONValue, name: String) -> DynamicGenerationSchema? {
            switch json {
            case .object(let dict):
                // enum of strings
                if case .array(let enumVals)? = dict["enum"],
                    case .string = enumVals.first
                {
                    let choices: [String] = enumVals.compactMap { v in
                        if case .string(let s) = v { return s } else { return nil }
                    }
                    return DynamicGenerationSchema(
                        name: name,
                        description: jsonStringOrNil(dict["description"]),
                        anyOf: choices
                    )
                }

                // type can be string or array
                var typeString: String? = nil
                if let t = dict["type"] {
                    switch t {
                    case .string(let s): typeString = s
                    case .array(let arr):
                        // Prefer first non-null type
                        typeString =
                            arr.compactMap { v in
                                if case .string(let s) = v, s != "null" { return s } else { return nil }
                            }.first
                    default: break
                    }
                }

                let desc = jsonStringOrNil(dict["description"])

                switch typeString ?? "object" {
                case "string":
                    return DynamicGenerationSchema(type: String.self)
                case "integer":
                    return DynamicGenerationSchema(type: Int.self)
                case "number":
                    return DynamicGenerationSchema(type: Double.self)
                case "boolean":
                    return DynamicGenerationSchema(type: Bool.self)
                case "array":
                    if let items = dict["items"],
                        let itemSchema = dynamicSchema(from: items, name: name + "Item")
                    {
                        let minItems = jsonIntOrNil(dict["minItems"])
                        let maxItems = jsonIntOrNil(dict["maxItems"])
                        return DynamicGenerationSchema(
                            arrayOf: itemSchema,
                            minimumElements: minItems,
                            maximumElements: maxItems
                        )
                    }
                    // Fallback to array of strings
                    return DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(type: String.self),
                        minimumElements: nil,
                        maximumElements: nil
                    )
                case "object": fallthrough
                default:
                    // Build object properties
                    var required: Set<String> = []
                    if case .array(let reqArr)? = dict["required"] {
                        required = Set(
                            reqArr.compactMap { v in if case .string(let s) = v { return s } else { return nil } }
                        )
                    }
                    var properties: [DynamicGenerationSchema.Property] = []
                    if case .object(let propsDict)? = dict["properties"] {
                        for (propName, propSchemaJSON) in propsDict {
                            let propSchema =
                                dynamicSchema(from: propSchemaJSON, name: name + "." + propName)
                                ?? DynamicGenerationSchema(type: String.self)
                            let isOptional = !required.contains(propName)
                            let prop = DynamicGenerationSchema.Property(
                                name: propName,
                                description: nil,
                                schema: propSchema,
                                isOptional: isOptional
                            )
                            properties.append(prop)
                        }
                    }
                    return DynamicGenerationSchema(name: name, description: desc, properties: properties)
                }

            case .string:
                return DynamicGenerationSchema(type: String.self)
            case .number:
                return DynamicGenerationSchema(type: Double.self)
            case .bool:
                return DynamicGenerationSchema(type: Bool.self)
            case .array(let arr):
                // Attempt array of first element type
                if let first = arr.first, let item = dynamicSchema(from: first, name: name + "Item") {
                    return DynamicGenerationSchema(arrayOf: item, minimumElements: nil, maximumElements: nil)
                }
                return DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(type: String.self),
                    minimumElements: nil,
                    maximumElements: nil
                )
            case .null:
                // Default to string when null only
                return DynamicGenerationSchema(type: String.self)
            }
        }

        // Helpers to extract primitive values from JSONValue
        nonisolated private func jsonStringOrNil(_ value: JSONValue?) -> String? {
            guard let value else { return nil }
            if case .string(let s) = value { return s }
            return nil
        }
        nonisolated private func jsonIntOrNil(_ value: JSONValue?) -> Int? {
            guard let value else { return nil }
            switch value {
            case .number(let d): return Int(d)
            case .string(let s): return Int(s)
            default: return nil
            }
        }

        @available(macOS 26.0, *)
        nonisolated private func shouldEnableTool(_ tool: Tool, choice: ToolChoiceOption?) -> Bool {
            guard let choice else { return true }
            switch choice {
            case .auto: return true
            case .none: return false
            case .function(let n):
                return n.function.name == tool.function.name
            }
        }
    #endif
}
