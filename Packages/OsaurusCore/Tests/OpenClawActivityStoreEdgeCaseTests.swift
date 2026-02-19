//
//  OpenClawActivityStoreEdgeCaseTests.swift
//  osaurusTests
//
//  Edge case and state management tests for OpenClawActivityStore.
//  Tests compaction, reset, malformed events, and multi-run tracking.
//

import Foundation
import Testing
@testable import OsaurusCore
import OpenClawKit

struct OpenClawActivityStoreEdgeCaseTests {

    // MARK: - Compaction Tests

    @Test @MainActor
    func compactionStartAndEnd_createsItems() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            data: ["phase": "start"]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            seq: 2,
            data: ["phase": "end", "willRetry": false]
        ))

        #expect(store.items.count == 2)

        guard case .compaction(let activity1) = store.items[0].kind else {
            Issue.record("First item should be compaction activity")
            return
        }
        #expect(activity1.phase == .started)

        guard case .compaction(let activity2) = store.items[1].kind else {
            Issue.record("Second item should be compaction activity")
            return
        }
        #expect(activity2.phase == .ended)
    }

    @Test @MainActor
    func compactionWillRetry_setsCorrectPhase() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            data: ["phase": "start"]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            seq: 2,
            data: ["phase": "end", "willRetry": true]
        ))

        #expect(store.items.count == 2)

        guard case .compaction(let activity) = store.items[1].kind else {
            Issue.record("Second item should be compaction activity")
            return
        }
        #expect(activity.phase == .willRetry)
    }

    // MARK: - Malformed Event Tests

    @Test @MainActor
    func malformedEvent_noPayload_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let frame = makeEventFrame(payload: ["irrelevant": "data"], seq: 1)
        store.processEventFrame(frame)

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func malformedEvent_missingStream_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let payload: [String: Any] = [
            "runId": "test-run-1",
            "seq": 1,
            "ts": 1708345600000,
            "data": ["phase": "start"]
            // Missing "stream" field
        ]
        store.processEventFrame(makeEventFrame(payload: payload, seq: 1))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func malformedEvent_missingRunId_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let payload: [String: Any] = [
            "stream": "lifecycle",
            "seq": 1,
            "ts": 1708345600000,
            "data": ["phase": "start"]
            // Missing "runId" field
        ]
        store.processEventFrame(makeEventFrame(payload: payload, seq: 1))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func malformedEvent_missingTimestamp_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let payload: [String: Any] = [
            "runId": "test-run-1",
            "stream": "lifecycle",
            "seq": 1,
            // Missing "ts" field
            "data": ["phase": "start"]
        ]
        store.processEventFrame(makeEventFrame(payload: payload, seq: 1))

        #expect(store.items.count == 0)
    }

    // MARK: - Unknown Stream Tests

    @Test @MainActor
    func unknownStream_isIgnored() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "unknown_stream",
            data: ["some": "data"]
        ))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func unknownStream_doesNotCrash() async throws {
        let store = OpenClawActivityStore()

        let streams = ["random", "unknown", "not_a_stream", "foo.bar.baz"]
        for (index, stream) in streams.enumerated() {
            store.processEventFrame(makeAgentEventFrame(
                stream: stream,
                seq: index + 1,
                data: ["data": "value"]
            ))
        }

        #expect(store.items.count == 0)
    }

    // MARK: - Reset Tests

    @Test @MainActor
    func reset_clearsAllState() async throws {
        let store = OpenClawActivityStore()

        // Add lifecycle start events to populate state
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            seq: 2,
            data: ["text": "Thinking..."]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            seq: 3,
            data: ["text": "Response"]
        ))

        #expect(store.items.count == 3)
        #expect(store.isRunActive == true)
        #expect(store.activeRunId == "test-run-1")

        // Reset and verify all state cleared
        store.reset()

        #expect(store.items.isEmpty)
        #expect(store.isRunActive == false)
        #expect(store.activeRunId == nil)
    }

    @Test @MainActor
    func reset_clearsIndexes() async throws {
        let store = OpenClawActivityStore()

        // Add a tool call to populate the toolCallIndex
        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            data: [
                "phase": "start",
                "toolCallId": "tool-1",
                "name": "bash",
                "args": ["command": "ls"]
            ]
        ))

        #expect(store.items.count == 1)

        // Reset should clear the toolCallIndex
        store.reset()

        #expect(store.items.isEmpty)

        // Add another tool with the same ID — should create a new index entry
        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            data: [
                "phase": "start",
                "toolCallId": "tool-1",
                "name": "bash",
                "args": ["command": "pwd"]
            ]
        ))

        #expect(store.items.count == 1)
    }

    // MARK: - Multi-Run Tracking Tests

    @Test @MainActor
    func multipleRuns_trackCorrectRunId() async throws {
        let store = OpenClawActivityStore()

        // Run 1: start
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-1",
            seq: 1,
            data: ["phase": "start"]
        ))

        #expect(store.activeRunId == "run-1")
        #expect(store.isRunActive == true)

        // Run 1: end
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-1",
            seq: 2,
            data: ["phase": "end"]
        ))

        #expect(store.activeRunId == "run-1")
        #expect(store.isRunActive == false)

        // Run 2: start
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-2",
            seq: 3,
            data: ["phase": "start"]
        ))

        #expect(store.activeRunId == "run-2")
        #expect(store.isRunActive == true)

        // Run 2: end
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-2",
            seq: 4,
            data: ["phase": "end"]
        ))

        #expect(store.activeRunId == "run-2")
        #expect(store.isRunActive == false)

        // Verify all 4 items are present
        #expect(store.items.count == 4)
    }

    @Test @MainActor
    func multipleRuns_preservesHistoryAcrossRuns() async throws {
        let store = OpenClawActivityStore()

        // Run 1
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-1",
            data: ["phase": "start"]
        ))
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            runId: "run-1",
            seq: 2,
            data: ["text": "Run 1 thought"]
        ))
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-1",
            seq: 3,
            data: ["phase": "end"]
        ))

        let countAfterRun1 = store.items.count
        #expect(countAfterRun1 == 3)

        // Run 2
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            runId: "run-2",
            seq: 4,
            data: ["phase": "start"]
        ))
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            runId: "run-2",
            seq: 5,
            data: ["text": "Run 2 thought"]
        ))

        #expect(store.items.count == 5)
    }

    @Test @MainActor
    func lifecycleError_updatesRunState() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        ))

        #expect(store.isRunActive == true)

        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            seq: 2,
            data: ["phase": "error", "error": "Test error message"]
        ))

        #expect(store.isRunActive == false)
        #expect(store.items.count == 2)

        guard case .lifecycle(let activity) = store.items[1].kind else {
            Issue.record("Second item should be lifecycle activity")
            return
        }

        guard case .error(let msg) = activity.phase else {
            Issue.record("Lifecycle phase should be error")
            return
        }

        #expect(msg == "Test error message")
    }

    // MARK: - Integration Tests

    @Test @MainActor
    func resetDuringActiveRun_finalizesStreams() async throws {
        let store = OpenClawActivityStore()

        // Start a run with streaming content
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            seq: 2,
            data: ["text": "Thinking..."]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            seq: 3,
            data: ["text": "Response"]
        ))

        #expect(store.items.count == 3)

        // Verify thinking and assistant are marked as streaming
        guard case .thinking(let thinkingActivity) = store.items[1].kind else {
            Issue.record("Second item should be thinking activity")
            return
        }
        #expect(thinkingActivity.isStreaming == true)

        guard case .assistant(let assistantActivity) = store.items[2].kind else {
            Issue.record("Third item should be assistant activity")
            return
        }
        #expect(assistantActivity.isStreaming == true)

        // Reset and verify all state is cleared
        store.reset()

        #expect(store.items.isEmpty)
        #expect(store.isRunActive == false)
        #expect(store.activeRunId == nil)
    }

    @Test @MainActor
    func compactionDuringRun_doesNotAffectRunState() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        ))

        #expect(store.isRunActive == true)

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            seq: 2,
            data: ["phase": "start"]
        ))

        #expect(store.isRunActive == true)

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            seq: 3,
            data: ["phase": "end", "willRetry": false]
        ))

        #expect(store.isRunActive == true)
        #expect(store.items.count == 3)
    }

    @Test @MainActor
    func toolCallIndex_isCorrectlyMaintained() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            data: [
                "phase": "start",
                "toolCallId": "tool-1",
                "name": "bash",
                "args": ["command": "ls"]
            ]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            data: [
                "phase": "update",
                "toolCallId": "tool-1",
                "partialResult": "file1.txt\nfile2.txt"
            ]
        ))

        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            seq: 3,
            data: [
                "phase": "result",
                "toolCallId": "tool-1",
                "isError": false,
                "result": "file1.txt\nfile2.txt\nfile3.txt",
                "meta": "3 files"
            ]
        ))

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Item should be tool call activity")
            return
        }

        #expect(activity.toolCallId == "tool-1")
        #expect(activity.name == "bash")
        #expect(activity.status == .completed)
        #expect(activity.isError == false)
        #expect(activity.result == "file1.txt\nfile2.txt\nfile3.txt")
    }

    @Test @MainActor
    func unknownToolPhase_doesNotCreateItem() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            data: [
                "phase": "unknown_phase",
                "toolCallId": "tool-1",
                "name": "bash",
                "args": ["command": "ls"]
            ]
        ))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func toolUpdate_withoutStart_isIgnored() async throws {
        let store = OpenClawActivityStore()

        // Try to update a tool that was never started
        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            data: [
                "phase": "update",
                "toolCallId": "tool-1",
                "partialResult": "result"
            ]
        ))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func compactionInvalidPhase_isIgnored() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "compaction",
            data: ["phase": "invalid_phase"]
        ))

        #expect(store.items.count == 0)
    }

    @Test @MainActor
    func timestampAsInteger_isHandledCorrectly() async throws {
        let store = OpenClawActivityStore()

        let payload: [String: Any] = [
            "runId": "test-run-1",
            "stream": "lifecycle",
            "seq": 1,
            "ts": 1708345600000,  // Integer timestamp
            "data": ["phase": "start"]
        ]
        store.processEventFrame(makeEventFrame(payload: payload, seq: 1))

        #expect(store.items.count == 1)
    }

    @Test @MainActor
    func emptyDataPayload_isHandledCorrectly() async throws {
        let store = OpenClawActivityStore()

        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: [:]  // Empty data
        ))

        // lifecycle handler defaults phase to empty string, which doesn't match any case
        #expect(store.items.count == 0)
    }
}
