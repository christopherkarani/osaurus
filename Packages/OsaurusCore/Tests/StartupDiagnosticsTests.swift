//
//  StartupDiagnosticsTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StartupDiagnosticsTests {
    @Test
    func emit_writesJsonlWithSharedStartupRunId() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-diagnostics-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let diagnostics = StartupDiagnostics(
            outputURL: outputURL,
            startupRunId: "startup-run-1",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        await diagnostics.emit(component: "app", event: "startup.begin", context: ["phase": "launch"])
        await diagnostics.emit(level: .warning, component: "provider", event: "connect.failed", context: ["status": "500"])

        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = raw.split(separator: "\n")
        #expect(lines.count == 2)

        let decoded = try lines.map { line in
            try JSONDecoder().decode(StartupDiagnosticRecord.self, from: Data(line.utf8))
        }

        #expect(decoded.allSatisfy { $0.startupRunId == "startup-run-1" })
        #expect(decoded[0].event == "startup.begin")
        #expect(decoded[1].level == "warning")
    }

    @Test
    func emit_redactsSecretsAndTruncatesLongValues() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-diagnostics-redaction-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let diagnostics = StartupDiagnostics(
            outputURL: outputURL,
            startupRunId: "startup-run-2"
        )

        let longPreview = String(repeating: "a", count: 400)
        await diagnostics.emit(
            level: .error,
            component: "remote-provider",
            event: "models.decode.failed",
            context: [
                "apiToken": "super-secret-token",
                "Authorization": "Bearer very-secret-value",
                "bodyPreview": longPreview,
            ]
        )

        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        guard let firstLine = raw.split(separator: "\n").first else {
            Issue.record("Expected a diagnostics line")
            return
        }
        let decoded = try JSONDecoder().decode(StartupDiagnosticRecord.self, from: Data(firstLine.utf8))

        #expect(decoded.context["apiToken"] == "<redacted>")
        #expect(decoded.context["Authorization"] == "<redacted>")
        #expect(decoded.context["bodyPreview"]?.contains("...(truncated)") == true)
    }
}
