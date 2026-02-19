//
//  OpenClawGatewayConnectionPhase1Tests.swift
//  osaurusTests
//

import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawGatewayCallRecorder {
    struct Call: Sendable {
        let method: String
        let params: [String: OpenClawProtocol.AnyCodable]?
    }

    private var calls: [Call] = []

    func record(method: String, params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append(Call(method: method, params: params))
    }

    func last() -> Call? {
        calls.last
    }
}

private actor OpenClawGatewayEventBox {
    private var frame: EventFrame?

    func store(_ frame: EventFrame) {
        self.frame = frame
    }

    func get() -> EventFrame? {
        frame
    }
}

struct OpenClawGatewayConnectionPhase1Tests {

    @Test
    func chatSend_encodesParamsAndDecodesResponse() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            let payload: [String: Any] = [
                "runId": "client-run-1",
                "status": "started"
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let response = try await connection.chatSend(
            message: "hello",
            sessionKey: "main",
            clientRunId: "client-run-1"
        )

        let call = try #require(await recorder.last())
        #expect(call.method == "chat.send")
        #expect(call.params?["sessionKey"]?.value as? String == "main")
        #expect(call.params?["message"]?.value as? String == "hello")
        #expect(call.params?["idempotencyKey"]?.value as? String == "client-run-1")
        #expect(response.runId == "client-run-1")
        #expect(response.status == "started")
    }

    @Test
    func sessionsList_passesPhase1FlagsAndParsesRows() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            let payload: [String: Any] = [
                "ts": 1700,
                "path": "/tmp/sessions.json",
                "count": 1,
                "sessions": [
                    [
                        "key": "agent:main:test",
                        "displayName": "Test Session",
                        "derivedTitle": "Derived Title",
                        "lastMessagePreview": "last message",
                        "updatedAt": 1700,
                        "model": "claude-opus"
                    ]
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let sessions = try await connection.sessionsList(
            limit: 25,
            includeTitles: true,
            includeLastMessage: true,
            includeGlobal: false,
            includeUnknown: false
        )

        let call = try #require(await recorder.last())
        #expect(call.method == "sessions.list")
        #expect(call.params?["limit"]?.value as? Int == 25)
        #expect(call.params?["includeDerivedTitles"]?.value as? Bool == true)
        #expect(call.params?["includeLastMessage"]?.value as? Bool == true)
        #expect(call.params?["includeGlobal"]?.value as? Bool == false)
        #expect(call.params?["includeUnknown"]?.value as? Bool == false)

        #expect(sessions.count == 1)
        #expect(sessions.first?.key == "agent:main:test")
        #expect(sessions.first?.derivedTitle == "Derived Title")
        #expect(sessions.first?.lastMessagePreview == "last message")
    }

    @Test
    func sessionsCreate_usesPatchAndReturnsResolvedKey() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            let payload: [String: Any] = [
                "ok": true,
                "key": "agent:main:new-session"
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let key = try await connection.sessionsCreate(model: "claude-opus")
        let call = try #require(await recorder.last())

        #expect(call.method == "sessions.patch")
        #expect(call.params?["model"]?.value as? String == "claude-opus")
        #expect(key == "agent:main:new-session")
    }

    @Test
    func subscribeToEvents_filtersByRunId() async throws {
        let connection = OpenClawGatewayConnection()
        let eventBox = OpenClawGatewayEventBox()
        let stream = await connection.subscribeToEvents(runId: "target-run")

        let consumer = Task {
            for await frame in stream {
                await eventBox.store(frame)
                break
            }
        }

        let otherRunFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "other-run",
                "seq": 1,
                "state": "delta",
                "message": ["role": "assistant", "content": [["type": "text", "text": "ignored"]]]
            ],
            seq: 1
        )
        await connection._testEmitPush(.event(otherRunFrame))

        let targetRunFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "target-run",
                "seq": 2,
                "state": "delta",
                "message": ["role": "assistant", "content": [["type": "text", "text": "kept"]]]
            ],
            seq: 2
        )
        await connection._testEmitPush(.event(targetRunFrame))

        try? await Task.sleep(nanoseconds: 150_000_000)
        let matched = await eventBox.get()
        consumer.cancel()

        #expect(matched?.seq == 2)
        if let payload = matched?.payload?.value as? [String: OpenClawProtocol.AnyCodable] {
            #expect(payload["runId"]?.value as? String == "target-run")
        } else {
            Issue.record("Expected payload dictionary on matched event frame")
        }
    }

    @Test
    func subscribeToEvents_replaysBufferedFramesForRunId() async throws {
        let connection = OpenClawGatewayConnection()

        let earlyFrame = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "buffered-run",
                "seq": 1,
                "state": "delta",
                "message": ["role": "assistant", "content": [["type": "text", "text": "early"]]]
            ],
            seq: 1
        )
        await connection._testEmitPush(.event(earlyFrame))

        let stream = await connection.subscribeToEvents(runId: "buffered-run")

        var matched: EventFrame?
        for await frame in stream {
            matched = frame
            break
        }

        #expect(matched?.seq == 1)
        if let payload = matched?.payload?.value as? [String: OpenClawProtocol.AnyCodable] {
            #expect(payload["runId"]?.value as? String == "buffered-run")
        } else {
            Issue.record("Expected payload dictionary on buffered event frame")
        }
    }

    @Test
    func announcePresence_postsSystemEvent() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            return try JSONSerialization.data(withJSONObject: ["ok": true])
        }

        try await connection.announcePresence()

        let call = try #require(await recorder.last())
        #expect(call.method == "system-event")
        #expect(call.params?["text"]?.value as? String == "Node: Osaurus")
        #expect(call.params?["platform"]?.value as? String == "macos")
        #expect((call.params?["roles"]?.value as? [String])?.contains("chat-client") == true)
    }
}
