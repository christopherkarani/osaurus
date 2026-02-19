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
}
