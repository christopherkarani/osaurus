//
//  OpenClawLogViewerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawLogViewerTests {
    @Test
    func parseLine_extractsLevelMessageTimestamp() {
        let payload = #"""
        {"ts": "2026-01-02T12:00:00Z", "level":"error", "message":"gateway refused"}
        """#
        let parsed = OpenClawLogParser.parseLine(payload)

        #expect(parsed?.level == .error)
        #expect(parsed?.message == "gateway refused")
        #expect(parsed?.timestamp != nil)
    }

    @Test
    func parseLine_ignoresInvalidJSON() {
        let parsed = OpenClawLogParser.parseLine("not a json object")
        #expect(parsed == nil)
    }

    @Test
    func parseJSONL_respectsLimitAndOrder() {
        let rawLines = (0..<4).map {
            "{\"level\":\"info\",\"message\":\"entry-\($0)\",\"ts\":\($0)}"
        }.joined(separator: "\n")
        let parsed = OpenClawLogParser.parseJSONL(rawLines, limit: 2)

        #expect(parsed.count == 2)
        #expect(parsed[0].message == "entry-2")
        #expect(parsed[1].message == "entry-3")
    }

    @Test
    func parseFilterByLevels() {
        let entries = [
            OpenClawLogEntry(level: .info, message: "i", timestamp: nil, rawLine: "i"),
            OpenClawLogEntry(level: .error, message: "e", timestamp: nil, rawLine: "e"),
            OpenClawLogEntry(level: .warning, message: "w", timestamp: nil, rawLine: "w"),
        ]

        let filtered = OpenClawLogParser.filter(entries, levels: [.error])
        #expect(filtered.count == 1)
        #expect(filtered.first?.message == "e")

        let unfiltered = OpenClawLogParser.filter(entries, levels: Set(OpenClawLogLevel.knownLevels))
        #expect(unfiltered.count == entries.count)
    }
}
