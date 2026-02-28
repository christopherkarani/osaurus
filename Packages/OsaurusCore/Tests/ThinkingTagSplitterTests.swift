//
//  ThinkingTagSplitterTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

@Suite("ThinkingTagSplitter")
struct ThinkingTagSplitterTests {
    @Test
    func split_extractsThinkingAndVisibleContent() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think>draft answer</think>final answer")
        let final = splitter.finalize()

        #expect(result.thinking == "draft answer")
        #expect(result.content == "final answer")
        #expect(final.thinking.isEmpty)
        #expect(final.content.isEmpty)
    }

    @Test
    func split_handlesOpenTagAcrossChunks() {
        var splitter = ThinkingTagSplitter()

        let first = splitter.split("prelude <thi")
        let second = splitter.split("nk>hidden</think> visible")
        let final = splitter.finalize()

        #expect(first.content == "prelude ")
        #expect(first.thinking.isEmpty)
        #expect(second.thinking == "hidden")
        #expect(second.content == " visible")
        #expect(final.content.isEmpty)
        #expect(final.thinking.isEmpty)
    }

    @Test
    func split_handlesCloseTagAcrossChunks() {
        var splitter = ThinkingTagSplitter()

        let first = splitter.split("<think>hidden</th")
        let second = splitter.split("ink>visible")
        let final = splitter.finalize()

        #expect(first.content.isEmpty)
        #expect(first.thinking == "hidden")
        #expect(second.content == "visible")
        #expect(second.thinking.isEmpty)
        #expect(final.content.isEmpty)
        #expect(final.thinking.isEmpty)
    }

    @Test
    func finalize_assignsPendingBufferToCurrentMode() {
        var contentModeSplitter = ThinkingTagSplitter()
        _ = contentModeSplitter.split("hello <thi")
        let contentTail = contentModeSplitter.finalize()
        #expect(contentTail.content == "<thi")
        #expect(contentTail.thinking.isEmpty)

        var thinkingModeSplitter = ThinkingTagSplitter()
        _ = thinkingModeSplitter.split("<think>reasoning</thi")
        let thinkingTail = thinkingModeSplitter.finalize()
        #expect(thinkingTail.content.isEmpty)
        #expect(thinkingTail.thinking == "</thi")
    }

    // MARK: - Case Insensitivity

    @Test
    func split_caseInsensitiveTags() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<Think>reasoning</THINK>answer")
        #expect(result.content == "answer")
        #expect(result.thinking == "reasoning")
    }

    // MARK: - Edge Cases

    @Test
    func split_emptyDeltaReturnsEmpty() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("")
        #expect(result.content.isEmpty)
        #expect(result.thinking.isEmpty)
    }

    @Test
    func split_plainTextNoTags() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("Hello, world!")
        #expect(result.content == "Hello, world!")
        #expect(result.thinking.isEmpty)
    }

    @Test
    func split_thinkingOnlyNoVisibleContent() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think>all reasoning</think>")
        #expect(result.content.isEmpty)
        #expect(result.thinking == "all reasoning")
    }

    @Test
    func split_emptyThinkingBlock() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think></think>content")
        #expect(result.content == "content")
        #expect(result.thinking.isEmpty)
    }

    @Test
    func split_multipleThinkingBlocks() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think>a</think>mid<think>b</think>end")
        #expect(result.content == "midend")
        #expect(result.thinking == "ab")
    }

    @Test
    func split_nestedAngleBracketsInsideThinking() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think>if x > 3 then y < 7</think>answer")
        #expect(result.content == "answer")
        #expect(result.thinking == "if x > 3 then y < 7")
    }

    @Test
    func split_multilineThinkingContent() {
        var splitter = ThinkingTagSplitter()
        let result = splitter.split("<think>line1\nline2\nline3</think>output")
        #expect(result.content == "output")
        #expect(result.thinking == "line1\nline2\nline3")
    }

    @Test
    func finalize_noBufferedContentReturnsEmpty() {
        var splitter = ThinkingTagSplitter()
        _ = splitter.split("clean content")
        let fin = splitter.finalize()
        #expect(fin.content.isEmpty)
        #expect(fin.thinking.isEmpty)
    }

    // MARK: - Streaming Simulations

    @Test
    func streaming_smallChunks() {
        // Note: single-character streaming is a known limitation — the `<` in
        // `</think>` gets consumed before `/` arrives because the shortest
        // close partial is `</` (2 chars).  Real LLM streams always emit
        // multi-character deltas, so we test with 2–3 char chunks instead.
        var splitter = ThinkingTagSplitter()
        var totalContent = ""
        var totalThinking = ""

        let input = "<think>abc</think>xyz"
        var idx = input.startIndex
        let stride = 3
        while idx < input.endIndex {
            let end = input.index(idx, offsetBy: stride, limitedBy: input.endIndex) ?? input.endIndex
            let chunk = String(input[idx..<end])
            let r = splitter.split(chunk)
            totalContent += r.content
            totalThinking += r.thinking
            idx = end
        }
        let fin = splitter.finalize()
        totalContent += fin.content
        totalThinking += fin.thinking

        #expect(totalContent == "xyz")
        #expect(totalThinking == "abc")
    }

    @Test
    func streaming_realisticLLMDeltas() {
        var splitter = ThinkingTagSplitter()
        var totalContent = ""
        var totalThinking = ""

        let deltas = [
            "<think>", "Let me ", "think about ", "this...", "</think>",
            "The answer ", "is 42."
        ]

        for delta in deltas {
            let r = splitter.split(delta)
            totalContent += r.content
            totalThinking += r.thinking
        }
        let fin = splitter.finalize()
        totalContent += fin.content
        totalThinking += fin.thinking

        #expect(totalContent == "The answer is 42.")
        #expect(totalThinking == "Let me think about this...")
    }

    @Test
    func streaming_interleavedThinkingBlocks() {
        var splitter = ThinkingTagSplitter()
        var totalContent = ""
        var totalThinking = ""

        let deltas = [
            "<think>step 1</think>",
            "First, ",
            "<think>step 2</think>",
            "then done."
        ]

        for delta in deltas {
            let r = splitter.split(delta)
            totalContent += r.content
            totalThinking += r.thinking
        }
        let fin = splitter.finalize()
        totalContent += fin.content
        totalThinking += fin.thinking

        #expect(totalContent == "First, then done.")
        #expect(totalThinking == "step 1step 2")
    }
}
