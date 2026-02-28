//
//  DiffParserTests.swift
//  osaurus
//

import Foundation
import Testing
@testable import OsaurusCore

@Suite("DiffParser")
struct DiffParserTests {

    @Test func parsesHunkHeader() {
        let diff = "@@ -1,4 +1,5 @@\n context\n-removed\n+added\n context"
        let lines = DiffParser.parse(diff)
        #expect(lines.count == 5)
    }

    @Test func classifiesAddedLine() {
        let diff = "@@ -1 +1,2 @@\n+new line"
        let lines = DiffParser.parse(diff)
        let added = lines.filter { $0.kind == .added }
        #expect(added.count == 1)
        #expect(added.first?.text == "new line")
    }

    @Test func classifiesRemovedLine() {
        let diff = "@@ -1,2 +1 @@\n-old line\n kept"
        let lines = DiffParser.parse(diff)
        let removed = lines.filter { $0.kind == .removed }
        #expect(removed.count == 1)
    }

    @Test func classifiesContextLine() {
        let diff = "@@ -1 +1 @@\n unchanged"
        let lines = DiffParser.parse(diff)
        let context = lines.filter { $0.kind == .context }
        #expect(context.count == 1)
    }

    @Test func skipsHunkHeaders() {
        let diff = "@@ -1,2 +1,2 @@\n context\n-old\n+new"
        let lines = DiffParser.parse(diff)
        let headers = lines.filter { $0.kind == .header }
        #expect(headers.count == 1)
    }

    @Test func handlesEmptyString() {
        #expect(DiffParser.parse("").isEmpty)
    }

    @Test func detectsDiff() {
        #expect(DiffParser.isDiff("@@ -1 +1 @@\n+line") == true)
        #expect(DiffParser.isDiff("regular output text") == false)
    }
}
