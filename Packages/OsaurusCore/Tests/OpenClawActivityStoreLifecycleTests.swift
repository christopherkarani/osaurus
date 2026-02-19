//
//  OpenClawActivityStoreLifecycleTests.swift
//  osaurusTests

import Foundation
import Testing
@testable import OsaurusCore
import OpenClawProtocol

struct OpenClawActivityStoreLifecycleTests {

    @Test @MainActor
    func lifecycleStart_setsRunActive() async throws {
        let store = OpenClawActivityStore()
        let frame = makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start", "startedAt": 1708345600000]
        )
        store.processEventFrame(frame)

        #expect(store.isRunActive == true)
        #expect(store.activeRunId == "test-run-1")
        #expect(store.items.count == 1)

        guard case .lifecycle(let activity) = store.items[0].kind else {
            Issue.record("Expected lifecycle activity")
            return
        }
        guard case .started = activity.phase else {
            Issue.record("Expected started phase")
            return
        }
        #expect(activity.runId == "test-run-1")
    }

    @Test @MainActor
    func lifecycleEnd_clearsRunActive() async throws {
        let store = OpenClawActivityStore()

        let startFrame = makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start", "startedAt": 1708345600000]
        )
        store.processEventFrame(startFrame)

        let endFrame = makeAgentEventFrame(
            stream: "lifecycle",
            ts: 1708345601000,
            data: ["phase": "end"]
        )
        store.processEventFrame(endFrame)

        #expect(store.isRunActive == false)
        #expect(store.items.count == 2)

        guard case .lifecycle(let activity) = store.items[1].kind else {
            Issue.record("Expected lifecycle activity")
            return
        }
        guard case .ended = activity.phase else {
            Issue.record("Expected ended phase")
            return
        }
    }

    @Test @MainActor
    func lifecycleError_surfacesMessage() async throws {
        let store = OpenClawActivityStore()

        let startFrame = makeAgentEventFrame(
            stream: "lifecycle",
            data: ["phase": "start"]
        )
        store.processEventFrame(startFrame)

        let errorFrame = makeAgentEventFrame(
            stream: "lifecycle",
            ts: 1708345601000,
            data: ["phase": "error", "error": "LLM request failed."]
        )
        store.processEventFrame(errorFrame)

        #expect(store.isRunActive == false)

        guard case .lifecycle(let activity) = store.items[1].kind else {
            Issue.record("Expected lifecycle activity")
            return
        }
        guard case .error(let msg) = activity.phase else {
            Issue.record("Expected error phase")
            return
        }
        #expect(msg == "LLM request failed.")
    }

    @Test @MainActor
    func lifecycleStart_finalizesActiveThinking() async throws {
        let store = OpenClawActivityStore()

        let thinkingFrame = makeAgentEventFrame(
            stream: "thinking",
            data: ["delta": "Hmm, let me think about this..."]
        )
        store.processEventFrame(thinkingFrame)

        #expect(store.items.count == 1)
        guard case .thinking(var thinkingActivity) = store.items[0].kind else {
            Issue.record("Expected thinking activity")
            return
        }
        #expect(thinkingActivity.isStreaming == true)

        let lifecycleFrame = makeAgentEventFrame(
            stream: "lifecycle",
            ts: 1708345601000,
            data: ["phase": "start"]
        )
        store.processEventFrame(lifecycleFrame)

        #expect(store.items.count == 2)

        guard case .thinking(let finalizedActivity) = store.items[0].kind else {
            Issue.record("Expected thinking activity at index 0")
            return
        }
        #expect(finalizedActivity.isStreaming == false)
        #expect(finalizedActivity.duration != nil)

        guard case .lifecycle(let lifecycleActivity) = store.items[1].kind else {
            Issue.record("Expected lifecycle activity at index 1")
            return
        }
        guard case .started = lifecycleActivity.phase else {
            Issue.record("Expected started phase")
            return
        }
    }
}
