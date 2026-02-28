//
//  WorkSessionOpenClawActivityFormattingTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkSessionOpenClawActivityFormattingTests {
    private func assistantParagraphText(from blocks: [ContentBlock]) -> String? {
        for block in blocks {
            if case let .paragraph(_, text, _, role) = block.kind, role == .assistant {
                return text
            }
        }
        return nil
    }

    @Test
    func applyOpenClawActivityItems_doesNotReplaceReadableContentWithCollapsedSnapshot() {
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-activity-format", title: "Format test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let readable = ActivityItem(
            id: UUID(),
            runId: "run-activity-format",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "I'll help you with formatting.",
                    isStreaming: true,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([readable])

        let collapsed = ActivityItem(
            id: UUID(),
            runId: "run-activity-format",
            timestamp: Date().addingTimeInterval(0.1),
            kind: .assistant(
                AssistantActivity(
                    text: "I'llhelpyouwithformattingandkeepitbeautifulfortheui",
                    isStreaming: true,
                    mediaUrls: [],
                    startedAt: Date().addingTimeInterval(0.1)
                )
            )
        )
        session.applyOpenClawActivityItems([readable, collapsed])

        // Simulate completion so suppressAssistantText is false and issueBlocks renders
        session.isExecuting = false

        let paragraph = assistantParagraphText(from: session.issueBlocks)
        #expect(paragraph == "I'll help you with formatting.")
    }

    @Test
    func applyOpenClawActivityItems_allowsRicherMarkdownSnapshotToReplaceShorterText() {
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-activity-markdown", title: "Markdown test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let initial = ActivityItem(
            id: UUID(),
            runId: "run-activity-markdown",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "Working on it...",
                    isStreaming: true,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([initial])

        let markdown = ActivityItem(
            id: UUID(),
            runId: "run-activity-markdown",
            timestamp: Date().addingTimeInterval(0.1),
            kind: .assistant(
                AssistantActivity(
                    text: "## Summary\n- Added UI wiring\n- Added artifact ingestion",
                    isStreaming: false,
                    mediaUrls: [],
                    startedAt: Date().addingTimeInterval(0.1)
                )
            )
        )
        session.applyOpenClawActivityItems([initial, markdown])

        // Simulate completion so suppressAssistantText is false and issueBlocks renders
        session.isExecuting = false

        let paragraph = assistantParagraphText(from: session.issueBlocks)
        #expect(paragraph == "## Summary\n- Added UI wiring\n- Added artifact ingestion")
    }

    @Test
    func applyOpenClawActivityItems_consolidatesMultipleGatewayRunsIntoSingleTurn() {
        // Regression test for Bug 2: when the OpenClaw gateway fires multiple runs
        // for the same issue (e.g. compaction retries), each run's onIterationStart
        // creates a new assistant turn. The final activity-store snapshot should
        // consolidate them so the response appears exactly once in the UI.

        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-dedup", title: "Dedup test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        // Run 1: streaming delta lands in the first assistant turn
        session.workEngine(engine, didReceiveStreamingDelta: "Hello world", forStep: 1)

        // Run 2: new iteration starts → WorkSession creates a second assistant turn
        // because the first already has content.
        session.workEngine(engine, didStartIteration: 2, forIssue: issue)
        session.workEngine(engine, didReceiveStreamingDelta: "Hello world", forStep: 2)

        // Now the activity store delivers the final (isStreaming: false) snapshot.
        // After consolidation there should be exactly one assistant paragraph.
        let finalActivity = ActivityItem(
            id: UUID(),
            runId: "run-dedup",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "Hello world",
                    isStreaming: false,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([finalActivity])

        // Simulate completion so suppressAssistantText is false and issueBlocks renders
        session.isExecuting = false

        // Collect all assistant paragraph blocks
        let assistantTexts = session.issueBlocks.compactMap { block -> String? in
            if case let .paragraph(_, text, _, role) = block.kind, role == .assistant {
                return text
            }
            return nil
        }

        // Must be exactly one block — duplication would give count > 1
        #expect(assistantTexts.count == 1)
        #expect(assistantTexts.first == "Hello world")
    }

    // MARK: - Tool Call Bridging

    @Test
    func applyOpenClawActivityItems_bridgesToolCallsToAssistantTurn() {
        // OpenClaw gateway tool calls arrive via the ActivityItem stream, not
        // through WorkEngineDelegate.didCallTool. applyOpenClawActivityItems
        // must bridge them onto the ChatTurn so generateBlocks() can produce
        // .activityGroup blocks in the main content area.

        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-tool-bridge", title: "Tool bridge test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let toolActivity = ActivityItem(
            id: UUID(),
            runId: "run-tool-bridge",
            timestamp: Date(),
            kind: .toolCall(
                ToolCallActivity(
                    toolCallId: "call_abc123",
                    name: "web_search",
                    args: ["query": "Swift concurrency"],
                    startedAt: Date()
                )
            )
        )
        let assistantActivity = ActivityItem(
            id: UUID(),
            runId: "run-tool-bridge",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "Searching...",
                    isStreaming: true,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([toolActivity, assistantActivity])

        // The assistant turn should now have tool calls bridged from the activity items
        let blocks = session.issueBlocks
        let activityBlock = blocks.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        #expect(activityBlock != nil, "Expected .activityGroup block from bridged tool calls")
        if case let .activityGroup(_, _, _, calls) = activityBlock?.kind {
            #expect(calls.count == 1)
            #expect(calls.first?.call.function.name == "web_search")
        }
    }

    @Test
    func applyOpenClawActivityItems_bridgesCompletedToolCallWithResult() {
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-tool-result", title: "Tool result test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        var completedTool = ToolCallActivity(
            toolCallId: "call_xyz789",
            name: "read_file",
            args: ["path": "/src/main.swift"],
            startedAt: Date()
        )
        completedTool.status = .completed
        completedTool.result = "file contents here"

        let toolItem = ActivityItem(
            id: UUID(),
            runId: "run-tool-result",
            timestamp: Date(),
            kind: .toolCall(completedTool)
        )
        let assistantItem = ActivityItem(
            id: UUID(),
            runId: "run-tool-result",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "Reading file...",
                    isStreaming: true,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([toolItem, assistantItem])

        let blocks = session.issueBlocks
        let activityBlock = blocks.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        #expect(activityBlock != nil)
        if case let .activityGroup(_, _, _, calls) = activityBlock?.kind {
            #expect(calls.count == 1)
            #expect(calls.first?.call.function.name == "read_file")
            #expect(calls.first?.result == "file contents here")
        }
    }

    @Test
    func applyOpenClawActivityItems_bridgesMultipleToolCallsInOrder() {
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-multi-tool", title: "Multi tool test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        var tool1 = ToolCallActivity(
            toolCallId: "call_001",
            name: "web_search",
            args: ["query": "test"],
            startedAt: Date()
        )
        tool1.status = .completed
        tool1.result = "search results"

        let tool2 = ToolCallActivity(
            toolCallId: "call_002",
            name: "web_fetch",
            args: ["url": "https://example.com"],
            startedAt: Date().addingTimeInterval(1)
        )

        let items: [ActivityItem] = [
            ActivityItem(id: UUID(), runId: "run-multi", timestamp: Date(),
                         kind: .toolCall(tool1)),
            ActivityItem(id: UUID(), runId: "run-multi", timestamp: Date().addingTimeInterval(1),
                         kind: .toolCall(tool2)),
            ActivityItem(id: UUID(), runId: "run-multi", timestamp: Date(),
                         kind: .assistant(AssistantActivity(
                             text: "Working...", isStreaming: true, mediaUrls: [], startedAt: Date()
                         ))),
        ]
        session.applyOpenClawActivityItems(items)

        let blocks = session.issueBlocks
        let activityBlock = blocks.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        #expect(activityBlock != nil)
        if case let .activityGroup(_, _, _, calls) = activityBlock?.kind {
            #expect(calls.count == 2)
            #expect(calls[0].call.function.name == "web_search")
            #expect(calls[0].result == "search results")
            #expect(calls[1].call.function.name == "web_fetch")
            #expect(calls[1].result == nil) // still running
        }
    }

    @Test
    func applyOpenClawActivityItems_doesNotDuplicateToolCallsOnRepeatedApply() {
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-no-dup", title: "No dup test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let tool = ToolCallActivity(
            toolCallId: "call_dedup",
            name: "web_search",
            args: ["query": "test"],
            startedAt: Date()
        )

        let items: [ActivityItem] = [
            ActivityItem(id: UUID(), runId: "run-dedup", timestamp: Date(),
                         kind: .toolCall(tool)),
            ActivityItem(id: UUID(), runId: "run-dedup", timestamp: Date(),
                         kind: .assistant(AssistantActivity(
                             text: "Working...", isStreaming: true, mediaUrls: [], startedAt: Date()
                         ))),
        ]

        // Apply the same items twice (as happens with activity store updates)
        session.applyOpenClawActivityItems(items)
        session.applyOpenClawActivityItems(items)

        let blocks = session.issueBlocks
        let activityBlock = blocks.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        #expect(activityBlock != nil)
        if case let .activityGroup(_, _, _, calls) = activityBlock?.kind {
            #expect(calls.count == 1, "Tool calls should not be duplicated on repeated apply")
        }
    }

    @Test
    func applyOpenClawActivityItems_bridgesToolCallsWithoutAssistantActivity() {
        // Edge case: activity items may contain only tool calls without assistant
        // text (early in execution). Should still bridge tool calls.
        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-tool-only", title: "Tool only test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let toolItem = ActivityItem(
            id: UUID(),
            runId: "run-tool-only",
            timestamp: Date(),
            kind: .toolCall(
                ToolCallActivity(
                    toolCallId: "call_solo",
                    name: "bash",
                    args: ["command": "ls"],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([toolItem])

        let blocks = session.issueBlocks
        let activityBlock = blocks.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        #expect(activityBlock != nil, "Tool calls should appear even without assistant text activity")
    }

    @Test
    func applyOpenClawActivityItems_stripsControlBlocksFromActivitySnapshot() {
        // Regression test for Bug 1 interaction: the activity store may carry raw
        // snapshots that include control blocks. sanitizeOpenClawActivityText must
        // strip them so they never reach the chat UI.

        let session = WorkSession(agentId: UUID())
        let issue = Issue(taskId: "task-strip", title: "Strip test")
        let engine = WorkEngine()

        session.isExecuting = true
        session.selectedIssueId = issue.id
        session.activeIssue = issue
        session.workEngine(engine, didStartIssue: issue)

        let rawActivity = ActivityItem(
            id: UUID(),
            runId: "run-strip",
            timestamp: Date(),
            kind: .assistant(
                AssistantActivity(
                    text: "Visible text\n---COMPLETE_TASK_START---\n{\"summary\":\"done\",\"success\":true}\n---COMPLETE_TASK_END---",
                    isStreaming: false,
                    mediaUrls: [],
                    startedAt: Date()
                )
            )
        )
        session.applyOpenClawActivityItems([rawActivity])

        // Simulate completion so suppressAssistantText is false and issueBlocks renders
        session.isExecuting = false

        let paragraph = assistantParagraphText(from: session.issueBlocks)
        #expect(paragraph == "Visible text")
        #expect(paragraph?.contains("COMPLETE_TASK_START") == false)
    }
}
