//
//  ToolCallSummaryCardTests.swift
//  osaurus
//
//  Tests for ToolCallSummary display logic.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ToolCallSummary Logic")
struct ToolCallSummaryCardTests {
    @Test func pluralLabel() {
        #expect(ToolCallSummaryLogic.summaryLabel(totalCount: 3, inProgressCount: 0) == "Used 3 tools")
    }

    @Test func singularLabel() {
        #expect(ToolCallSummaryLogic.summaryLabel(totalCount: 1, inProgressCount: 0) == "Used 1 tool")
    }

    @Test func runningLabel() {
        #expect(ToolCallSummaryLogic.summaryLabel(totalCount: 3, inProgressCount: 2) == "Running 2 tools...")
    }

    @Test func runningSingularLabel() {
        #expect(ToolCallSummaryLogic.summaryLabel(totalCount: 1, inProgressCount: 1) == "Running 1 tool...")
    }

    @Test func statusIconComplete() {
        #expect(ToolCallSummaryLogic.statusIcon(isComplete: true, isRejected: false) == "checkmark")
    }

    @Test func statusIconRejected() {
        #expect(ToolCallSummaryLogic.statusIcon(isComplete: true, isRejected: true) == "xmark")
    }

    @Test func statusIconInProgress() {
        #expect(ToolCallSummaryLogic.statusIcon(isComplete: false, isRejected: false) == nil)
    }

    @Test func hasActiveToolsDetection() {
        let calls = [
            ToolCallItem(call: ToolCall(id: "1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}")), result: "done"),
            ToolCallItem(call: ToolCall(id: "2", type: "function", function: ToolCallFunction(name: "test2", arguments: "{}")), result: nil),
        ]
        #expect(ToolCallSummaryLogic.hasActiveTools(calls: calls) == true)
    }
}
