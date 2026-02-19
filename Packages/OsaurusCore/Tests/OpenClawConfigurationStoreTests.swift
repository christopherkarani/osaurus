//
//  OpenClawConfigurationStoreTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawConfigurationStoreTests {
    @Test @MainActor func loadMissing_returnsDefaults() throws {
        let temp = try makeTempDir(prefix: "openclaw-store-missing")
        defer { try? FileManager.default.removeItem(at: temp) }

        OpenClawConfigurationStore.overrideDirectory = temp
        defer { OpenClawConfigurationStore.overrideDirectory = nil }

        let loaded = OpenClawConfigurationStore.load()
        #expect(loaded == OpenClawConfiguration())
    }

    @Test @MainActor func saveAndLoad_roundTrips() throws {
        let temp = try makeTempDir(prefix: "openclaw-store-roundtrip")
        defer { try? FileManager.default.removeItem(at: temp) }

        OpenClawConfigurationStore.overrideDirectory = temp
        defer { OpenClawConfigurationStore.overrideDirectory = nil }

        let config = OpenClawConfiguration(
            isEnabled: true,
            gatewayPort: 19001,
            bindMode: .lan,
            autoStartGateway: false,
            installPath: "/custom/path",
            lastKnownVersion: "9.9.9"
        )
        OpenClawConfigurationStore.save(config)
        let loaded = OpenClawConfigurationStore.load()

        #expect(loaded == config)
    }

    @Test @MainActor func malformedFile_returnsDefaults() throws {
        let temp = try makeTempDir(prefix: "openclaw-store-malformed")
        defer { try? FileManager.default.removeItem(at: temp) }

        OpenClawConfigurationStore.overrideDirectory = temp
        defer { OpenClawConfigurationStore.overrideDirectory = nil }

        let file = temp.appendingPathComponent("openclaw.json")
        try "{not-valid-json".write(to: file, atomically: true, encoding: .utf8)

        let loaded = OpenClawConfigurationStore.load()
        #expect(loaded == OpenClawConfiguration())
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
