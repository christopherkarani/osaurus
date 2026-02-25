//
//  WorkToolActivityPresentationTests.swift
//  osaurusTests
//
//  Tests display normalization and detail summarization for Work-mode tool rows.
//

import Foundation
import Testing
@testable import OsaurusCore

struct WorkToolActivityPresentationTests {

    @Test
    func displayName_normalizesInvalidNames() {
        #expect(WorkToolActivityPresentation.displayName("web_fetch") == "web_fetch")
        #expect(WorkToolActivityPresentation.displayName("   ") == "invalid_tool_name")
        #expect(WorkToolActivityPresentation.displayName("</think> <|tool_calls|>") == "invalid_tool_name")
    }

    @Test
    func detail_summarizesMissingFileReadErrors() {
        var activity = ToolCallActivity(
            toolCallId: "tool-1",
            name: "read",
            args: ["path": "/tmp/file.txt"],
            startedAt: Date()
        )
        activity.status = .failed
        activity.result = "ENOENT: no such file or directory, access '/Users/test/.openclaw/workspace/MEMORY.md'"

        let detail = WorkToolActivityPresentation.detail(for: activity)
        #expect(detail == "Missing file: /Users/test/.openclaw/workspace/MEMORY.md")
    }

    @Test
    func detail_summarizesWebFetchHttpErrors() {
        var activity = ToolCallActivity(
            toolCallId: "tool-2",
            name: "web_fetch",
            args: ["url": "https://example.com"],
            startedAt: Date()
        )
        activity.status = .failed
        activity.result = "Web fetch failed (403): request blocked"

        let detail = WorkToolActivityPresentation.detail(for: activity)
        #expect(detail == "Web fetch failed (HTTP 403)")
    }

    @Test
    func detail_fallsBackToArgsSummaryWhenNoResult() {
        var activity = ToolCallActivity(
            toolCallId: "tool-3",
            name: "web_fetch",
            args: ["url": "https://example.com/profile"],
            startedAt: Date()
        )
        activity.status = .running
        activity.result = nil

        let detail = WorkToolActivityPresentation.detail(for: activity)
        #expect(detail == "url: https://example.com/profile")
    }
}
