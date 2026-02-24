//
//  OpenClawEventProcessorTests.swift
//  osaurusTests
//

import Foundation
import Testing
@testable import OsaurusCore

struct OpenClawEventProcessorTests {

    @Test @MainActor
    func processAgentStreams_updatesChatTurn() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = OpenClawEventProcessor()
        processor.startRun(runId: "run-1", turn: turn)

        processor.processEvent(
            makeAgentEventFrame(
                stream: "thinking",
                runId: "run-1",
                seq: 1,
                data: ["delta": "Thinking..."]
            ),
            turn: turn
        )

        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-1",
                seq: 2,
                data: ["text": "Hello from OpenClaw"]
            ),
            turn: turn
        )

        processor.processEvent(
            makeAgentEventFrame(
                stream: "tool",
                runId: "run-1",
                seq: 3,
                data: [
                    "phase": "start",
                    "toolCallId": "tool_1",
                    "name": "read_file",
                    "args": ["path": "/tmp/a.txt"]
                ]
            ),
            turn: turn
        )

        processor.processEvent(
            makeAgentEventFrame(
                stream: "tool",
                runId: "run-1",
                seq: 4,
                data: [
                    "phase": "result",
                    "toolCallId": "tool_1",
                    "result": "contents"
                ]
            ),
            turn: turn
        )

        processor.processEvent(
            makeAgentEventFrame(
                stream: "lifecycle",
                runId: "run-1",
                seq: 5,
                data: ["phase": "end"]
            ),
            turn: turn
        )

        #expect(turn.thinking.contains("Thinking"))
        #expect(turn.content.contains("Hello from OpenClaw"))
        #expect(turn.toolCalls?.count == 1)
        #expect(turn.toolCalls?.first?.function.name == "read_file")
        #expect(turn.toolResults["tool_1"] == "contents")
    }

    @Test @MainActor
    func processChatDelta_extractsTextAndThinking() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        var emitted: [String] = []
        let processor = OpenClawEventProcessor(
            onTextDelta: { emitted.append($0) }
        )

        processor.startRun(runId: "run-2", turn: turn)

        let delta = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "run-2",
                "seq": 1,
                "state": "delta",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "stream text"],
                        ["type": "thinking", "thinking": "internal thought"]
                    ]
                ]
            ],
            seq: 1
        )
        processor.processEvent(delta, turn: turn)

        let final = makeEventFrame(
            event: "chat",
            payload: [
                "runId": "run-2",
                "seq": 2,
                "state": "final"
            ],
            seq: 2
        )
        processor.processEvent(final, turn: turn)

        #expect(emitted == ["stream text"])
        #expect(turn.content.contains("stream text"))
        #expect(turn.thinking.contains("internal thought"))
    }

    @Test @MainActor
    func sequenceGap_triggersCallback() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        var expected = 0
        var received = 0
        let processor = OpenClawEventProcessor(
            onSequenceGap: { nextExpected, nextReceived in
                expected = nextExpected
                received = nextReceived
            }
        )
        processor.startRun(runId: "run-3", turn: turn)

        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-3",
                seq: 1,
                data: ["text": "A"]
            ),
            turn: turn
        )

        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-3",
                seq: 3,
                data: ["text": "B"]
            ),
            turn: turn
        )

        #expect(expected == 2)
        #expect(received == 3)
    }

    @Test @MainActor
    func processEvent_ignoresOtherRunIds() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = OpenClawEventProcessor()
        processor.startRun(runId: "run-4", turn: turn)

        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "different-run",
                seq: 1,
                data: ["text": "ignored"]
            ),
            turn: turn
        )

        #expect(turn.contentIsEmpty)
        #expect(turn.toolCalls == nil)
    }

    @Test @MainActor
    func onSync_firesFromDeltaProcessor_notPerEvent() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        var syncCount = 0
        let processor = OpenClawEventProcessor(
            onSync: { syncCount += 1 }
        )
        processor.startRun(runId: "run-sync", turn: turn)

        let eventCount = 20
        for i in 1 ... eventCount {
            processor.processEvent(
                makeAgentEventFrame(
                    stream: "assistant",
                    runId: "run-sync",
                    seq: i,
                    data: ["text": "word\(i) "]
                ),
                turn: turn
            )
        }

        processor.endRun(turn: turn)

        // The delta processor's adaptive throttle (100-250ms) should batch
        // syncs so we get far fewer than one-per-event.
        #expect(syncCount > 0, "onSync must fire at least once")
        #expect(syncCount < eventCount, "onSync should be throttled, not per-event")
    }
}
