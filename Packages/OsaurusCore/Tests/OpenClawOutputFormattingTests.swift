//
//  OpenClawOutputFormattingTests.swift
//  osaurusTests
//
//  Tests for OpenClawControlBlockStreamFilter and OpenClawOutputFormatting.
//  These cover the streaming filter that must suppress ---MARKER--- control
//  blocks before they reach the UI.
//

import Testing
@testable import OsaurusCore

@Suite("OpenClawOutputFormatting")
struct OpenClawOutputFormattingTests {

    // MARK: - OpenClawControlBlockStreamFilter — basic passthrough

    @Test
    func streamFilter_passesRegularTextThrough() {
        var filter = OpenClawControlBlockStreamFilter()
        let result = filter.consume("Hello world")
        let tail = filter.finalize()
        #expect(result == "Hello world")
        #expect(tail.isEmpty)
    }

    // MARK: - COMPLETE_TASK block

    @Test
    func streamFilter_stripsCompleteTaskBlock_singleChunk() {
        var filter = OpenClawControlBlockStreamFilter()
        let input = "Before\n---COMPLETE_TASK_START---\n{\"summary\":\"done\"}\n---COMPLETE_TASK_END---\nAfter"
        let result = filter.consume(input) + filter.finalize()
        #expect(!result.contains("---COMPLETE_TASK_START---"))
        #expect(!result.contains("---COMPLETE_TASK_END---"))
        #expect(!result.contains("summary"))
        // stripping a block may leave an extra blank line; check meaningful content survives
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
        #expect(!result.contains("---"))
    }

    @Test
    func streamFilter_stripsCompleteTaskBlock_acrossChunks() {
        var filter = OpenClawControlBlockStreamFilter()
        let chunks = [
            "Some text\n",
            "---COMPLETE_TASK_START---\n",
            "{\"summary\":\"done\",\"success\":true}\n",
            "---COMPLETE_TASK_END---\n",
            "After",
        ]
        var combined = ""
        for chunk in chunks {
            combined += filter.consume(chunk)
        }
        combined += filter.finalize()
        #expect(!combined.contains("---COMPLETE_TASK_START---"))
        #expect(!combined.contains("summary"))
        #expect(combined.contains("Some text"))
        #expect(combined.contains("After"))
        #expect(!combined.contains("---"))
    }

    @Test
    func streamFilter_stripsCompleteTaskBlock_withArtifact() {
        // Bug 1 regression: artifact field containing backticks must not corrupt the filter
        var filter = OpenClawControlBlockStreamFilter()
        let input = """
            Thinking done.
            ---COMPLETE_TASK_START---
            {"summary":"ok","success":true,"artifact":"# Header\\n\\n```swift\\nlet x = 1\\n```"}
            ---COMPLETE_TASK_END---
            """
        let result = filter.consume(input) + filter.finalize()
        #expect(!result.contains("COMPLETE_TASK_START"))
        #expect(!result.contains("COMPLETE_TASK_END"))
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "Thinking done.")
    }

    // MARK: - REQUEST_CLARIFICATION block

    @Test
    func streamFilter_stripsClarificationBlock() {
        var filter = OpenClawControlBlockStreamFilter()
        let input =
            "---REQUEST_CLARIFICATION_START---\n{\"question\":\"what?\"}\n---REQUEST_CLARIFICATION_END---\nVisible"
        let result = filter.consume(input) + filter.finalize()
        #expect(!result.contains("REQUEST_CLARIFICATION"))
        #expect(result.contains("Visible"))
    }

    // MARK: - GENERATED_ARTIFACT block

    @Test
    func streamFilter_stripsGeneratedArtifactBlock() {
        var filter = OpenClawControlBlockStreamFilter()
        let input =
            "---GENERATED_ARTIFACT_START---\n{\"filename\":\"out.md\"}\ncontent here\n---GENERATED_ARTIFACT_END---"
        let result = filter.consume(input) + filter.finalize()
        #expect(!result.contains("GENERATED_ARTIFACT"))
        #expect(!result.contains("out.md"))
        #expect(!result.contains("content here"))
    }

    // MARK: - sanitizeVisibleText (post-hoc stripping for stored content)

    @Test
    func sanitizeVisibleText_stripsCompleteTaskBlock() {
        let raw = "Thinking...\n---COMPLETE_TASK_START---\n{\"summary\":\"done\"}\n---COMPLETE_TASK_END---"
        let result = OpenClawOutputFormatting.sanitizeVisibleText(raw)
        #expect(result == "Thinking...")
        #expect(!result.contains("COMPLETE_TASK"))
    }

    @Test
    func sanitizeVisibleText_preservesRegularMarkdown() {
        let raw = "# Hello\n\nThis is **bold** text."
        let result = OpenClawOutputFormatting.sanitizeVisibleText(raw)
        #expect(result == raw)
    }
}
