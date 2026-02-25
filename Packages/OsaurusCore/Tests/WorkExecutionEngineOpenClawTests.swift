//
//  WorkExecutionEngineOpenClawTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

private actor StreamRequestRecorder {
    private var requests: [ChatCompletionRequest] = []

    func append(_ request: ChatCompletionRequest) {
        requests.append(request)
    }

    func all() -> [ChatCompletionRequest] {
        requests
    }
}

private struct StubWorkChatEngine: ChatEngineProtocol {
    let deltas: [String]
    let recorder: StreamRequestRecorder

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        await recorder.append(request)
        let chunks = deltas
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "chatcmpl-test",
            created: Int(Date().timeIntervalSince1970),
            model: "stub",
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: "stub"),
                    finish_reason: "stop"
                )
            ],
            usage: Usage(prompt_tokens: 1, completion_tokens: 1, total_tokens: 2),
            system_fingerprint: nil
        )
    }
}

private struct OpenClawBackedWorkChatEngine: ChatEngineProtocol {
    let service: OpenClawModelService
    let recorder: StreamRequestRecorder

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        await recorder.append(request)
        let parameters = GenerationParameters(
            temperature: request.temperature,
            maxTokens: request.max_tokens ?? 4096,
            topPOverride: request.top_p,
            repetitionPenalty: nil
        )
        return try await service.streamDeltas(
            messages: request.messages,
            parameters: parameters,
            requestedModel: request.model,
            stopSequences: request.stop ?? []
        )
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "WorkExecutionEngineOpenClawTests", code: -1)
    }
}

@MainActor
struct WorkExecutionEngineOpenClawTests {
    private actor TaskResultBox<T: Sendable> {
        private var result: Result<T, Error>?

        func set(_ result: Result<T, Error>) {
            self.result = result
        }

        func get() -> Result<T, Error>? {
            result
        }
    }

    private func waitForRequestCount(
        _ minimumCount: Int,
        recorder: StreamRequestRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await recorder.all().count >= minimumCount {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await recorder.all().count >= minimumCount
    }

    private func awaitTaskResult<T: Sendable>(
        _ task: Task<T, Error>,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000
    ) async throws -> T {
        let box = TaskResultBox<T>()
        Task {
            do {
                await box.set(.success(try await task.value))
            } catch {
                await box.set(.failure(error))
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let result = await box.get() {
                return try result.get()
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        task.cancel()
        throw CancellationError()
    }

    @Test
    func executeLoop_openClawRuntime_usesGatewaySinglePass() async throws {
        let recorder = StreamRequestRecorder()
        let engine = WorkExecutionEngine(
            chatEngine: StubWorkChatEngine(
                deltas: ["Investigating… ", "Done. SUMMARY: fixed."],
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "Fix the failing task")]
        let issue = Issue(taskId: "task-1", title: "Fix failing task", description: "Investigate and repair")

        var iterations: [Int] = []
        var toolCallCount = 0
        var streamed = ""

        let result = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "You are a test worker.",
            model: "openclaw:session-1",
            tools: [],
            toolOverrides: nil,
            onIterationStart: { iteration in
                iterations.append(iteration)
            },
            onDelta: { delta, _ in
                streamed += delta
            },
            onToolCall: { _, _, _ in
                toolCallCount += 1
            },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        switch result {
        case .completed(let summary, _):
            #expect(summary.contains("SUMMARY"))
        default:
            Issue.record("Expected completed loop result for OpenClaw runtime model")
        }

        #expect(iterations == [1])
        #expect(toolCallCount == 0)
        #expect(streamed.contains("Investigating"))

        let requests = await recorder.all()
        #expect(requests.count == 1)
        #expect(requests.first?.model == "openclaw:session-1")
        let prompt = requests.first?.messages.first?.content ?? ""
        #expect(prompt.contains("System instructions"))
        #expect(prompt.contains("Fix failing task"))
    }

    @Test
    func executeLoop_openClawPreSessionIdentifier_rejected() async throws {
        let recorder = StreamRequestRecorder()
        let engine = WorkExecutionEngine(
            chatEngine: StubWorkChatEngine(
                deltas: ["unused"],
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "Hello")]
        let issue = Issue(taskId: "task-2", title: "Task")

        do {
            _ = try await engine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: "System",
                model: "openclaw-model:test",
                tools: [],
                toolOverrides: nil,
                onIterationStart: { _ in },
                onDelta: { _, _ in },
                onToolCall: { _, _, _ in },
                onStatusUpdate: { _ in },
                onArtifact: { _ in },
                onTokensConsumed: { _, _ in }
            )
            Issue.record("Expected pre-session OpenClaw identifier to be rejected")
        } catch {
            #expect(error.localizedDescription.contains("runtime session model identifiers"))
        }

        let requests = await recorder.all()
        #expect(requests.isEmpty)
    }

    @Test
    func executeLoop_openClawRuntime_cumulativeSnapshots_noDuplicateStreaming_endToEnd() async throws {
        let recorder = StreamRequestRecorder()
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try JSONSerialization.data(withJSONObject: ["runId": "run-work-e2e", "status": "started"])
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let engine = WorkExecutionEngine(
            chatEngine: OpenClawBackedWorkChatEngine(
                service: service,
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "hello")]
        let issue = Issue(taskId: "task-3", title: "Task")
        var streamed = ""
        let executeTask = Task {
            try await engine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: "System",
                model: "openclaw:session-1",
                tools: [],
                toolOverrides: nil,
                onIterationStart: { _ in },
                onDelta: { delta, _ in
                    streamed += delta
                },
                onToolCall: { _, _, _ in },
                onStatusUpdate: { _ in },
                onArtifact: { _ in },
                onTokensConsumed: { _, _ in }
            )
        }

        let requestObserved = await waitForRequestCount(1, recorder: recorder)
        #expect(requestObserved)

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-e2e",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello"]]
                        ]
                    ],
                    seq: 1
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-e2e",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello"]]
                        ]
                    ],
                    seq: 2
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-e2e",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello there"]]
                        ]
                    ],
                    seq: 3
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-e2e",
                        "state": "final"
                    ],
                    seq: 4
                )
            )
        )

        let result = try await executeTask.value
        switch result {
        case .completed:
            break
        default:
            Issue.record("Expected completed loop result")
        }
        #expect(streamed == "Hello there")
    }

    @Test
    func executeLoop_openClawRuntime_mixedChatFinalAndAgentAssistant_keepsUpdatingChatStream_whenLifecycleStarted() async throws {
        let recorder = StreamRequestRecorder()
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try JSONSerialization.data(withJSONObject: ["runId": "run-work-mixed", "status": "started"])
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let engine = WorkExecutionEngine(
            chatEngine: OpenClawBackedWorkChatEngine(
                service: service,
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "deep research")]
        let issue = Issue(taskId: "task-4", title: "Task")
        var streamed = ""
        let executeTask = Task {
            try await engine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: "System",
                model: "openclaw:session-1",
                tools: [],
                toolOverrides: nil,
                onIterationStart: { _ in },
                onDelta: { delta, _ in
                    streamed += delta
                },
                onToolCall: { _, _, _ in },
                onStatusUpdate: { _ in },
                onArtifact: { _ in },
                onTokensConsumed: { _, _ in }
            )
        }

        let requestObserved = await waitForRequestCount(1, recorder: recorder)
        #expect(requestObserved)

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-work-mixed",
                    seq: 1,
                    data: ["phase": "start"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-work-mixed",
                    seq: 2,
                    data: ["text": "I'll conduct deep research"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-mixed",
                        "state": "final"
                    ],
                    seq: 3
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-work-mixed",
                    seq: 4,
                    data: ["text": "I'll conduct deep research and share findings."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-work-mixed",
                    seq: 5,
                    data: ["phase": "end"]
                )
            )
        )

        let result = try await executeTask.value
        switch result {
        case .completed:
            break
        default:
            Issue.record("Expected completed loop result")
        }
        #expect(streamed == "I'll conduct deep research and share findings.")
    }

    @Test
    func executeLoop_openClawRuntime_finalMessageOnly_stillUpdatesChatStream() async throws {
        let recorder = StreamRequestRecorder()
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try JSONSerialization.data(withJSONObject: ["runId": "run-work-final-only", "status": "started"])
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let engine = WorkExecutionEngine(
            chatEngine: OpenClawBackedWorkChatEngine(
                service: service,
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "quick reply")]
        let issue = Issue(taskId: "task-5", title: "Task")
        var streamed = ""
        let executeTask = Task {
            try await engine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: "System",
                model: "openclaw:session-1",
                tools: [],
                toolOverrides: nil,
                onIterationStart: { _ in },
                onDelta: { delta, _ in
                    streamed += delta
                },
                onToolCall: { _, _, _ in },
                onStatusUpdate: { _ in },
                onArtifact: { _ in },
                onTokensConsumed: { _, _ in }
            )
        }

        let requestObserved = await waitForRequestCount(1, recorder: recorder)
        #expect(requestObserved)

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-final-only",
                        "state": "final",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Final-only work response"]]
                        ]
                    ],
                    seq: 1
                )
            )
        )

        let result = try await executeTask.value
        switch result {
        case .completed:
            break
        default:
            Issue.record("Expected completed loop result")
        }
        #expect(streamed == "Final-only work response")
    }

    @Test
    func executeLoop_openClawRuntime_agentWhitespaceDeltas_renderWithSpacingAndCompleteWithoutLifecycle() async throws {
        let recorder = StreamRequestRecorder()
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try JSONSerialization.data(withJSONObject: ["runId": "run-work-whitespace", "status": "started"])
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let engine = WorkExecutionEngine(
            chatEngine: OpenClawBackedWorkChatEngine(
                service: service,
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "who is cristiano ronaldo")]
        let issue = Issue(taskId: "task-6", title: "Task")
        var streamed = ""
        let executeTask = Task {
            try await engine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: "System",
                model: "openclaw:session-1",
                tools: [],
                toolOverrides: nil,
                onIterationStart: { _ in },
                onDelta: { delta, _ in
                    streamed += delta
                },
                onToolCall: { _, _, _ in },
                onStatusUpdate: { _ in },
                onArtifact: { _ in },
                onTokensConsumed: { _, _ in }
            )
        }

        let requestObserved = await waitForRequestCount(1, recorder: recorder)
        #expect(requestObserved)

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-work-whitespace",
                    seq: 1,
                    data: ["delta": "Cristiano Ronaldo is a Portuguese footballer."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-work-whitespace",
                    seq: 2,
                    data: ["delta": "\n\nHe currently plays for Al Nassr."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-work-whitespace",
                        "state": "final"
                    ],
                    seq: 3
                )
            )
        )

        let result = try await awaitTaskResult(executeTask)
        switch result {
        case .completed:
            break
        default:
            Issue.record("Expected completed loop result")
        }
        #expect(
            streamed
                == "Cristiano Ronaldo is a Portuguese footballer.\n\nHe currently plays for Al Nassr."
        )
    }

    @Test
    func executeLoop_openClawRuntime_systemTraceAtStart_isNotStreamed() async throws {
        let recorder = StreamRequestRecorder()
        let engine = WorkExecutionEngine(
            chatEngine: StubWorkChatEngine(
                deltas: [
                    "Sys",
                    "tem:\n# Task Execution Trace\n- step 1",
                ],
                recorder: recorder
            )
        )

        var messages = [ChatMessage(role: "user", content: "Summarize the result")]
        let issue = Issue(taskId: "task-7", title: "Task")
        var streamed = ""

        let result = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "System",
            model: "openclaw:session-1",
            tools: [],
            toolOverrides: nil,
            onIterationStart: { _ in },
            onDelta: { delta, _ in
                streamed += delta
            },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        switch result {
        case .completed(let summary, let artifact):
            #expect(summary == "OpenClaw run completed.")
            #expect(artifact == nil)
        default:
            Issue.record("Expected completed loop result")
        }
        #expect(streamed.isEmpty)
    }
}
