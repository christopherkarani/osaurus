//
//  OpenClawActivityStoreStreamingTests.swift
//  osaurusTests
//
//  Tests for thinking and assistant stream handlers in OpenClawActivityStore.
//  Covers delta accumulation, finalization, and separation of stream types.
//

import Foundation
import Testing
@testable import OsaurusCore
import OpenClawProtocol

struct OpenClawActivityStoreStreamingTests {

    // MARK: - Test 1: Thinking Delta Accumulation

    @Test @MainActor
    func thinkingDeltaAccumulation_producesOneItem() async throws {
        let store = OpenClawActivityStore()

        // Send 3 thinking events with delta accumulation
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            data: ["text": "A", "delta": "A"]
        ))
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            seq: 2,
            data: ["text": "AB", "delta": "B"]
        ))
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            seq: 3,
            data: ["text": "ABC", "delta": "C"]
        ))

        // Verify: single thinking item with accumulated text
        #expect(store.items.count == 1)

        guard case .thinking(let activity) = store.items[0].kind else {
            Issue.record("Expected thinking kind but got something else")
            return
        }

        #expect(activity.text == "ABC")
        #expect(activity.isStreaming == true)
    }

    // MARK: - Test 2: Thinking Finalization When Tool Starts

    @Test @MainActor
    func thinkingFinalization_whenToolStarts() async throws {
        let store = OpenClawActivityStore()

        // Send thinking delta
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            data: ["text": "Processing request", "delta": "Processing request"]
        ))

        #expect(store.items.count == 1)
        guard case .thinking(let beforeFinal) = store.items[0].kind else {
            Issue.record("Expected thinking kind")
            return
        }
        #expect(beforeFinal.isStreaming == true)
        #expect(beforeFinal.duration == nil)

        // Send tool start event — should finalize thinking
        store.processEventFrame(makeAgentEventFrame(
            stream: "tool",
            seq: 2,
            data: [
                "phase": "start",
                "toolCallId": "tool-1",
                "name": "bash",
                "args": ["command": "ls"]
            ]
        ))

        // Verify: thinking is finalized, new tool item added
        #expect(store.items.count == 2)

        guard case .thinking(let afterFinal) = store.items[0].kind else {
            Issue.record("Expected thinking kind in items[0]")
            return
        }
        #expect(afterFinal.isStreaming == false)
        #expect(afterFinal.duration != nil)

        guard case .toolCall = store.items[1].kind else {
            Issue.record("Expected toolCall kind in items[1]")
            return
        }
    }

    // MARK: - Test 3: Assistant Delta Accumulation With Media URLs

    @Test @MainActor
    func assistantDeltaAccumulation_withMediaUrls() async throws {
        let store = OpenClawActivityStore()

        // Send first assistant event
        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            data: ["text": "Hello", "delta": "Hello"]
        ))

        #expect(store.items.count == 1)
        guard case .assistant(let first) = store.items[0].kind else {
            Issue.record("Expected assistant kind")
            return
        }
        #expect(first.text == "Hello")
        #expect(first.mediaUrls.isEmpty)

        // Send second assistant event with delta and media URL
        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            seq: 2,
            data: [
                "text": "Hello world",
                "delta": " world",
                "mediaUrls": ["https://example.com/img.png"]
            ]
        ))

        // Verify: single assistant item with accumulated text and media
        #expect(store.items.count == 1)

        guard case .assistant(let activity) = store.items[0].kind else {
            Issue.record("Expected assistant kind after accumulation")
            return
        }

        #expect(activity.text == "Hello world")
        #expect(activity.mediaUrls == ["https://example.com/img.png"])
        #expect(activity.isStreaming == true)
    }

    // MARK: - Test 4: Assistant Finalization When Lifecycle Ends

    @Test @MainActor
    func assistantFinalization_whenLifecycleEnds() async throws {
        let store = OpenClawActivityStore()

        // Send lifecycle start
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        ))

        // Send assistant delta
        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            seq: 2,
            data: ["text": "Hello", "delta": "Hello"]
        ))

        #expect(store.items.count == 2)
        guard case .assistant(let beforeFinal) = store.items[1].kind else {
            Issue.record("Expected assistant kind in items[1]")
            return
        }
        #expect(beforeFinal.isStreaming == true)

        // Send lifecycle end — should finalize assistant
        store.processEventFrame(makeAgentEventFrame(
            stream: "lifecycle",
            seq: 3,
            data: ["phase": "end"]
        ))

        // Verify: assistant finalized, lifecycle end added
        #expect(store.items.count == 3)

        guard case .assistant(let afterFinal) = store.items[1].kind else {
            Issue.record("Expected assistant kind in items[1] after finalization")
            return
        }
        #expect(afterFinal.isStreaming == false)

        guard case .lifecycle(let lifecycleEnd) = store.items[2].kind else {
            Issue.record("Expected lifecycle kind in items[2]")
            return
        }
        #expect(lifecycleEnd.phase == .ended)
    }

    // MARK: - Test 5: Thinking and Assistant Are Separate Items

    @Test @MainActor
    func thinkingAndAssistant_areSeparateItems() async throws {
        let store = OpenClawActivityStore()

        // Send thinking delta
        store.processEventFrame(makeAgentEventFrame(
            stream: "thinking",
            data: ["text": "Thinking...", "delta": "Thinking..."]
        ))

        #expect(store.items.count == 1)

        // Send assistant delta
        store.processEventFrame(makeAgentEventFrame(
            stream: "assistant",
            seq: 2,
            data: ["text": "Response", "delta": "Response"]
        ))

        // Verify: two separate items
        #expect(store.items.count == 2)

        guard case .thinking(let thinkingActivity) = store.items[0].kind else {
            Issue.record("Expected thinking kind in items[0]")
            return
        }
        #expect(thinkingActivity.text == "Thinking...")
        #expect(thinkingActivity.isStreaming == true)

        guard case .assistant(let assistantActivity) = store.items[1].kind else {
            Issue.record("Expected assistant kind in items[1]")
            return
        }
        #expect(assistantActivity.text == "Response")
        #expect(assistantActivity.isStreaming == true)
    }
}
