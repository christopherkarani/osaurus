//
//  OpenClawModelServiceTests.swift
//  osaurusTests
//

import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawModelServiceCallRecorder {
    struct Call: Sendable {
        let method: String
        let params: [String: OpenClawProtocol.AnyCodable]?
    }

    private var calls: [Call] = []

    func append(method: String, params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append(Call(method: method, params: params))
    }

    func all() -> [Call] {
        calls
    }

    func contains(method: String) -> Bool {
        calls.contains { $0.method == method }
    }
}

private func encodeJSONObject(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

struct OpenClawModelServiceTests {
    private let params = GenerationParameters(
        temperature: nil,
        maxTokens: 1024,
        topPOverride: nil,
        repetitionPenalty: nil
    )

    private func waitForCall(
        _ method: String,
        recorder: OpenClawModelServiceCallRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await recorder.contains(method: method) {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await recorder.contains(method: method)
    }

    private func waitForCallCount(
        _ method: String,
        minimumCount: Int,
        recorder: OpenClawModelServiceCallRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let count = await recorder.all().filter { $0.method == method }.count
            if count >= minimumCount {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        let finalCount = await recorder.all().filter { $0.method == method }.count
        return finalCount >= minimumCount
    }

    @Test @MainActor
    func handlesOpenClawModelIdentifiers() async throws {
        let connection = OpenClawGatewayConnection()
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        #expect(service.isAvailable() == true)
        #expect(service.handles(requestedModel: "openclaw:session-1") == true)
        #expect(service.handles(requestedModel: "openclaw-model:claude-opus") == true)
        #expect(service.handles(requestedModel: "foundation") == false)
    }

    @Test @MainActor
    func streamDeltas_yieldsChatTextAndFinishes() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-1", "status": "started"])
            }
            return try encodeJSONObject([:])
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Hello there")],
            parameters: params,
            requestedModel: "openclaw:main",
            stopSequences: []
        )

        let consumeTask = Task { () throws -> String in
            var output = ""
            for try await delta in stream {
                output += delta
            }
            return output
        }

        let deltaFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "run-1",
                "state": "delta",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hello back"]
                    ]
                ]
            ],
            seq: 1
        )
        await connection._testEmitPush(.event(deltaFrame))

        let finalFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "run-1",
                "state": "final"
            ],
            seq: 2
        )
        await connection._testEmitPush(.event(finalFrame))

        let output = try await consumeTask.value
        #expect(output == "Hello back")

        let calls = await recorder.all()
        #expect(calls.count == 1)
        #expect(calls.first?.method == "chat.send")
        #expect(calls.first?.params?["sessionKey"]?.value as? String == "main")
    }

    @Test @MainActor
    func streamDeltas_throwsOnChatError() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-2", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Trigger error")],
            parameters: params,
            requestedModel: "openclaw:main",
            stopSequences: []
        )

        let consumeTask = Task { () throws -> String in
            var output = ""
            for try await delta in stream {
                output += delta
            }
            return output
        }

        let errorFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "run-2",
                "state": "error",
                "errorMessage": "boom"
            ],
            seq: 1
        )
        await connection._testEmitPush(.event(errorFrame))

        do {
            _ = try await consumeTask.value
            Issue.record("Expected stream to throw on chat error state")
        } catch {
            #expect(error.localizedDescription.contains("boom"))
        }
    }

    @Test @MainActor
    func streamRunIntoTurn_mapsThinkingToolAndTextEvents() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-3", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let turn = ChatTurn(role: .assistant, content: "")

        let runTask = Task {
            try await service.streamRunIntoTurn(
                messages: [ChatMessage(role: "user", content: "Question")],
                requestedModel: "openclaw:main",
                turn: turn
            )
        }

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "thinking",
                    runId: "run-3",
                    seq: 1,
                    data: ["delta": "let me think"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-3",
                    seq: 2,
                    data: ["text": "answer"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "tool",
                    runId: "run-3",
                    seq: 3,
                    data: [
                        "phase": "start",
                        "toolCallId": "tool-1",
                        "name": "search",
                        "args": ["q": "swift"]
                    ]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "tool",
                    runId: "run-3",
                    seq: 4,
                    data: [
                        "phase": "result",
                        "toolCallId": "tool-1",
                        "result": "done"
                    ]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-3",
                    seq: 5,
                    data: ["phase": "end"]
                )
            )
        )

        try await runTask.value

        #expect(turn.thinking.contains("let me think"))
        #expect(turn.content.contains("answer"))
        #expect(turn.toolCalls?.first?.id == "tool-1")
        #expect(turn.toolResults["tool-1"] == "done")
    }

    @Test @MainActor
    func streamDeltas_rejectsNonSessionIdentifiers() async throws {
        let service = OpenClawModelService(
            connection: OpenClawGatewayConnection(),
            availabilityProvider: { true }
        )

        do {
            _ = try await service.streamDeltas(
                messages: [ChatMessage(role: "user", content: "Hi")],
                parameters: params,
                requestedModel: "openclaw-model:claude-opus",
                stopSequences: []
            )
            Issue.record("Expected unsupported model identifier error")
        } catch {
            #expect(error.localizedDescription.contains("Unsupported OpenClaw model identifier"))
        }
    }

    @Test @MainActor
    func streamRunIntoTurn_sequenceGapTriggersConnectionRefresh() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-gap", "status": "started"])
            case "agent.wait":
                return try encodeJSONObject(["runId": "run-gap", "status": "timeout"])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let turn = ChatTurn(role: .assistant, content: "")

        let runTask = Task {
            try await service.streamRunIntoTurn(
                messages: [ChatMessage(role: "user", content: "Question with sequence gap")],
                requestedModel: "openclaw:main",
                turn: turn
            )
        }

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-gap",
                    seq: 1,
                    data: ["text": "first"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-gap",
                    seq: 3,
                    data: ["text": "third"]
                )
            )
        )
        let refreshObserved = await waitForCall("agent.wait", recorder: recorder)
        #expect(refreshObserved)

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-gap",
                    seq: 4,
                    data: ["phase": "end"]
                )
            )
        )

        try await runTask.value

        let calls = await recorder.all()
        #expect(calls.contains { $0.method == "agent.wait" })
    }

    @Test @MainActor
    func streamRunIntoTurn_multipleSequenceGapsTriggerRepeatedRefreshes() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-multi-gap", "status": "started"])
            case "agent.wait":
                return try encodeJSONObject(["runId": "run-multi-gap", "status": "timeout"])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let turn = ChatTurn(role: .assistant, content: "")

        let runTask = Task {
            try await service.streamRunIntoTurn(
                messages: [ChatMessage(role: "user", content: "Question with multiple gaps")],
                requestedModel: "openclaw:main",
                turn: turn
            )
        }

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-multi-gap",
                    seq: 1,
                    data: ["text": "first"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-multi-gap",
                    seq: 3,
                    data: ["text": "third"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-multi-gap",
                    seq: 5,
                    data: ["text": "fifth"]
                )
            )
        )

        let observedTwoRefreshes = await waitForCallCount(
            "agent.wait",
            minimumCount: 2,
            recorder: recorder
        )
        #expect(observedTwoRefreshes)

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-multi-gap",
                    seq: 6,
                    data: ["phase": "end"]
                )
            )
        )

        try await runTask.value
    }

    @Test @MainActor
    func streamRunIntoTurn_gapThenImmediateEnd_isDeterministicAcrossIterations() async throws {
        for iteration in 1...10 {
            let runId = "run-gap-stability-\(iteration)"
            let recorder = OpenClawModelServiceCallRecorder()
            let connection = OpenClawGatewayConnection { method, params in
                await recorder.append(method: method, params: params)
                switch method {
                case "chat.send":
                    return try encodeJSONObject(["runId": runId, "status": "started"])
                case "agent.wait":
                    return try encodeJSONObject(["runId": runId, "status": "timeout"])
                default:
                    return try encodeJSONObject([:])
                }
            }

            let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
            let turn = ChatTurn(role: .assistant, content: "")

            let runTask = Task {
                try await service.streamRunIntoTurn(
                    messages: [ChatMessage(role: "user", content: "Immediate end gap test \(iteration)")],
                    requestedModel: "openclaw:main",
                    turn: turn
                )
            }

            await connection._testEmitPush(
                .event(
                    makeAgentEventFrame(
                        stream: "assistant",
                        runId: runId,
                        seq: 1,
                        data: ["text": "first"]
                    )
                )
            )
            await connection._testEmitPush(
                .event(
                    makeAgentEventFrame(
                        stream: "assistant",
                        runId: runId,
                        seq: 3,
                        data: ["text": "gap"]
                    )
                )
            )
            await connection._testEmitPush(
                .event(
                    makeAgentEventFrame(
                        stream: "lifecycle",
                        runId: runId,
                        seq: 4,
                        data: ["phase": "end"]
                    )
                )
            )

            try await runTask.value
            let observedRefresh = await waitForCall("agent.wait", recorder: recorder)
            #expect(observedRefresh)
        }
    }
}
