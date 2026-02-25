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
    func processChatDelta_normalizesCumulativeSnapshots() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        var emitted: [String] = []
        let processor = OpenClawEventProcessor(
            onTextDelta: { emitted.append($0) }
        )

        processor.startRun(runId: "run-snapshot", turn: turn)

        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-snapshot",
                    "seq": 1,
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello"]
                        ]
                    ]
                ],
                seq: 1
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-snapshot",
                    "seq": 2,
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello"]
                        ]
                    ]
                ],
                seq: 2
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-snapshot",
                    "seq": 3,
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello world"]
                        ]
                    ]
                ],
                seq: 3
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-snapshot",
                    "seq": 4,
                    "state": "final"
                ],
                seq: 4
            ),
            turn: turn
        )

        #expect(emitted == ["Hello", " world"])
        #expect(turn.content == "Hello world")
    }

    @Test @MainActor
    func processChatDelta_prefersExplicitDeltaField() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        var emitted: [String] = []
        let processor = OpenClawEventProcessor(
            onTextDelta: { emitted.append($0) }
        )
        processor.startRun(runId: "run-explicit", turn: turn)

        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-explicit",
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello", "delta": "Hello"]
                        ]
                    ]
                ],
                seq: 1
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-explicit",
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello there", "delta": " there"]
                        ]
                    ]
                ],
                seq: 2
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-explicit",
                    "state": "final"
                ],
                seq: 3
            ),
            turn: turn
        )

        #expect(emitted == ["Hello", " there"])
        #expect(turn.content == "Hello there")
    }

    @Test @MainActor
    func processChatDelta_nonPrefixRewriteReplacesTurnContent() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = OpenClawEventProcessor()
        processor.startRun(runId: "run-rewrite", turn: turn)

        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-rewrite",
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello world"]
                        ]
                    ]
                ],
                seq: 1
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-rewrite",
                    "state": "delta",
                    "message": [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello there"]
                        ]
                    ]
                ],
                seq: 2
            ),
            turn: turn
        )
        processor.processEvent(
            makeEventFrame(
                event: "chat",
                payload: [
                    "runId": "run-rewrite",
                    "state": "final"
                ],
                seq: 3
            ),
            turn: turn
        )

        #expect(turn.content == "Hello there")
    }

    @Test @MainActor
    func processEvent_usesEventMetaChannelAndRunId() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = OpenClawEventProcessor()
        processor.startRun(runId: "meta-run", turn: turn)

        let delta = makeEventFrame(
            event: "runtime.stream",
            payload: [
                "state": "delta",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "hello via meta"]
                    ]
                ]
            ],
            seq: 1,
            eventMeta: [
                "schemaVersion": 1,
                "channel": "chat",
                "runId": "meta-run"
            ]
        )
        processor.processEvent(delta, turn: turn)

        let final = makeEventFrame(
            event: "runtime.stream",
            payload: [
                "state": "final"
            ],
            seq: 2,
            eventMeta: [
                "schemaVersion": 1,
                "channel": "chat",
                "runId": "meta-run"
            ]
        )
        processor.processEvent(final, turn: turn)

        #expect(turn.content.contains("hello via meta"))
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

    @Test @MainActor
    func processAgentAssistant_completeTaskControlBlock_isNotRenderedAndArtifactIsPromoted() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = OpenClawEventProcessor()
        processor.startRun(runId: "run-complete-block", turn: turn)

        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-complete-block",
                seq: 1,
                data: [
                    "delta": "Let me gather sources. I'll compile the final answer."
                ]
            ),
            turn: turn
        )
        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-complete-block",
                seq: 2,
                data: [
                    "delta": """
                    \n---COMPLETE_TASK_START---
                    {"summary":"Completed research.","success":true,"artifact":"# Cristiano Ronaldo\\n- Record goalscorer\\n- Multiple Ballon d'Or winner"}
                    """
                ]
            ),
            turn: turn
        )
        processor.processEvent(
            makeAgentEventFrame(
                stream: "assistant",
                runId: "run-complete-block",
                seq: 3,
                data: [
                    "delta": """
                    \n---COMPLETE_TASK_END---
                    """
                ]
            ),
            turn: turn
        )
        processor.processEvent(
            makeAgentEventFrame(
                stream: "lifecycle",
                runId: "run-complete-block",
                seq: 4,
                data: ["phase": "end"]
            ),
            turn: turn
        )

        #expect(!turn.content.contains("---COMPLETE_TASK_START---"))
        #expect(!turn.content.contains("---COMPLETE_TASK_END---"))
        #expect(turn.content.contains("# Cristiano Ronaldo"))
        #expect(turn.content.contains("Record goalscorer"))
    }
}
