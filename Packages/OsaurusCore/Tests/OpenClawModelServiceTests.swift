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
    private actor TaskResultBox<T: Sendable> {
        private var result: Result<T, Error>?

        func set(_ result: Result<T, Error>) {
            self.result = result
        }

        func get() -> Result<T, Error>? {
            result
        }
    }

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
    func streamDeltas_normalizesCumulativeChatSnapshots() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-cumulative", "status": "started"])
            }
            return try encodeJSONObject([:])
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "hello")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-cumulative",
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
                        "runId": "run-cumulative",
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
                        "runId": "run-cumulative",
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
                        "runId": "run-cumulative",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello there"]]
                        ]
                    ],
                    seq: 4
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-cumulative",
                        "state": "final"
                    ],
                    seq: 5
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Hello there")
    }

    @Test @MainActor
    func streamDeltas_prefersExplicitDeltaFieldWhenPresent() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-explicit-delta", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "hello")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-explicit-delta",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello", "delta": "Hello"]]
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
                        "runId": "run-explicit-delta",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello there", "delta": " there"]]
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
                        "runId": "run-explicit-delta",
                        "state": "final"
                    ],
                    seq: 3
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Hello there")
    }

    @Test @MainActor
    func streamDeltas_deltaOnlyCumulativeSnapshots_withoutText_doNotDuplicate() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-delta-only-cumulative", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "hello")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-delta-only-cumulative",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "delta": "Hello"]]
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
                        "runId": "run-delta-only-cumulative",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "delta": "Hello"]]
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
                        "runId": "run-delta-only-cumulative",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "delta": "Hello there"]]
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
                        "runId": "run-delta-only-cumulative",
                        "state": "final"
                    ],
                    seq: 4
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Hello there")
    }

    @Test @MainActor
    func streamDeltas_agentAssistantDeltaOnlyCumulativeSnapshots_doNotDuplicate() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-agent-delta-cumulative", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "hello")],
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

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-delta-cumulative",
                    seq: 1,
                    data: ["delta": "Hello"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-delta-cumulative",
                    seq: 2,
                    data: ["delta": "Hello"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-delta-cumulative",
                    seq: 3,
                    data: ["delta": "Hello there"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-agent-delta-cumulative",
                        "state": "final"
                    ],
                    seq: 4
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Hello there")
    }

    @Test @MainActor
    func streamDeltas_nonPrefixRewriteDoesNotCorruptOutput() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-rewrite", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "hello")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-rewrite",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello world"]]
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
                        "runId": "run-rewrite",
                        "state": "delta",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Hello there"]]
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
                        "runId": "run-rewrite",
                        "state": "final"
                    ],
                    seq: 3
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Hello world")
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
    func streamDeltas_chatErrorWithoutMessage_fallsBackToHistoryErrorMessage() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-history-fallback", "status": "started"])
            case "chat.history":
                return try encodeJSONObject([
                    "sessionKey": "main",
                    "messages": [
                        [
                            "role": "assistant",
                            "stopReason": "error",
                            "errorMessage": "401 Invalid Authentication",
                            "content": []
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Trigger auth error")],
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
                "runId": "run-history-fallback",
                "state": "error"
            ],
            seq: 1
        )
        await connection._testEmitPush(.event(errorFrame))

        do {
            _ = try await consumeTask.value
            Issue.record("Expected stream to throw on chat error state")
        } catch {
            #expect(error.localizedDescription.contains("401 Invalid Authentication"))
        }

        let calls = await recorder.all()
        #expect(calls.contains { $0.method == "chat.history" })
    }

    @Test @MainActor
    func streamDeltas_authError_appendsProviderDebugDetailsAndHint() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-auth-debug", "status": "started"])
            case "chat.history":
                return try encodeJSONObject([
                    "sessionKey": "main",
                    "messages": [
                        [
                            "role": "assistant",
                            "stopReason": "error",
                            "errorMessage": "HTTP 401: Invalid Authentication",
                            "content": []
                        ]
                    ]
                ])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "main",
                            "model": "moonshot/kimi-k2.5"
                        ]
                    ]
                ])
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "moonshot": [
                                    "baseUrl": "https://api.moonshot.ai/v1",
                                    "api": "openai-completions",
                                    "apiKey": "__OPENCLAW_REDACTED__",
                                ]
                            ]
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Trigger auth debug")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-auth-debug",
                        "state": "error"
                    ],
                    seq: 1
                )
            )
        )

        do {
            _ = try await consumeTask.value
            Issue.record("Expected stream to throw on chat error state")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401: Invalid Authentication"))
            #expect(error.localizedDescription.contains("auth-debug"))
            #expect(error.localizedDescription.contains("model=moonshot/kimi-k2.5"))
            #expect(error.localizedDescription.contains("provider=moonshot"))
            #expect(error.localizedDescription.contains("baseUrl=https://api.moonshot.ai/v1"))
            #expect(error.localizedDescription.contains("hint=If this key is from Kimi Code"))
        }

        let calls = await recorder.all()
        #expect(calls.contains { $0.method == "chat.history" })
        #expect(calls.contains { $0.method == "sessions.list" })
        #expect(calls.contains { $0.method == "config.get" })
    }

    @Test @MainActor
    func streamDeltas_authError_usesSessionModelProviderWhenModelIsUnqualifiedInList() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-auth-provider", "status": "started"])
            case "chat.history":
                return try encodeJSONObject([
                    "sessionKey": "main",
                    "messages": [
                        [
                            "role": "assistant",
                            "stopReason": "error",
                            "errorMessage": "HTTP 401: Invalid Authentication",
                            "content": []
                        ]
                    ]
                ])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "main",
                            "modelProvider": "kimi-coding",
                            "model": "k2p5"
                        ]
                    ]
                ])
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "kimi-coding": [
                                    "baseUrl": "https://api.kimi.com/coding",
                                    "api": "anthropic-messages",
                                    "apiKey": "__OPENCLAW_REDACTED__",
                                ]
                            ]
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Trigger auth debug provider")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-auth-provider",
                        "state": "error"
                    ],
                    seq: 1
                )
            )
        )

        do {
            _ = try await consumeTask.value
            Issue.record("Expected stream to throw on chat error state")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401: Invalid Authentication"))
            #expect(error.localizedDescription.contains("model=kimi-coding/k2p5"))
            #expect(error.localizedDescription.contains("provider=kimi-coding"))
            #expect(error.localizedDescription.contains("Session model is unqualified") == false)
        }
    }

    @Test @MainActor
    func streamDeltas_authError_kimiCodingThinkingModel_appendsK2p5Hint() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-auth-kimi-thinking", "status": "started"])
            case "chat.history":
                return try encodeJSONObject([
                    "sessionKey": "main",
                    "messages": [
                        [
                            "role": "assistant",
                            "stopReason": "error",
                            "errorMessage": "HTTP 401: Invalid Authentication",
                            "content": []
                        ]
                    ]
                ])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "main",
                            "modelProvider": "kimi-coding",
                            "model": "kimi-k2-thinking"
                        ]
                    ]
                ])
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "kimi-coding": [
                                    "baseUrl": "https://api.kimi.com/coding",
                                    "api": "anthropic-messages",
                                    "apiKey": "__OPENCLAW_REDACTED__",
                                ]
                            ]
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }

        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Trigger auth debug kimi thinking")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-auth-kimi-thinking",
                        "state": "error"
                    ],
                    seq: 1
                )
            )
        )

        do {
            _ = try await consumeTask.value
            Issue.record("Expected stream to throw on chat error state")
        } catch {
            #expect(error.localizedDescription.contains("model=kimi-coding/kimi-k2-thinking"))
            #expect(error.localizedDescription.contains("hint=For Kimi Coding keys, prefer model `kimi-coding/k2p5`"))
        }
    }

    @Test @MainActor
    func streamDeltas_acceptsEventMetaRunIdAndChannel() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-meta", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "Meta route")],
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
            event: "runtime.stream",
            payload: [
                "state": "delta",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "meta text"]]
                ]
            ],
            seq: 1,
            eventMeta: [
                "schemaVersion": 1,
                "channel": "chat",
                "runId": "run-meta"
            ]
        )
        await connection._testEmitPush(.event(deltaFrame))

        let finalFrame = makeEventFrame(
            event: "runtime.stream",
            payload: [
                "state": "final"
            ],
            seq: 2,
            eventMeta: [
                "schemaVersion": 1,
                "channel": "chat",
                "runId": "run-meta"
            ]
        )
        await connection._testEmitPush(.event(finalFrame))

        let output = try await consumeTask.value
        #expect(output == "meta text")
    }

    @Test @MainActor
    func streamDeltas_keepsStreamingAssistantAfterChatFinalWhenLifecycleStartObserved() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-agent-mixed", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "deep research")],
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

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-agent-mixed",
                    seq: 1,
                    data: ["phase": "start"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-mixed",
                    seq: 2,
                    data: ["text": "I'll research"]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-agent-mixed",
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
                    runId: "run-agent-mixed",
                    seq: 4,
                    data: ["text": "I'll research and summarize."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-agent-mixed",
                    seq: 5,
                    data: ["phase": "end"]
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "I'll research and summarize.")
    }

    @Test @MainActor
    func streamDeltas_emitsFinalMessageTextWhenNoPriorDeltaArrived() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-final-only", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "quick run")],
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

        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-final-only",
                        "state": "final",
                        "message": [
                            "role": "assistant",
                            "content": [["type": "text", "text": "Final-only response"]]
                        ]
                    ],
                    seq: 1
                )
            )
        )

        let output = try await consumeTask.value
        #expect(output == "Final-only response")
    }

    @Test @MainActor
    func streamDeltas_agentAssistantPreservesWhitespaceAndCompletesOnChatFinalWithoutLifecycle() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            if method == "chat.send" {
                return try encodeJSONObject(["runId": "run-agent-whitespace", "status": "started"])
            }
            return try encodeJSONObject([:])
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })

        let stream = try await service.streamDeltas(
            messages: [ChatMessage(role: "user", content: "who is cristiano ronaldo")],
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

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-whitespace",
                    seq: 1,
                    data: ["delta": "I'll help you learn about Cristiano Ronaldo."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-agent-whitespace",
                    seq: 2,
                    data: ["delta": "\n\nBased on public records, he was born in Funchal, Madeira."]
                )
            )
        )
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "chat",
                    payload: [
                        "runId": "run-agent-whitespace",
                        "state": "final"
                    ],
                    seq: 3
                )
            )
        )

        let output = try await awaitTaskResult(consumeTask)
        #expect(
            output
                == "I'll help you learn about Cristiano Ronaldo.\n\nBased on public records, he was born in Funchal, Madeira."
        )
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
    func streamRunIntoTurn_agentLifecycleErrorWithoutMessage_fallsBackToHistoryErrorMessage() async throws {
        let recorder = OpenClawModelServiceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "chat.send":
                return try encodeJSONObject(["runId": "run-turn-error", "status": "started"])
            case "chat.history":
                return try encodeJSONObject([
                    "sessionKey": "main",
                    "messages": [
                        [
                            "role": "assistant",
                            "stopReason": "error",
                            "errorMessage": "401 Invalid Authentication",
                            "content": []
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }
        let service = OpenClawModelService(connection: connection, availabilityProvider: { true })
        let turn = ChatTurn(role: .assistant, content: "")

        let runTask = Task {
            try await service.streamRunIntoTurn(
                messages: [ChatMessage(role: "user", content: "hello")],
                requestedModel: "openclaw:main",
                turn: turn
            )
        }

        await connection._testEmitPush(
            .event(
                makeAgentEventFrame(
                    stream: "lifecycle",
                    runId: "run-turn-error",
                    seq: 1,
                    data: ["phase": "error"]
                )
            )
        )

        do {
            try await runTask.value
            Issue.record("Expected streamRunIntoTurn to throw on lifecycle error phase")
        } catch {
            #expect(error.localizedDescription.contains("401 Invalid Authentication"))
        }

        let calls = await recorder.all()
        #expect(calls.contains { $0.method == "chat.history" })
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
