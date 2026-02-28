//
//  WorkExecutionEngine.swift
//  osaurus
//
//  Execution engine for Osaurus Agents - reasoning loop based.
//  Handles iterative task execution where model decides actions.
//

import Foundation
import Terra
import OpenTelemetryApi

/// Execution engine for running work tasks via reasoning loop
public actor WorkExecutionEngine {
    private final class ChatMessageBuffer: @unchecked Sendable {
        var messages: [ChatMessage]

        init(_ messages: [ChatMessage]) {
            self.messages = messages
        }
    }

    /// The chat engine for LLM calls
    private let chatEngine: ChatEngineProtocol

    typealias OpenClawWorkspaceFilesLoader = @Sendable () async -> [OpenClawAgentWorkspaceFile]
    private let openClawWorkspaceFilesLoader: OpenClawWorkspaceFilesLoader

    init(
        chatEngine: ChatEngineProtocol? = nil,
        openClawWorkspaceFilesLoader: OpenClawWorkspaceFilesLoader? = nil
    ) {
        self.chatEngine = chatEngine ?? ChatEngine(source: .agent)
        self.openClawWorkspaceFilesLoader =
            openClawWorkspaceFilesLoader ?? Self.defaultOpenClawWorkspaceFilesLoader
    }

    // MARK: - Tool Execution

    /// Maximum time (in seconds) to wait for a single tool execution before timing out.
    private static let toolExecutionTimeout: UInt64 = 120

    /// Executes a tool call with a timeout to prevent indefinite hangs.
    /// Uses ToolRegistry span instrumentation with preserved model tool-call IDs.
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        overrides: [String: Bool]?,
        issueId: String
    ) async throws -> ToolCallResult {
        let callId =
            invocation.toolCallId
            ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        let timeout = Self.toolExecutionTimeout
        let toolName = invocation.toolName

        let result: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                return await self.executeToolInBackground(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments,
                    overrides: overrides,
                    issueId: issueId,
                    telemetryCallId: callId
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                return nil
            }

            let first = await group.next()!
            group.cancelAll()

            if let result = first {
                return result
            }

            print("[WorkExecutionEngine] Tool '\(toolName)' timed out after \(timeout)s")
            return "[TIMEOUT] Tool '\(toolName)' did not complete within \(timeout) seconds."
        }

        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: invocation.jsonArguments
            ),
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )

        return ToolCallResult(toolCall: toolCall, result: result)
    }

    /// Helper to execute tool in background with issue context
    private func executeToolInBackground(
        name: String,
        argumentsJSON: String,
        overrides: [String: Bool]?,
        issueId: String,
        telemetryCallId: String
    ) async -> String {
        do {
            // Wrap with execution context so folder tools can log operations
            return try await WorkExecutionContext.$currentIssueId.withValue(issueId) {
                try await ToolRegistry.shared.execute(
                    name: name,
                    argumentsJSON: argumentsJSON,
                    overrides: overrides,
                    telemetryCallId: telemetryCallId
                )
            }
        } catch {
            print("[WorkExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Folder Context

    /// Builds the folder context section for prompts when a folder is selected
    private func buildFolderContextSection(from folderContext: WorkFolderContext?) -> String {
        guard let folder = folderContext else {
            return ""
        }

        var section = "\n## Working Directory\n"
        section += "**Path:** \(folder.rootPath.path)\n"
        section += "**Project Type:** \(folder.projectType.displayName)\n"

        section += "\n**File Structure:**\n```\n\(folder.tree)```\n"

        if let manifest = folder.manifest {
            // Truncate manifest if too long for prompt
            let truncatedManifest =
                manifest.count > 2000 ? String(manifest.prefix(2000)) + "\n... (truncated)" : manifest
            section += "\n**Manifest:**\n```\n\(truncatedManifest)\n```\n"
        }

        if let gitStatus = folder.gitStatus, !gitStatus.isEmpty {
            section += "\n**Git Status:**\n```\n\(gitStatus)\n```\n"
        }

        section +=
            "\n**File Tools Available:** Use file_read, file_write, file_edit, file_search, etc. to work with files.\n"
        section += "Always read files before editing. Use relative paths from the working directory.\n"

        return section
    }

    // MARK: - Reasoning Loop

    /// Callback type for iteration-based streaming updates
    public typealias IterationStreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback type for tool call completion
    public typealias ToolCallCallback = @MainActor @Sendable (String, String, String) async -> Void

    /// Callback type for status updates
    public typealias StatusCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for artifact generation
    public typealias ArtifactCallback = @MainActor @Sendable (Artifact) async -> Void

    /// Callback type for iteration start (iteration number)
    public typealias IterationStartCallback = @MainActor @Sendable (Int) async -> Void

    /// Callback type for token consumption (inputTokens, outputTokens)
    public typealias TokenConsumptionCallback = @MainActor @Sendable (Int, Int) async -> Void

    /// Default maximum iterations for the reasoning loop
    public static let defaultMaxIterations = 30

    /// Maximum consecutive text-only responses (no tool call) before aborting.
    /// Models that don't support tool calling will describe actions in plain text
    /// instead of invoking tools, causing an infinite loop of "Continue" prompts.
    private static let maxConsecutiveTextOnlyResponses = 3
    private static let clarificationStartMarker = "---REQUEST_CLARIFICATION_START---"
    private static let clarificationEndMarker = "---REQUEST_CLARIFICATION_END---"
    private static let completeTaskStartMarker = "---COMPLETE_TASK_START---"
    private static let completeTaskEndMarker = "---COMPLETE_TASK_END---"
    private static let generatedArtifactStartMarker = "---GENERATED_ARTIFACT_START---"
    private static let generatedArtifactEndMarker = "---GENERATED_ARTIFACT_END---"
    private static let maxWorkspaceFilesToImport = 12
    private static let maxWorkspaceArtifactCharacters = 250_000

    /// The main reasoning loop. Model decides what to do on each iteration.
    /// - Parameters:
    ///   - issue: The issue being executed
    ///   - messages: Conversation messages (mutated with new messages)
    ///   - systemPrompt: The full system prompt including work instructions
    ///   - model: Model to use
    ///   - tools: All available tools (model picks which to use)
    ///   - toolOverrides: Tool permission overrides
    ///   - contextLength: Model context window size in tokens (used for budget management)
    ///   - toolTokenEstimate: Estimated tokens consumed by tool definitions
    ///   - maxIterations: Maximum loop iterations (not tool calls - iterations)
    ///   - onIterationStart: Callback at the start of each iteration
    ///   - onDelta: Callback for streaming text deltas
    ///   - onToolCall: Callback when a tool is called (toolName, args, result)
    ///   - onStatusUpdate: Callback for status messages
    ///   - onArtifact: Callback when an artifact is generated (via generate_artifact tool)
    ///   - onTokensConsumed: Callback with estimated token consumption per iteration
    /// - Returns: The result of the loop execution
    func executeLoop(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        toolOverrides: [String: Bool]?,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        contextLength: Int? = nil,
        toolTokenEstimate: Int = 0,
        maxIterations: Int = defaultMaxIterations,
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onToolCall: @escaping ToolCallCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback
    ) async throws -> LoopResult {
        if Self.isOpenClawRequestedModel(model) {
            return try await executeOpenClawGatewayRun(
                issue: issue,
                messages: &messages,
                systemPrompt: systemPrompt,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens,
                topPOverride: topPOverride,
                onIterationStart: onIterationStart,
                onDelta: onDelta,
                onStatusUpdate: onStatusUpdate,
                onArtifact: onArtifact,
                onTokensConsumed: onTokensConsumed
            )
        }

        let messageBuffer = ChatMessageBuffer(messages)
        let loopResult: LoopResult = try await Terra.withAgentInvocationSpan(
            agent: .init(name: "osaurus.work.loop", id: issue.id)
        ) { scope -> LoopResult in
            scope.setAttributes([
                Terra.Keys.Terra.autoInstrumented: .bool(false),
                Terra.Keys.Terra.runtime: .string("osaurus_sdk"),
                Terra.Keys.GenAI.providerName: .string("osaurus"),
                "osaurus.trace.origin": .string("sdk"),
                "osaurus.trace.surface": .string("work_loop"),
                "osaurus.work.model": .string(model ?? "default"),
                "osaurus.work.max_iterations": .int(maxIterations),
                "osaurus.work.tools.count": .int(tools.count),
                "osaurus.work.context_length": .int(contextLength ?? 0),
                "osaurus.work.system_prompt.length": .int(systemPrompt.count),
                "osaurus.work.request.temperature": .double(Double(temperature ?? 0.3)),
                "osaurus.work.request.max_tokens": .int(maxTokens ?? 4096),
                "osaurus.work.request.top_p": .double(Double(topPOverride ?? 1)),
            ])

            var iteration = 0
            var totalToolCalls = 0
            var toolsUsed: [String] = []
            var consecutiveTextOnly = 0
            var lastResponseContent = ""

            defer {
                scope.setAttributes([
                    "osaurus.work.total_iterations": .int(iteration),
                    "osaurus.work.total_tool_calls": .int(totalToolCalls),
                    "osaurus.work.tools_used.count": .int(toolsUsed.count),
                ])
            }

            // Set up context budget manager if context length is known
            var budgetManager: ContextBudgetManager? = nil
            if let ctxLen = contextLength {
                var manager = ContextBudgetManager(contextLength: ctxLen)
                manager.reserveByCharCount(.systemPrompt, characters: systemPrompt.count)
                manager.reserve(.tools, tokens: toolTokenEstimate)
                manager.reserve(.memory, tokens: 0)
                manager.reserve(.response, tokens: maxTokens ?? 4096)
                budgetManager = manager
            }

            while iteration < maxIterations {
                iteration += 1
                scope.addEvent("osaurus.work.iteration.start", attributes: ["osaurus.work.iteration": .int(iteration)])
                try Task.checkCancellation()

                await onIterationStart(iteration)

                await onStatusUpdate("Iteration \(iteration)")

                // Trim messages to fit context budget (no-op if within budget or no limit known)
                let effectiveMessages: [ChatMessage]
                if let manager = budgetManager {
                    effectiveMessages = manager.trimMessages(messageBuffer.messages)
                } else {
                    effectiveMessages = messageBuffer.messages
                }

                // Build full messages with system prompt
                let fullMessages = [ChatMessage(role: "system", content: systemPrompt)] + effectiveMessages

                // Create request with all available tools - model picks which to use
                let request = ChatCompletionRequest(
                    model: model ?? "default",
                    messages: fullMessages,
                    temperature: temperature ?? 0.3,
                    max_tokens: maxTokens ?? 4096,
                    stream: nil,
                    top_p: topPOverride,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: tools.isEmpty ? nil : tools,
                    tool_choice: nil,
                    session_id: nil
                )

                // Stream response
                var responseContent = ""
                var toolInvoked: ServiceToolInvocation?

                do {
                    let stream = try await chatEngine.streamChat(request: request)
                    for try await delta in stream {
                        responseContent += delta
                        await onDelta(delta, iteration)
                    }
                } catch let invocation as ServiceToolInvocation {
                    toolInvoked = invocation
                }

                lastResponseContent = responseContent

                // Estimate token consumption for this iteration
                // Rough estimate: ~4 characters per token (varies by model/tokenizer)
                let inputChars = fullMessages.reduce(0) { $0 + ($1.content?.count ?? 0) } + systemPrompt.count
                let outputChars = responseContent.count + (toolInvoked?.jsonArguments.count ?? 0)
                let estimatedInputTokens = max(1, inputChars / 4)
                let estimatedOutputTokens = max(1, outputChars / 4)
                await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)
                scope.addEvent(
                    "osaurus.work.iteration.tokens",
                    attributes: [
                        "osaurus.work.iteration": .int(iteration),
                        Terra.Keys.GenAI.usageInputTokens: .int(estimatedInputTokens),
                        Terra.Keys.GenAI.usageOutputTokens: .int(estimatedOutputTokens),
                    ]
                )

                // Emit a consolidated iteration-completed event with full context
                scope.addEvent(
                    "osaurus.work.iteration.completed",
                    attributes: [
                        "osaurus.work.iteration": .int(iteration),
                        "osaurus.work.response.length": .int(responseContent.count),
                        "osaurus.work.response.has_tool_call": .bool(toolInvoked != nil),
                        "osaurus.work.tools_used_so_far": .string(toolsUsed.joined(separator: ",")),
                        "osaurus.work.tool.name": .string(toolInvoked?.toolName ?? ""),
                    ]
                )

                // If pure text response (no tool call) - check if model signals completion
                if toolInvoked == nil {
                    messageBuffer.messages.append(ChatMessage(role: "assistant", content: responseContent))
                    scope.addEvent(
                        "osaurus.work.iteration.text_response",
                        attributes: [
                            "osaurus.work.iteration": .int(iteration),
                            "osaurus.work.response.length": .int(responseContent.count),
                        ]
                    )

                    // Check for completion signals in the response
                    if Self.isCompletionSignal(responseContent) {
                        scope.addEvent("osaurus.work.completed.signal", attributes: ["osaurus.work.iteration": .int(iteration)])
                        let summary = Self.extractCompletionSummary(from: responseContent)
                        return LoopResult.completed(summary: summary, artifact: nil)
                    }

                    // Track consecutive text-only responses to detect models that can't use tools
                    consecutiveTextOnly += 1
                    if consecutiveTextOnly >= Self.maxConsecutiveTextOnlyResponses {
                        print(
                            "[WorkExecutionEngine] \(consecutiveTextOnly) consecutive text-only responses"
                                + " — aborting to prevent infinite loop"
                        )
                        scope.addEvent(
                            "osaurus.work.completed.text_only_guard",
                            attributes: ["osaurus.work.consecutive_text_only": .int(consecutiveTextOnly)]
                        )
                        let summary = Self.extractCompletionSummary(from: responseContent)
                        let fallback =
                            summary.isEmpty
                            ? String(responseContent.prefix(500))
                            : summary
                        return LoopResult.completed(summary: fallback, artifact: nil)
                    }

                    // Model is reasoning but hasn't called a tool yet - prompt to continue
                    // This helps models that reason out loud before acting
                    messageBuffer.messages.append(ChatMessage(role: "user", content: "Continue with the next action."))
                    continue
                }

                // Model successfully called a tool - reset consecutive text-only counter
                consecutiveTextOnly = 0

                // Tool call - execute it
                let invocation = toolInvoked!
                totalToolCalls += 1
                if !toolsUsed.contains(invocation.toolName) {
                    toolsUsed.append(invocation.toolName)
                }

                scope.addEvent(
                    "osaurus.work.tool.invocation",
                    attributes: [
                        Terra.Keys.GenAI.toolName: .string(invocation.toolName),
                        "osaurus.work.iteration": .int(iteration),
                        "osaurus.work.tool_args.length": .int(invocation.jsonArguments.count),
                        "osaurus.work.tool_call_id": .string(invocation.toolCallId ?? ""),
                    ]
                )

                // Check for meta-tool signals before execution
                switch invocation.toolName {
                case "complete_task":
                    // Parse the complete_task arguments to get summary and artifact
                    let (summary, artifact) = Self.parseCompleteTaskArgs(invocation.jsonArguments, taskId: issue.taskId)
                    return LoopResult.completed(summary: summary, artifact: artifact)

                case "request_clarification":
                    // Parse clarification request
                    let clarification = Self.parseClarificationArgs(invocation.jsonArguments)
                    return LoopResult.needsClarification(clarification)

                default:
                    break
                }

                // Execute the tool
                let result = try await executeToolCall(invocation, overrides: toolOverrides, issueId: issue.id)
                scope.addEvent(
                    "osaurus.work.tool.completed",
                    attributes: [
                        Terra.Keys.GenAI.toolName: .string(invocation.toolName),
                        "osaurus.work.iteration": .int(iteration),
                        "osaurus.work.tool_result.length": .int(result.result.count),
                        "osaurus.work.tool_success": .bool(!result.result.hasPrefix("[REJECTED]")),
                    ]
                )
                await onToolCall(invocation.toolName, invocation.jsonArguments, result.result)

                // Clean response content - strip any leaked function-call JSON patterns
                let cleanedContent = StringCleaning.stripFunctionCallLeakage(responseContent, toolName: invocation.toolName)

                // Append tool call + result to conversation
                if cleanedContent.isEmpty {
                    messageBuffer.messages.append(
                        ChatMessage(role: "assistant", content: nil, tool_calls: [result.toolCall], tool_call_id: nil)
                    )
                } else {
                    messageBuffer.messages.append(
                        ChatMessage(
                            role: "assistant",
                            content: cleanedContent,
                            tool_calls: [result.toolCall],
                            tool_call_id: nil
                        )
                    )
                }
                messageBuffer.messages.append(
                    ChatMessage(
                        role: "tool",
                        content: result.result,
                        tool_calls: nil,
                        tool_call_id: result.toolCall.id
                    )
                )

                // Log the tool call event
                _ = try? IssueStore.createEvent(
                    IssueEvent.withPayload(
                        issueId: issue.id,
                        eventType: .toolCallCompleted,
                        payload: EventPayload.ToolCallCompleted(
                            toolName: invocation.toolName,
                            iteration: iteration,
                            arguments: invocation.jsonArguments,
                            result: result.result,
                            success: !result.result.hasPrefix("[REJECTED]")
                        )
                    )
                )

                // Handle semi-meta-tools (execute but also process results)
                switch invocation.toolName {
                case "create_issue":
                    await onStatusUpdate("Created follow-up issue")

                case "generate_artifact":
                    // Extract artifact from tool result and notify delegate
                    if let artifact = Self.parseGeneratedArtifact(from: result.result, taskId: issue.taskId) {
                        await onArtifact(artifact)
                        await onStatusUpdate("Generated artifact: \(artifact.filename)")
                    }

                default:
                    break
                }
            }

            // Hit iteration limit
            return LoopResult.iterationLimitReached(
                totalIterations: iteration,
                totalToolCalls: totalToolCalls,
                lastResponseContent: lastResponseContent
            )
        }
        messages = messageBuffer.messages
        return loopResult
    }

    private static func isOpenClawRequestedModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return model.hasPrefix(OpenClawModelService.sessionPrefix)
            || model.hasPrefix(OpenClawModelService.modelPrefix)
    }

    /// Runs Work execution through OpenClaw's gateway runtime in a single pass.
    /// OpenClaw performs orchestration and tool execution on its side, so Osaurus does
    /// not run the local reasoning/tool loop for this path.
    private func executeOpenClawGatewayRun(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        temperature: Float?,
        maxTokens: Int?,
        topPOverride: Float?,
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback
    ) async throws -> LoopResult {
        guard let model else {
            throw WorkExecutionError.unknown("OpenClaw model is missing.")
        }

        guard model.hasPrefix(OpenClawModelService.sessionPrefix) else {
            throw WorkExecutionError.unknown(
                "OpenClaw work execution requires runtime session model identifiers."
            )
        }

        let messageBuffer = ChatMessageBuffer(messages)
        let loopResult: LoopResult = try await Terra.withAgentInvocationSpan(
            agent: .init(name: "osaurus.work.openclaw.gateway", id: issue.id)
        ) { scope -> LoopResult in
            scope.setAttributes([
                Terra.Keys.Terra.autoInstrumented: .bool(false),
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.trace.origin": .string("sdk"),
                "osaurus.trace.surface": .string("work_openclaw_gateway"),
                "osaurus.work.model": .string(model),
                "osaurus.work.issue.id": .string(issue.id),
                "osaurus.work.task.id": .string(issue.taskId),
                "osaurus.work.issue.title": .string(issue.title),
                "osaurus.work.request.temperature": .double(Double(temperature ?? 0.3)),
                "osaurus.work.request.max_tokens": .int(maxTokens ?? 4096),
                "osaurus.work.request.top_p": .double(Double(topPOverride ?? 1)),
            ])

            try Task.checkCancellation()
            await onIterationStart(1)
            await onStatusUpdate("Running via OpenClaw gateway")

            let gatewayInput = Self.buildOpenClawGatewayInput(
                issue: issue,
                systemPrompt: systemPrompt,
                messages: messageBuffer.messages
            )
            scope.setAttributes([
                "osaurus.prompt.raw": .string(gatewayInput),
                "osaurus.work.gateway_input.length": .int(gatewayInput.count),
                Terra.Keys.GenAI.usageInputTokens: .int(max(1, gatewayInput.count / 4)),
            ])

            let request = ChatCompletionRequest(
                model: model,
                messages: [ChatMessage(role: "user", content: gatewayInput)],
                temperature: temperature ?? 0.3,
                max_tokens: maxTokens ?? 4096,
                stream: nil,
                top_p: topPOverride,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: nil,
                tool_choice: nil,
                session_id: nil
            )

            var rawResponseContent = ""
            var visibleResponseContent = ""
            var outputFilter = OpenClawOutputFilter()
            do {
                let stream = try await chatEngine.streamChat(request: request)
                for try await delta in stream {
                    try Task.checkCancellation()
                    rawResponseContent += delta
                    let visibleDelta = outputFilter.consume(delta)
                    if !visibleDelta.isEmpty {
                        visibleResponseContent += visibleDelta
                        await onDelta(visibleDelta, 1)
                    }
                }
                let tail = outputFilter.finalize()
                if !tail.isEmpty {
                    visibleResponseContent += tail
                    await onDelta(tail, 1)
                }
            } catch is ServiceToolInvocation {
                throw WorkExecutionError.toolExecutionFailed(
                    "Unexpected local tool invocation during OpenClaw gateway execution."
                )
            }

            let estimatedInputTokens = max(1, gatewayInput.count / 4)
            let estimatedOutputTokens = max(1, rawResponseContent.count / 4)
            await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)
            scope.setAttributes([
                Terra.Keys.GenAI.usageOutputTokens: .int(estimatedOutputTokens),
                "osaurus.response.raw": .string(rawResponseContent),
                "osaurus.response.visible.length": .int(visibleResponseContent.count),
            ])

            let cleanedVisibleResponse = Self.sanitizeOpenClawVisibleResponse(visibleResponseContent)
            let trimmedResponse = cleanedVisibleResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            messageBuffer.messages.append(ChatMessage(role: "user", content: gatewayInput))
            if !trimmedResponse.isEmpty {
                messageBuffer.messages.append(ChatMessage(role: "assistant", content: trimmedResponse))
            }

            if let clarificationJSON = Self.extractLastJSONBlock(
                from: rawResponseContent,
                startMarker: Self.clarificationStartMarker,
                endMarker: Self.clarificationEndMarker
            ) {
                scope.addEvent(
                    "osaurus.work.needs_clarification",
                    attributes: [
                        "osaurus.work.clarification.payload.length": .int(clarificationJSON.count),
                    ]
                )
                let clarification = Self.parseClarificationArgs(clarificationJSON)
                return LoopResult.needsClarification(clarification)
            }

            var completionSummary = Self.extractCompletionSummary(from: trimmedResponse)
            var completionArtifact: Artifact?
            if let completionJSON = Self.extractLastJSONBlock(
                from: rawResponseContent,
                startMarker: Self.completeTaskStartMarker,
                endMarker: Self.completeTaskEndMarker
            ) {
                scope.addEvent(
                    "osaurus.work.completion.block.detected",
                    attributes: [
                        "osaurus.work.completion.payload.length": .int(completionJSON.count),
                    ]
                )
                let parsed = Self.parseCompleteTaskArgs(completionJSON, taskId: issue.taskId)
                completionSummary = parsed.0
                completionArtifact = parsed.1
            }

            var generatedArtifacts: [Artifact] = Self.parseGeneratedArtifacts(
                from: rawResponseContent,
                taskId: issue.taskId
            )
            scope.setAttributes([
                "osaurus.work.generated_artifacts.count": .int(generatedArtifacts.count),
            ])
            if let completionArtifact {
                generatedArtifacts.removeAll {
                    $0.filename.caseInsensitiveCompare(completionArtifact.filename) == .orderedSame
                        && $0.content == completionArtifact.content
                }
            }
            for artifact in generatedArtifacts {
                await onArtifact(artifact)
            }

            let importedWorkspaceFiles = await importOpenClawWorkspaceArtifacts(taskId: issue.taskId)
            scope.setAttributes([
                "osaurus.work.workspace_artifacts.imported.count": .int(importedWorkspaceFiles.count),
            ])
            var workspaceFinalArtifact: Artifact?
            for fileArtifact in importedWorkspaceFiles {
                if let completionArtifact,
                    completionArtifact.filename.caseInsensitiveCompare(fileArtifact.filename) == .orderedSame,
                    completionArtifact.content == fileArtifact.content
                {
                    continue
                }

                if completionArtifact == nil,
                    workspaceFinalArtifact == nil,
                    Self.isPreferredWorkspaceFinalArtifact(filename: fileArtifact.filename)
                {
                    workspaceFinalArtifact = Artifact(
                        taskId: fileArtifact.taskId,
                        filename: fileArtifact.filename,
                        content: fileArtifact.content,
                        contentType: fileArtifact.contentType,
                        isFinalResult: true
                    )
                    continue
                }

                await onArtifact(fileArtifact)
            }

            let finalArtifact = completionArtifact ?? workspaceFinalArtifact

            if completionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completionSummary = trimmedResponse.isEmpty
                    ? "OpenClaw run completed."
                    : Self.extractCompletionSummary(from: trimmedResponse)
            }

            scope.setAttributes([
                "osaurus.work.completion.summary": .string(completionSummary),
                "osaurus.work.completion.has_final_artifact": .bool(finalArtifact != nil),
            ])
            return LoopResult.completed(
                summary: completionSummary,
                artifact: finalArtifact
            )
        }
        messages = messageBuffer.messages
        return loopResult
    }

    private static func buildOpenClawGatewayInput(
        issue: Issue,
        systemPrompt: String,
        messages: [ChatMessage]
    ) -> String {
        let issueTitle = issue.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let issueDescription = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines)

        var issueLines: [String] = []
        if !issueTitle.isEmpty {
            issueLines.append(issueTitle)
        }
        if let issueDescription, !issueDescription.isEmpty,
           normalizedPromptComparisonText(issueDescription) != normalizedPromptComparisonText(issueTitle)
        {
            issueLines.append(issueDescription)
        }

        let dedupeUserInputs = Set(issueLines.map { normalizedPromptComparisonText($0) })

        var sections: [String] = []
        sections.append(
            """
            You are executing an Osaurus Work issue through the OpenClaw gateway.

            Issue:
            \(issueLines.joined(separator: "\n"))
            """
        )
        sections.append("System instructions:\n\(systemPrompt)")

        let contextLines = messages.compactMap { message -> String? in
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if message.role.caseInsensitiveCompare("user") == .orderedSame {
                let normalized = normalizedPromptComparisonText(text)
                if dedupeUserInputs.contains(normalized) {
                    return nil
                }
            }
            return "[\(message.role)]\n\(text)"
        }
        if !contextLines.isEmpty {
            sections.append("Conversation context:\n\(contextLines.joined(separator: "\n\n"))")
        }

        sections.append(
            """
            Respond with concise progress updates while working.
            Use polished, readable markdown for user-visible output (headings, lists, tables, code fences when helpful).
            Do not include internal/system traces in the visible response (for example, do not emit `System:` trace sections).
            When complete, include a clear completion summary.

            If you need clarification, emit exactly one block:
            \(Self.clarificationStartMarker)
            {"question":"<question>","options":["<optional option>"],"context":"<optional context>"}
            \(Self.clarificationEndMarker)

            When complete, emit exactly one block:
            \(Self.completeTaskStartMarker)
            {"summary":"<what you completed>","success":true,"artifact":"<optional markdown artifact content>"}
            \(Self.completeTaskEndMarker)

            Optional additional artifacts can be emitted as:
            ---GENERATED_ARTIFACT_START---
            {"filename":"notes.md","content_type":"markdown"}
            <artifact content>
            ---GENERATED_ARTIFACT_END---
            """
        )
        return sections.joined(separator: "\n\n")
    }

    private static func normalizedPromptComparisonText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func sanitizeOpenClawVisibleResponse(_ raw: String) -> String {
        var cleaned = raw
        if let markerRange = cleaned.range(of: "\nSystem:\n") {
            cleaned = String(cleaned[..<markerRange.lowerBound])
        } else if cleaned.hasPrefix("System:\n") {
            cleaned = ""
        }
        cleaned = Self.stripTaggedBlocks(
            from: cleaned,
            startMarker: Self.clarificationStartMarker,
            endMarker: Self.clarificationEndMarker
        )
        cleaned = Self.stripTaggedBlocks(
            from: cleaned,
            startMarker: Self.completeTaskStartMarker,
            endMarker: Self.completeTaskEndMarker
        )
        cleaned = Self.stripTaggedBlocks(
            from: cleaned,
            startMarker: Self.generatedArtifactStartMarker,
            endMarker: Self.generatedArtifactEndMarker
        )
        return cleaned
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTaggedBlocks(
        from text: String,
        startMarker: String,
        endMarker: String
    ) -> String {
        var output = text
        while let startRange = output.range(of: startMarker),
            let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        {
            output.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return output
    }

    private static func extractLastJSONBlock(
        from text: String,
        startMarker: String,
        endMarker: String
    ) -> String? {
        var cursor = text.startIndex
        var payload: String?

        while cursor < text.endIndex,
            let start = text.range(of: startMarker, range: cursor..<text.endIndex),
            let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        {
            let candidate = String(text[start.upperBound..<end.lowerBound])
            let normalized = Self.normalizeJSONBlock(candidate)
            if !normalized.isEmpty {
                payload = normalized
            }
            cursor = end.upperBound
        }

        return payload
    }

    private static func normalizeJSONBlock(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let firstNewline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: firstNewline)...])
            }
            if let closingFence = value.range(of: "```", options: .backwards) {
                value = String(value[..<closingFence.lowerBound])
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func parseGeneratedArtifacts(from response: String, taskId: String) -> [Artifact] {
        var artifacts: [Artifact] = []
        var cursor = response.startIndex

        while cursor < response.endIndex,
            let start = response.range(of: Self.generatedArtifactStartMarker, range: cursor..<response.endIndex),
            let end = response.range(of: Self.generatedArtifactEndMarker, range: start.upperBound..<response.endIndex)
        {
            let block = String(response[start.lowerBound..<end.upperBound])
            if let artifact = Self.parseGeneratedArtifact(from: block, taskId: taskId) {
                artifacts.append(artifact)
            }
            cursor = end.upperBound
        }

        return artifacts
    }

    private func importOpenClawWorkspaceArtifacts(taskId: String) async -> [Artifact] {
        let workspaceFiles = await openClawWorkspaceFilesLoader()
        if workspaceFiles.isEmpty {
            return []
        }

        let sortedFiles = workspaceFiles
            .filter { !$0.missing }
            .sorted { lhs, rhs in
                let l = lhs.updatedAtMs ?? 0
                let r = rhs.updatedAtMs ?? 0
                if l == r {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return l > r
            }

        var artifacts: [Artifact] = []
        var dedupeKeys = Set<String>()

        for file in sortedFiles.prefix(Self.maxWorkspaceFilesToImport) {
            let fileName = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isIngestibleWorkspaceFile(filename: fileName),
                let content = file.content?.trimmingCharacters(in: .newlines),
                !content.isEmpty,
                content.count <= Self.maxWorkspaceArtifactCharacters
            else {
                continue
            }

            let dedupeKey = "\(fileName.lowercased())::\(content)"
            guard !dedupeKeys.contains(dedupeKey) else { continue }
            dedupeKeys.insert(dedupeKey)

            artifacts.append(
                Artifact(
                    taskId: taskId,
                    filename: fileName,
                    content: content,
                    contentType: Artifact.contentType(from: fileName),
                    isFinalResult: false
                )
            )
        }

        return artifacts
    }

    private static func isIngestibleWorkspaceFile(filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if lowered == "bootstrap.md" || lowered.hasPrefix(".") {
            return false
        }

        if lowered == "readme" || lowered == "readme.md" || lowered == "memory.md" {
            return true
        }

        let ext = (trimmed as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt", "json", "yaml", "yml", "log"].contains(ext)
    }

    private static func isPreferredWorkspaceFinalArtifact(filename: String) -> Bool {
        let lowered = filename.lowercased()
        return lowered == "readme.md"
            || lowered == "readme.markdown"
            || lowered == "result.md"
            || lowered == "summary.md"
    }

    private static func defaultOpenClawWorkspaceFilesLoader() async -> [OpenClawAgentWorkspaceFile] {
        let manager = await MainActor.run { OpenClawManager.shared }
        let connected = await MainActor.run { manager.isConnected }
        guard connected else { return [] }

        do {
            let listing = try await manager.listAgentWorkspaceFiles()
            var loaded: [OpenClawAgentWorkspaceFile] = []

            for file in listing.files.prefix(Self.maxWorkspaceFilesToImport) {
                guard !file.missing else { continue }
                guard Self.isIngestibleWorkspaceFile(filename: file.name) else { continue }
                if let content = file.content {
                    loaded.append(
                        OpenClawAgentWorkspaceFile(
                            name: file.name,
                            path: file.path,
                            missing: file.missing,
                            size: file.size,
                            updatedAtMs: file.updatedAtMs,
                            content: content
                        )
                    )
                    continue
                }
                do {
                    let hydrated = try await manager.readAgentWorkspaceFile(name: file.name)
                    loaded.append(hydrated)
                } catch {
                    continue
                }
            }

            return loaded
        } catch {
            return []
        }
    }

    private struct OpenClawOutputFilter {
        private static let systemTraceMarkers = ["\nSystem:\n", "System:\n"]
        private static let systemTracePartials: [String] = {
            var partials = Set<String>()
            for marker in systemTraceMarkers {
                for length in 1 ..< marker.count {
                    partials.insert(String(marker.prefix(length)))
                }
            }
            return partials.sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs < rhs
                }
                return lhs.count > rhs.count
            }
        }()

        /// Strips ---MARKER_START--- ... ---MARKER_END--- control blocks from the stream.
        private var controlBlockFilter = OpenClawControlBlockStreamFilter()
        private var inSystemTrace = false
        private var systemBoundaryBuffer = ""

        mutating func consume(_ chunk: String) -> String {
            guard !chunk.isEmpty else { return "" }

            // First pass: strip ---MARKER--- control blocks before any further processing.
            let afterBlocks = controlBlockFilter.consume(chunk)
            guard !afterBlocks.isEmpty else { return "" }

            // Second pass: suppress everything from the System: trace boundary onward.
            if inSystemTrace {
                return ""
            }

            let combined = systemBoundaryBuffer + afterBlocks
            systemBoundaryBuffer = ""

            if let markerRange = firstSystemMarkerRange(in: combined) {
                let content = String(combined[..<markerRange.lowerBound])
                inSystemTrace = true
                return content
            }

            if let partial = Self.systemTracePartials.first(where: { combined.hasSuffix($0) }) {
                let flush = String(combined.dropLast(partial.count))
                systemBoundaryBuffer = partial
                return flush
            }

            return combined
        }

        private func firstSystemMarkerRange(in text: String) -> Range<String.Index>? {
            var earliest: Range<String.Index>?
            for marker in Self.systemTraceMarkers {
                guard let range = text.range(of: marker) else { continue }
                if let current = earliest {
                    if range.lowerBound < current.lowerBound {
                        earliest = range
                    }
                } else {
                    earliest = range
                }
            }
            return earliest
        }

        mutating func finalize() -> String {
            let blockTail = controlBlockFilter.finalize()
            guard !inSystemTrace else {
                systemBoundaryBuffer = ""
                return ""
            }
            let tail = systemBoundaryBuffer + blockTail
            systemBoundaryBuffer = ""
            return tail
        }
    }

    /// Parses generate_artifact tool result to extract the artifact
    private static func parseGeneratedArtifact(from result: String, taskId: String) -> Artifact? {
        guard let startRange = result.range(of: Self.generatedArtifactStartMarker),
            let endRange = result.range(of: Self.generatedArtifactEndMarker, range: startRange.upperBound..<result.endIndex)
        else {
            return nil
        }

        var fullContent = String(result[startRange.upperBound ..< endRange.lowerBound])
        fullContent = fullContent.trimmingCharacters(in: .newlines)

        // First line is JSON metadata, rest is content
        let lines = fullContent.components(separatedBy: "\n")
        guard lines.count >= 2, let metadataLine = lines.first else {
            return nil
        }

        // Parse metadata
        guard let metadataData = metadataLine.data(using: .utf8),
            let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: String],
            let filename = metadata["filename"]
        else {
            return nil
        }

        let contentType = metadata["content_type"].flatMap { ArtifactContentType(rawValue: $0) } ?? .text
        let content = lines.dropFirst().joined(separator: "\n")

        guard !content.isEmpty else { return nil }

        return Artifact(
            taskId: taskId,
            filename: filename,
            content: content,
            contentType: contentType,
            isFinalResult: false
        )
    }

    /// Builds the work system prompt for reasoning loop execution
    /// - Parameters:
    ///   - base: Base system prompt (agent instructions, etc.)
    ///   - issue: The issue being executed
    ///   - tools: Available tools
    ///   - folderContext: Optional folder context for file operations
    ///   - skillInstructions: Optional skill-specific instructions
    /// - Returns: Complete system prompt for work mode
    func buildAgentSystemPrompt(
        base: String,
        issue: Issue,
        tools: [Tool],
        folderContext: WorkFolderContext? = nil,
        skillInstructions: String? = nil
    ) -> String {
        var prompt = base

        prompt += """


            # Work Mode

            You are executing a task for the user. Your goal:

            **\(issue.title)**
            \(issue.description ?? "")

            ## How to Work

            - You have tools available. Use them to accomplish the goal.
            - Work step by step. After each tool call, assess what you learned and decide the next action.
            - You do NOT need to plan everything upfront. Explore, read, understand, then act.
            - If you discover additional work needed, use `create_issue` to track it.
            - When the task is complete, use `complete_task` with a summary of what you accomplished.
            - If the task is ambiguous and you cannot make a reasonable assumption, use `request_clarification`.

            ## Important Guidelines

            - Always read/explore before modifying. Don't guess at file contents or project structure.
            - For coding tasks: write code, then verify it works if possible.
            - If something fails, analyze the error and try a different approach. Don't repeat the same action.
            - Keep the user's original request in mind at all times. Every action should serve the goal.
            - When creating follow-up issues, write detailed descriptions with full context about what you learned.

            ## Communication Style

            - Before calling tools, briefly explain what you are about to do and why.
            - After receiving tool results, summarize what you learned before proceeding.
            - Use concise natural language (not code or JSON) when explaining your actions.
            - The user sees your text responses in real time, so keep them informed of progress.

            ## Completion

            When the goal is fully achieved, call `complete_task` with:
            - A summary of what was accomplished
            - Any artifacts produced (optional)

            Do NOT call complete_task until you have actually done the work and verified it.

            """

        // Add folder context if available
        if let folder = folderContext {
            prompt += buildFolderContextSection(from: folder)
        }

        // Add skill instructions if available
        if let skills = skillInstructions, !skills.isEmpty {
            prompt += "\n## Active Skills\n\(skills)\n"
        }

        return prompt
    }

    /// Checks if the response signals task completion (without using complete_task tool)
    private static func isCompletionSignal(_ content: String) -> Bool {
        let upperContent = content.uppercased()
        // Look for explicit completion markers
        let completionPhrases = [
            "TASK_COMPLETE",
            "TASK COMPLETE",
            "I HAVE COMPLETED",
            "THE TASK IS COMPLETE",
            "THE TASK HAS BEEN COMPLETED",
            "ALL DONE",
            "FINISHED SUCCESSFULLY",
        ]
        return completionPhrases.contains { upperContent.contains($0) }
    }

    /// Extracts a completion summary from a text response
    private static func extractCompletionSummary(from content: String) -> String {
        // Try to find a summary section
        let lines = content.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        var inSummary = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().contains("SUMMARY") || trimmed.uppercased().contains("COMPLETED") {
                inSummary = true
            }
            if inSummary && !trimmed.isEmpty {
                summaryLines.append(trimmed)
            }
        }

        if summaryLines.isEmpty {
            // Just use the whole content, truncated
            return String(content.prefix(500))
        }
        return summaryLines.joined(separator: "\n")
    }

    /// Parses complete_task tool arguments
    private static func parseCompleteTaskArgs(_ jsonArgs: String, taskId: String) -> (String, Artifact?) {
        struct CompleteTaskArgs: Decodable {
            let summary: String
            let success: Bool?
            let artifact: String?
            let remaining_work: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(CompleteTaskArgs.self, from: data)
        else {
            return ("Task completed", nil)
        }

        var artifact: Artifact? = nil
        if let rawContent = args.artifact, !rawContent.isEmpty {
            // Unescape literal \n and \t sequences that models sometimes send
            let content =
                rawContent
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")

            artifact = Artifact(
                taskId: taskId,
                filename: "result.md",
                content: content,
                contentType: .markdown,
                isFinalResult: true
            )
        }

        return (args.summary, artifact)
    }

    /// Parses request_clarification tool arguments
    private static func parseClarificationArgs(_ jsonArgs: String) -> ClarificationRequest {
        struct ClarificationArgs: Decodable {
            let question: String
            let options: [String]?
            let context: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(ClarificationArgs.self, from: data)
        else {
            return ClarificationRequest(question: "Could you please clarify your request?")
        }

        return ClarificationRequest(
            question: args.question,
            options: args.options,
            context: args.context
        )
    }

}

// MARK: - Supporting Types

/// Result of a tool call
public struct ToolCallResult: Sendable {
    public let toolCall: ToolCall
    public let result: String
}

// MARK: - Errors

/// Errors that can occur during work execution
public enum WorkExecutionError: Error, LocalizedError {
    case executionCancelled
    case iterationLimitReached(Int)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case toolExecutionFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .executionCancelled:
            return "Execution was cancelled"
        case .iterationLimitReached(let count):
            return "Iteration limit reached after \(count) iterations"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .toolExecutionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        case .toolExecutionFailed:
            return true
        case .executionCancelled, .iterationLimitReached:
            return false
        case .unknown:
            return true
        }
    }
}
