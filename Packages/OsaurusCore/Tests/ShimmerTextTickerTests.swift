//
//  ShimmerTextTickerTests.swift
//  osaurus
//
//  Tests for ShimmerTextTicker line extraction, truncation, and fallback logic.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ShimmerTextTicker Logic")
struct ShimmerTextTickerTests {

    // MARK: - displayLine (the main API used by the view)

    @Test("Empty text returns fallback regardless of streaming")
    func emptyTextReturnsFallback() {
        #expect(ShimmerTextTickerLogic.displayLine(from: "", isStreaming: true) == "Working on it...")
        #expect(ShimmerTextTickerLogic.displayLine(from: "", isStreaming: false) == "Working on it...")
    }

    @Test("Whitespace-only text returns fallback")
    func whitespaceOnlyReturnsFallback() {
        #expect(
            ShimmerTextTickerLogic.displayLine(from: "   \n  \n  ", isStreaming: true)
                == "Working on it..."
        )
    }

    @Test("Single line while streaming shows that line (no second-to-last available)")
    func singleLineStreamingShowsIt() {
        let result = ShimmerTextTickerLogic.displayLine(from: "Analyzing...", isStreaming: true)
        #expect(result == "Analyzing...")
    }

    @Test("Single line not streaming shows that line")
    func singleLineNotStreaming() {
        let result = ShimmerTextTickerLogic.displayLine(from: "Done.", isStreaming: false)
        #expect(result == "Done.")
    }

    @Test("Multi-line while streaming shows second-to-last (last is in-progress)")
    func multiLineStreamingShowsSecondToLast() {
        let text = "Line 1\nLine 2\nLine 3 still typing"
        let result = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: true)
        #expect(result == "Line 2")
    }

    @Test("Multi-line not streaming shows actual last line")
    func multiLineNotStreamingShowsLast() {
        let text = "Line 1\nLine 2\nLine 3"
        let result = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: false)
        #expect(result == "Line 3")
    }

    @Test("Blank lines are skipped in display line logic")
    func blankLinesSkipped() {
        let text = "Line 1\n\n\nLine 2\n\nLine 3 typing"
        let result = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: true)
        #expect(result == "Line 2")
    }

    @Test("Two lines while streaming shows first (the only complete one)")
    func twoLinesStreamingShowsFirst() {
        let text = "Complete line\nStill typing"
        let result = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: true)
        #expect(result == "Complete line")
    }

    // MARK: - latestLine (legacy / non-streaming helper)

    @Test("latestLine: empty text returns fallback")
    func latestLineEmptyFallback() {
        #expect(ShimmerTextTickerLogic.latestLine(from: "") == "Working on it...")
    }

    @Test("latestLine: picks last non-empty line")
    func latestLinePicksLast() {
        #expect(ShimmerTextTickerLogic.latestLine(from: "A\nB\nC") == "C")
    }

    @Test("latestLine: blank lines filtered")
    func latestLineBlankFiltered() {
        #expect(ShimmerTextTickerLogic.latestLine(from: "A\n\n\nB\n\n") == "B")
    }

    // MARK: - Truncation

    @Test("Line at exactly 120 chars is not truncated")
    func exactlyMaxLengthNotTruncated() {
        let line = String(repeating: "A", count: 120)
        let result = ShimmerTextTickerLogic.displayLine(from: line, isStreaming: false)
        #expect(result == line)
        #expect(result.count == 120)
    }

    @Test("Line over 120 chars is truncated with ellipsis")
    func longLineTruncatedWithEllipsis() {
        let line = String(repeating: "B", count: 200)
        let result = ShimmerTextTickerLogic.displayLine(from: line, isStreaming: false)
        #expect(result.count == 123)  // 120 + "..."
        #expect(result.hasSuffix("..."))
    }

    // MARK: - Line Count (slide-up gating)

    @Test("Empty text has zero non-empty lines")
    func emptyTextZeroLines() {
        #expect(ShimmerTextTickerLogic.nonEmptyLineCount(in: "") == 0)
    }

    @Test("Single line counts as one")
    func singleLineCountsAsOne() {
        #expect(ShimmerTextTickerLogic.nonEmptyLineCount(in: "Hello") == 1)
    }

    @Test("Multiple lines counted correctly")
    func multipleLinesCounted() {
        #expect(ShimmerTextTickerLogic.nonEmptyLineCount(in: "A\nB\nC") == 3)
    }

    @Test("Blank lines excluded from count")
    func blankLinesExcludedFromCount() {
        #expect(ShimmerTextTickerLogic.nonEmptyLineCount(in: "A\n\n\nB\n\n") == 2)
    }

    @Test("Same line growing does not change count")
    func sameLineGrowingStableCount() {
        let before = ShimmerTextTickerLogic.nonEmptyLineCount(in: "Analyzing co")
        let after = ShimmerTextTickerLogic.nonEmptyLineCount(in: "Analyzing code structure")
        #expect(before == after)
    }

    @Test("New line appearing increments count")
    func newLineIncrementsCount() {
        let before = ShimmerTextTickerLogic.nonEmptyLineCount(in: "Line 1")
        let after = ShimmerTextTickerLogic.nonEmptyLineCount(in: "Line 1\nLine 2")
        #expect(after == before + 1)
    }

    // MARK: - Latest Streaming Activity

    @Test("Streaming thinking activity is preferred")
    func streamingThinkingPreferred() {
        let items = [
            makeActivityItem(kind: .assistant(AssistantActivity(
                text: "Old assistant text", isStreaming: false, mediaUrls: [], startedAt: Date()
            ))),
            makeActivityItem(kind: .thinking(ThinkingActivity(
                text: "Current thinking", isStreaming: true, duration: nil, startedAt: Date()
            ))),
        ]
        let result = ShimmerTextTickerLogic.latestStreamingActivity(from: items)
        #expect(result.text == "Current thinking")
        #expect(result.isStreaming == true)
    }

    @Test("Streaming assistant activity is preferred over non-streaming")
    func streamingAssistantPreferred() {
        let items = [
            makeActivityItem(kind: .thinking(ThinkingActivity(
                text: "Done thinking", isStreaming: false, duration: 1.0, startedAt: Date()
            ))),
            makeActivityItem(kind: .assistant(AssistantActivity(
                text: "Streaming reply", isStreaming: true, mediaUrls: [], startedAt: Date()
            ))),
        ]
        let result = ShimmerTextTickerLogic.latestStreamingActivity(from: items)
        #expect(result.text == "Streaming reply")
        #expect(result.isStreaming == true)
    }

    @Test("Falls back to most recent non-streaming activity")
    func fallbackToNonStreaming() {
        let items = [
            makeActivityItem(kind: .thinking(ThinkingActivity(
                text: "Early thought", isStreaming: false, duration: 0.5, startedAt: Date()
            ))),
            makeActivityItem(kind: .assistant(AssistantActivity(
                text: "Latest assistant", isStreaming: false, mediaUrls: [], startedAt: Date()
            ))),
            makeActivityItem(kind: .toolCall(ToolCallActivity(
                toolCallId: "tc1", name: "read", args: [:], startedAt: Date()
            ))),
        ]
        let result = ShimmerTextTickerLogic.latestStreamingActivity(from: items)
        #expect(result.text == "Latest assistant")
        #expect(result.isStreaming == false)
    }

    @Test("Empty items returns empty text with isStreaming false")
    func emptyItemsReturnsFallback() {
        let result = ShimmerTextTickerLogic.latestStreamingActivity(from: [])
        #expect(result.text == "")
        #expect(result.isStreaming == false)
    }

    @Test("Tool-only items returns empty text")
    func toolOnlyItemsReturnsFallback() {
        let items = [
            makeActivityItem(kind: .toolCall(ToolCallActivity(
                toolCallId: "tc1", name: "bash", args: [:], startedAt: Date()
            ))),
        ]
        let result = ShimmerTextTickerLogic.latestStreamingActivity(from: items)
        #expect(result.text == "")
        #expect(result.isStreaming == false)
    }

    // MARK: - Markdown Stripping

    @Test("Bold markers stripped")
    func boldStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("**bold text**") == "bold text")
    }

    @Test("Italic markers stripped")
    func italicStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("*italic text*") == "italic text")
    }

    @Test("Inline code backticks stripped")
    func inlineCodeStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("Use `foo()` here") == "Use foo() here")
    }

    @Test("Link syntax stripped, text preserved")
    func linkStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("[click here](https://example.com)") == "click here")
    }

    @Test("Header markers stripped")
    func headerStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("## Section Title") == "Section Title")
        #expect(ShimmerTextTickerLogic.stripMarkdown("### Subsection") == "Subsection")
    }

    @Test("List markers stripped")
    func listMarkersStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("- list item") == "list item")
        #expect(ShimmerTextTickerLogic.stripMarkdown("* another item") == "another item")
        #expect(ShimmerTextTickerLogic.stripMarkdown("1. numbered item") == "numbered item")
    }

    @Test("Blockquote stripped")
    func blockquoteStripped() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("> quoted text") == "quoted text")
    }

    @Test("displayLine strips markdown from output")
    func displayLineStripsMarkdown() {
        let text = "## **Analyzing** the `auth` module"
        let result = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: false)
        #expect(result == "Analyzing the auth module")
    }

    @Test("Plain text passes through unchanged")
    func plainTextUnchanged() {
        #expect(ShimmerTextTickerLogic.stripMarkdown("Just plain text") == "Just plain text")
    }

    // MARK: - Helpers

    private func makeActivityItem(kind: ActivityKind) -> ActivityItem {
        ActivityItem(id: UUID(), runId: "run-1", timestamp: Date(), kind: kind)
    }
}
