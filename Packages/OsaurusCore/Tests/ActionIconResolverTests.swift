//
//  ActionIconResolverTests.swift
//  osaurus
//

import Foundation
import Testing
@testable import OsaurusCore

@Suite("ActionIconResolver")
struct ActionIconResolverTests {

    @Test @MainActor func staticFallbackReturnsImmediately() async {
        let resolver = ActionIconResolver()
        let icon = resolver.icon(
            toolName: "read_file",
            arguments: "{\"path\": \"/main.swift\"}",
            thinkingContext: nil
        )
        #expect(icon == "doc.text")
    }

    @Test func cacheKeyIsStable() {
        let key1 = ActionIconResolver.cacheKey(toolName: "bash", arguments: "{\"command\": \"ls\"}")
        let key2 = ActionIconResolver.cacheKey(toolName: "bash", arguments: "{\"command\": \"ls\"}")
        #expect(key1 == key2)
    }

    @Test func differentArgsDifferentKeys() {
        let key1 = ActionIconResolver.cacheKey(toolName: "bash", arguments: "{\"command\": \"ls\"}")
        let key2 = ActionIconResolver.cacheKey(toolName: "bash", arguments: "{\"command\": \"pwd\"}")
        #expect(key1 != key2)
    }

    @Test func curatedSymbolListIsNonEmpty() {
        #expect(!ActionIconResolver.curatedSymbols.isEmpty)
        #expect(ActionIconResolver.curatedSymbols.contains("terminal"))
    }

    @Test func promptFormattingIncludesToolName() {
        let prompt = ActionIconResolver.buildPrompt(
            toolName: "web_search",
            arguments: "{\"query\": \"Swift\"}",
            thinkingContext: "Let me search for Swift patterns"
        )
        #expect(prompt.contains("web_search"))
        #expect(prompt.contains("Swift"))
    }
}
