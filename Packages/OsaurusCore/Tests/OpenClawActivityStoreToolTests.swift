//
//  OpenClawActivityStoreToolTests.swift
//  osaurusTests
//
//  Tests for the tool stream handler of OpenClawActivityStore.
//  Verifies tool lifecycle (start → update → result), error handling, and integration with other streams.
//

import Foundation
import Testing
@testable import OsaurusCore
import OpenClawKit

struct OpenClawActivityStoreToolTests {

    // MARK: - Test: toolStartAndResult_correlateToSingleItem

    @Test @MainActor
    func toolStartAndResult_correlateToSingleItem() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_1",
                "args": ["path": "/tmp/file.txt"]
            ]
        )

        let result = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345601000,
            data: [
                "phase": "result",
                "name": "read",
                "toolCallId": "call_1",
                "meta": "50 lines",
                "isError": false,
                "result": "file contents"
            ]
        )

        store.processEventFrame(start)
        store.processEventFrame(result)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        #expect(activity.toolCallId == "call_1")
        #expect(activity.status == .completed)
        #expect(activity.resultSize == "50 lines")
        #expect(activity.isError == false)
        #expect(activity.result == "file contents")

        // Duration should be approximately 1.0 second (1708345601000 - 1708345600000 = 1000ms)
        if let duration = activity.duration {
            #expect(duration >= 0.99 && duration <= 1.01)
        } else {
            Issue.record("Expected duration to be set")
        }
    }

    // MARK: - Test: toolResultWithError_setsFailed

    @Test @MainActor
    func toolResultWithError_setsFailed() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "execute",
                "toolCallId": "call_2",
                "args": ["command": "bad command"]
            ]
        )

        let result = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345601000,
            data: [
                "phase": "result",
                "name": "execute",
                "toolCallId": "call_2",
                "isError": true,
                "result": "Command not found"
            ]
        )

        store.processEventFrame(start)
        store.processEventFrame(result)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        #expect(activity.status == .failed)
        #expect(activity.isError == true)
        #expect(activity.result == "Command not found")
    }

    // MARK: - Test: toolUpdate_setsPartialResult

    @Test @MainActor
    func toolUpdate_setsPartialResult() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_3",
                "args": ["path": "/tmp/large.txt"]
            ]
        )

        let update = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345600500,
            data: [
                "phase": "update",
                "name": "read",
                "toolCallId": "call_3",
                "partialResult": "partial output"
            ]
        )

        store.processEventFrame(start)
        store.processEventFrame(update)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        #expect(activity.status == .running)
        #expect(activity.result == "partial output")
    }

    // MARK: - Test: toolStart_finalizesActiveThinking

    @Test @MainActor
    func toolStart_finalizesActiveThinking() async throws {
        let store = OpenClawActivityStore()

        let thinkingStart = makeAgentEventFrame(
            stream: "thinking",
            ts: 1708345600000,
            data: [
                "delta": "Hmm, I need to read"
            ]
        )

        let thinkingDelta = makeAgentEventFrame(
            stream: "thinking",
            seq: 2,
            ts: 1708345600100,
            data: [
                "delta": " the file first."
            ]
        )

        let toolStart = makeAgentEventFrame(
            stream: "tool",
            seq: 3,
            ts: 1708345600200,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_4",
                "args": ["path": "/tmp/file.txt"]
            ]
        )

        store.processEventFrame(thinkingStart)
        store.processEventFrame(thinkingDelta)
        store.processEventFrame(toolStart)

        #expect(store.items.count == 2)

        guard case .thinking(let thinkingActivity) = store.items[0].kind else {
            Issue.record("Expected thinking activity at items[0]")
            return
        }

        guard case .toolCall(let toolActivity) = store.items[1].kind else {
            Issue.record("Expected toolCall activity at items[1]")
            return
        }

        // Thinking should be finalized (not streaming)
        #expect(thinkingActivity.isStreaming == false)
        // Duration should be ~200ms
        if let duration = thinkingActivity.duration {
            #expect(duration >= 0.19 && duration <= 0.21)
        } else {
            Issue.record("Expected duration to be set on thinking activity")
        }

        // Tool should exist and be running
        #expect(toolActivity.status == .running)
        #expect(toolActivity.toolCallId == "call_4")
    }

    // MARK: - Test: toolWithMissingToolCallId_isIgnored

    @Test @MainActor
    func toolWithMissingToolCallId_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let invalidTool = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read"
                // Missing toolCallId
            ]
        )

        store.processEventFrame(invalidTool)

        #expect(store.items.count == 0)
    }

    // MARK: - Test: multipleToolCalls_maintainSeparateIndices

    @Test @MainActor
    func multipleToolCalls_maintainSeparateIndices() async throws {
        let store = OpenClawActivityStore()

        let tool1Start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_A",
                "args": ["path": "/tmp/a.txt"]
            ]
        )

        let tool2Start = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345600100,
            data: [
                "phase": "start",
                "name": "write",
                "toolCallId": "call_B",
                "args": ["path": "/tmp/b.txt", "content": "data"]
            ]
        )

        let tool1Result = makeAgentEventFrame(
            stream: "tool",
            seq: 3,
            ts: 1708345600200,
            data: [
                "phase": "result",
                "toolCallId": "call_A",
                "isError": false,
                "result": "content of a"
            ]
        )

        let tool2Result = makeAgentEventFrame(
            stream: "tool",
            seq: 4,
            ts: 1708345600300,
            data: [
                "phase": "result",
                "toolCallId": "call_B",
                "isError": false,
                "result": "ok"
            ]
        )

        store.processEventFrame(tool1Start)
        store.processEventFrame(tool2Start)
        store.processEventFrame(tool1Result)
        store.processEventFrame(tool2Result)

        #expect(store.items.count == 2)

        guard case .toolCall(let activity1) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        guard case .toolCall(let activity2) = store.items[1].kind else {
            Issue.record("Expected toolCall activity at items[1]")
            return
        }

        #expect(activity1.toolCallId == "call_A")
        #expect(activity1.status == .completed)
        #expect(activity1.result == "content of a")

        #expect(activity2.toolCallId == "call_B")
        #expect(activity2.status == .completed)
        #expect(activity2.result == "ok")
    }

    // MARK: - Test: toolUpdate_beforeStart_isIgnored

    @Test @MainActor
    func toolUpdate_beforeStart_isIgnored() async throws {
        let store = OpenClawActivityStore()

        let update = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "update",
                "toolCallId": "nonexistent",
                "partialResult": "should be ignored"
            ]
        )

        store.processEventFrame(update)

        #expect(store.items.count == 0)
    }

    // MARK: - Test: toolWithComplexResult_stringified

    @Test @MainActor
    func toolWithComplexResult_stringified() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "search",
                "toolCallId": "call_search",
                "args": ["query": "test"]
            ]
        )

        let result = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345601000,
            data: [
                "phase": "result",
                "toolCallId": "call_search",
                "isError": false,
                "result": [
                    "matches": 5,
                    "firstResult": "found it"
                ]
            ]
        )

        store.processEventFrame(start)
        store.processEventFrame(result)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        #expect(activity.status == .completed)
        #expect(activity.result != nil)
        // Result should be stringified
        if let result = activity.result {
            #expect(result.contains("matches") || result.contains("firstResult"))
        }
    }

    // MARK: - Test: toolWithStringResult_preservedAsIs

    @Test @MainActor
    func toolWithStringResult_preservedAsIs() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_str",
                "args": ["path": "/tmp/file.txt"]
            ]
        )

        let result = makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            ts: 1708345601000,
            data: [
                "phase": "result",
                "toolCallId": "call_str",
                "isError": false,
                "result": "plain text result"
            ]
        )

        store.processEventFrame(start)
        store.processEventFrame(result)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        #expect(activity.result == "plain text result")
    }

    // MARK: - Test: toolArgsSummary_generated

    @Test @MainActor
    func toolArgsSummary_generated() async throws {
        let store = OpenClawActivityStore()

        let start = makeAgentEventFrame(
            stream: "tool",
            ts: 1708345600000,
            data: [
                "phase": "start",
                "name": "read",
                "toolCallId": "call_summary",
                "args": ["path": "/home/user/important.txt"]
            ]
        )

        store.processEventFrame(start)

        #expect(store.items.count == 1)

        guard case .toolCall(let activity) = store.items[0].kind else {
            Issue.record("Expected toolCall activity at items[0]")
            return
        }

        // For "read" tool, argsSummary should be the path
        #expect(activity.argsSummary == "/home/user/important.txt")
    }

}
