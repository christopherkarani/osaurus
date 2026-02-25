//
//  OpenClawMCPBridgeTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawMCPBridgeTests {
    @Test
    func writeConfig_generatesMCPorterShapeWithUniqueServerIDs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-mcporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let providers: [OpenClawMCPBridge.ProviderEntry] = [
            .init(
                name: "Linear MCP",
                url: "https://mcp.example.com/sse",
                headers: ["X-API-Key": "abc123", "Empty": "   "]
            ),
            .init(
                name: "Linear MCP",
                url: "https://mcp-2.example.com/sse",
                headers: [:]
            ),
            .init(
                name: "Broken URL",
                url: "not-a-url",
                headers: [:]
            ),
        ]

        let result = try OpenClawMCPBridge.writeConfig(
            providers: providers,
            to: outputURL,
            mode: .manual,
            allowUnownedOverwrite: true
        )
        #expect(result.syncedProviderCount == 2)
        #expect(result.skippedProviderNames == ["Broken URL"])
        #expect(result.configPath == outputURL.path)
        #expect(result.configSHA256.count == 64)
        #expect(result.sourceFingerprint.count == 64)
        #expect(result.backupPath == nil)
        #expect(result.driftDetected == false)
        #expect(result.ownershipConflictDetected == false)

        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let imports = json?["imports"] as? [Any]
        let servers = json?["mcpServers"] as? [String: Any]

        #expect(imports?.isEmpty == true)
        #expect(servers?.count == 2)
        #expect(servers?["linear-mcp"] != nil)
        #expect(servers?["linear-mcp-2"] != nil)

        let firstServer = servers?["linear-mcp"] as? [String: Any]
        #expect(firstServer?["baseUrl"] as? String == "https://mcp.example.com/sse")
        let headers = firstServer?["headers"] as? [String: String]
        #expect(headers?["X-API-Key"] == "abc123")
        #expect(headers?["Empty"] == nil)

        let metadata = OpenClawMCPBridge.readMetadata(fileURL: outputURL)
        #expect(metadata?.owner == "ai.osaurus.openclaw.mcp-bridge")
        #expect(metadata?.sourceFingerprint == result.sourceFingerprint)
        #expect(metadata?.updatedAt != nil)
    }

    @Test
    func writeConfig_withNoProviders_writesEmptyServerMap() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-mcporter-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let result = try OpenClawMCPBridge.writeConfig(
            providers: [],
            to: outputURL,
            mode: .manual,
            allowUnownedOverwrite: true
        )

        #expect(result.syncedProviderCount == 0)
        #expect(result.skippedProviderNames.isEmpty)

        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = json?["mcpServers"] as? [String: Any]
        #expect(servers?.isEmpty == true)
    }

    @Test
    func writeConfig_automaticModeRejectsUnownedConfigWithoutOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-mcporter-unowned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let legacyConfig = """
        {"imports":[],"mcpServers":{"legacy":{"baseUrl":"https://legacy.example.com/sse"}}}
        """
        guard let legacyData = legacyConfig.data(using: .utf8) else {
            Issue.record("Failed to encode legacy config fixture")
            return
        }
        try legacyData.write(to: outputURL)

        #expect(throws: OpenClawMCPBridgeError.self) {
            _ = try OpenClawMCPBridge.writeConfig(
                providers: [.init(name: "Example", url: "https://mcp.example.com/sse", headers: [:])],
                to: outputURL,
                mode: .automatic,
                allowUnownedOverwrite: false
            )
        }
    }

    @Test
    func writeConfig_detectsDriftAndRollbackRestoresBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-mcporter-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let providers: [OpenClawMCPBridge.ProviderEntry] = [
            .init(name: "Example", url: "https://mcp.example.com/sse", headers: [:])
        ]
        _ = try OpenClawMCPBridge.writeConfig(
            providers: providers,
            to: outputURL,
            mode: .manual,
            allowUnownedOverwrite: true
        )

        let driftedContent = """
        {"imports":[],"mcpServers":{"drifted":{"baseUrl":"https://drifted.example.com/sse"}}}
        """
        guard let driftedData = driftedContent.data(using: .utf8) else {
            Issue.record("Failed to encode drifted config fixture")
            return
        }
        try driftedData.write(to: outputURL)

        let second = try OpenClawMCPBridge.writeConfig(
            providers: providers,
            to: outputURL,
            mode: .manual,
            allowUnownedOverwrite: true
        )
        #expect(second.driftDetected == true)
        #expect(second.backupPath != nil)

        let rolledBack = try OpenClawMCPBridge.rollbackToBackup(configFileURL: outputURL)
        #expect(rolledBack == true)

        let restoredData = try Data(contentsOf: outputURL)
        let restoredString = String(data: restoredData, encoding: .utf8) ?? ""
        #expect(restoredString.contains("drifted.example.com"))
    }
}
