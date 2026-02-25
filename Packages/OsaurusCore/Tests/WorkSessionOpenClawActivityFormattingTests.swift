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

        let paragraph = assistantParagraphText(from: session.issueBlocks)
        #expect(paragraph == "## Summary\n- Added UI wiring\n- Added artifact ingestion")
    }
}
