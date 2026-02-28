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

    // MARK: - toolIcon

    @Test func toolIcon_read() {
        #expect(ToolCallSummaryLogic.toolIcon(for: "read_file") == "doc.text")
    }

    @Test func toolIcon_write() {
        #expect(ToolCallSummaryLogic.toolIcon(for: "write_file") == "doc.badge.plus")
    }

    @Test func toolIcon_bash() {
        #expect(ToolCallSummaryLogic.toolIcon(for: "bash") == "terminal")
    }

    @Test func toolIcon_search() {
        #expect(ToolCallSummaryLogic.toolIcon(for: "search_files") == "magnifyingglass")
    }

    @Test func toolIcon_unknown() {
        #expect(ToolCallSummaryLogic.toolIcon(for: "mystery_tool") == "wrench.and.screwdriver")
    }

    // MARK: - humanTitle

    @Test func humanTitle_readWithPath() {
        let call = ToolCall(id: "1", type: "function", function: ToolCallFunction(
            name: "read_file",
            arguments: "{\"path\": \"/src/main.swift\"}"
        ))
        #expect(ToolCallSummaryLogic.humanTitle(call: call) == "Reading /src/main.swift")
    }

    @Test func humanTitle_bashWithCommand() {
        let call = ToolCall(id: "2", type: "function", function: ToolCallFunction(
            name: "bash",
            arguments: "{\"command\": \"swift build\"}"
        ))
        #expect(ToolCallSummaryLogic.humanTitle(call: call) == "Running swift build")
    }

    @Test func humanTitle_truncatesLongArgs() {
        let long = String(repeating: "x", count: 80)
        let call = ToolCall(id: "3", type: "function", function: ToolCallFunction(
            name: "read_file",
            arguments: "{\"path\": \"\(long)\"}"
        ))
        let result = ToolCallSummaryLogic.humanTitle(call: call)
        #expect(result.count <= 70) // "Reading " (8) + 60 + "..." (3) = 71 max
        #expect(result.hasSuffix("..."))
    }

    @Test func humanTitle_noArgs() {
        let call = ToolCall(id: "4", type: "function", function: ToolCallFunction(
            name: "list_directory",
            arguments: "{}"
        ))
        #expect(ToolCallSummaryLogic.humanTitle(call: call) == "Listing")
    }

    // MARK: - contentKind

    @Test func contentKind_fileRead() {
        let call = ToolCall(id: "1", type: "function", function: ToolCallFunction(
            name: "read_file",
            arguments: "{\"path\": \"/src/main.swift\"}"
        ))
        if case .file(let path, _) = ToolCallSummaryLogic.contentKind(call: call, result: "contents") {
            #expect(path == "/src/main.swift")
        } else {
            Issue.record("Expected .file content kind")
        }
    }

    @Test func contentKind_bash() {
        let call = ToolCall(id: "2", type: "function", function: ToolCallFunction(
            name: "bash",
            arguments: "{\"command\": \"ls -la\"}"
        ))
        if case .terminal(let command, _) = ToolCallSummaryLogic.contentKind(call: call, result: "output") {
            #expect(command == "ls -la")
        } else {
            Issue.record("Expected .terminal content kind")
        }
    }

    @Test func contentKind_search() {
        let call = ToolCall(id: "3", type: "function", function: ToolCallFunction(
            name: "web_search",
            arguments: "{\"query\": \"swift concurrency\"}"
        ))
        if case .search(let query, _) = ToolCallSummaryLogic.contentKind(call: call, result: nil) {
            #expect(query == "swift concurrency")
        } else {
            Issue.record("Expected .search content kind")
        }
    }
}
