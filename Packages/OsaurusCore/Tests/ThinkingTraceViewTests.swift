//
//  ThinkingTraceViewTests.swift
//  osaurus
//
//  Tests for ThinkingTrace display logic.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ThinkingTrace Logic")
struct ThinkingTraceViewTests {
    @Test func formatShortDuration() {
        #expect(ThinkingTraceLogic.formatDuration(1.5) == "1.5s")
    }

    @Test func formatLongDuration() {
        #expect(ThinkingTraceLogic.formatDuration(125) == "2m 5s")
    }

    @Test func collapsedLabelWithDuration() {
        #expect(ThinkingTraceLogic.collapsedLabel(duration: 3.2) == "Thought for 3.2s")
    }

    @Test func collapsedLabelNoDuration() {
        #expect(ThinkingTraceLogic.collapsedLabel(duration: nil) == "Thinking...")
    }

    @Test func shouldNotCollapseWhileStreaming() {
        #expect(ThinkingTraceLogic.shouldAutoCollapse(isStreaming: true, duration: nil) == false)
    }

    @Test func shouldCollapseWhenDone() {
        #expect(ThinkingTraceLogic.shouldAutoCollapse(isStreaming: false, duration: 5.0) == true)
    }
}
