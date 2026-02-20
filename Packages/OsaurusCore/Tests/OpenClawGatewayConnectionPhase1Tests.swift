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

    func all() -> [Call] {
        calls
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

private actor OpenClawGapReconnectGate {
    private var allowAgentWait = false

    func setAllowAgentWait(_ value: Bool) {
        allowAgentWait = value
    }

    func canAgentWait() -> Bool {
        allowAgentWait
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
        #expect((call.params?["scopes"]?.value as? [String])?.contains("operator.admin") == true)
    }

    @Test
    func channelsStatusDetailed_decodesMetaAndAccountSnapshots() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            let payload: [String: Any] = [
                "channelOrder": ["telegram"],
                "channelLabels": ["telegram": "Telegram"],
                "channelSystemImages": ["telegram": "paperplane.fill"],
                "channelMeta": [
                    [
                        "id": "telegram",
                        "label": "Telegram",
                        "detailLabel": "Bot",
                        "systemImage": "paperplane.fill"
                    ]
                ],
                "channelDefaultAccountId": ["telegram": "acct-1"],
                "channelAccounts": [
                    "telegram": [
                        [
                            "accountId": "acct-1",
                            "name": "Primary",
                            "enabled": true,
                            "configured": true,
                            "linked": true,
                            "running": true,
                            "connected": true,
                            "lastInboundAt": 1_708_345_600_000
                        ]
                    ]
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let result = try await connection.channelsStatusDetailed()
        let summarized = try await connection.channelsStatus()

        let call = try #require(await recorder.last())
        #expect(call.method == "channels.status")
        #expect(result.channelOrder == ["telegram"])
        #expect(result.channelMeta.first?.id == "telegram")
        #expect(result.channelAccounts["telegram"]?.first?.connected == true)
        #expect(result.channelAccounts["telegram"]?.first?.lastInboundAt != nil)

        #expect(summarized.count == 1)
        #expect(summarized.first?["id"]?.value as? String == "telegram")
        #expect(summarized.first?["isLinked"]?.value as? Bool == true)
        #expect(summarized.first?["isConnected"]?.value as? Bool == true)
    }

    @Test
    func wizardStart_andNext_encodeExpectedParams() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "wizard.start":
                let payload: [String: Any] = [
                    "sessionId": "wizard-1",
                    "done": false,
                    "status": "running",
                    "step": [
                        "id": "token-input",
                        "type": "text",
                        "title": "Enter token",
                        "placeholder": "Paste token"
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "wizard.next":
                let payload: [String: Any] = [
                    "done": true,
                    "status": "done"
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "wizard.cancel":
                let payload: [String: Any] = [
                    "status": "cancelled"
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        let start = try await connection.wizardStart(mode: "local", workspace: nil)
        #expect(start.sessionId == "wizard-1")
        #expect(start.step?.id == "token-input")

        let next = try await connection.wizardNext(
            sessionId: start.sessionId,
            stepId: "token-input",
            value: OpenClawProtocol.AnyCodable("abc-token")
        )
        #expect(next.done == true)
        #expect(next.status == .done)

        _ = try await connection.wizardCancel(sessionId: start.sessionId)
        let call = try #require(await recorder.last())
        #expect(call.method == "wizard.cancel")
        #expect(call.params?["sessionId"]?.value as? String == "wizard-1")
    }

    @Test
    func registerSequenceGap_refreshesEvenAfterLifecycleEndRemovesActiveRun() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "agent.wait":
                return try JSONSerialization.data(
                    withJSONObject: ["runId": "gap-run", "status": "completed"]
                )
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        // First event maps run -> session.
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "agent.event",
                    payload: [
                        "runId": "gap-run",
                        "seq": 1,
                        "stream": "assistant",
                        "sessionKey": "agent:main:test",
                        "data": ["text": "hello"]
                    ],
                    seq: 1
                )
            )
        )

        // Lifecycle end removes active run tracking.
        await connection._testEmitPush(
            .event(
                makeEventFrame(
                    event: "agent.event",
                    payload: [
                        "runId": "gap-run",
                        "seq": 2,
                        "stream": "lifecycle",
                        "data": ["phase": "end"]
                    ],
                    seq: 2
                )
            )
        )

        // Gap resync must still refresh this run even after lifecycle end.
        await connection.registerSequenceGap(runId: "gap-run", expectedSeq: 2, receivedSeq: 4)

        let calls = await recorder.all()
        #expect(
            calls.contains { call in
                guard call.method == "agent.wait" else { return false }
                return call.params?["runId"]?.value as? String == "gap-run"
            }
        )
    }

    @Test
    func registerSequenceGap_gapResyncSurvivesReconnectInterleaving() async throws {
        let recorder = OpenClawGatewayCallRecorder()
        let gate = OpenClawGapReconnectGate()

        let connection = OpenClawGatewayConnection(
            requestExecutor: { method, params in
                await recorder.record(method: method, params: params)
                if method == "agent.wait" {
                    if await gate.canAgentWait() {
                        return try JSONSerialization.data(
                            withJSONObject: ["runId": "run-reconnect-gap", "status": "timeout"]
                        )
                    }
                    throw OpenClawConnectionError.noChannel
                }
                return try JSONSerialization.data(withJSONObject: [:])
            },
            reconnectConnectHook: { _, _, _ in
                await gate.setAllowAgentWait(true)
            },
            sleepHook: { _ in }
        )

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "token")
        await connection._testSetConnected(true)

        // Initial attempt races/fails before reconnect path is active.
        await connection.registerSequenceGap(runId: "run-reconnect-gap", expectedSeq: 10, receivedSeq: 12)

        // Unexpected disconnect triggers reconnect and post-reconnect refresh.
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1008 slow consumer")
        await connection._testWaitForReconnectCompletion()

        let calls = await recorder.all()
        let waitCalls = calls.filter { $0.method == "agent.wait" }
        #expect(waitCalls.count >= 2)
        #expect(
            waitCalls.contains { call in
                call.params?["runId"]?.value as? String == "run-reconnect-gap"
            }
        )
    }
}
