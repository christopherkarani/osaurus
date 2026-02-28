//
//  OpenClawMCPBridge.swift
//  osaurus
//

import CryptoKit
import Foundation

public enum OpenClawMCPBridgeSyncMode: String, Sendable {
    case manual
    case automatic
}

public struct OpenClawMCPBridgeSyncResult: Sendable, Equatable {
    public let configPath: String
    public let syncedProviderCount: Int
    public let skippedProviderNames: [String]
    public let sourceFingerprint: String
    public let configSHA256: String
    public let driftDetected: Bool
    public let ownershipConflictDetected: Bool
    public let backupPath: String?
    public let syncedAt: Date

    public init(
        configPath: String,
        syncedProviderCount: Int,
        skippedProviderNames: [String],
        sourceFingerprint: String,
        configSHA256: String,
        driftDetected: Bool,
        ownershipConflictDetected: Bool,
        backupPath: String?,
        syncedAt: Date
    ) {
        self.configPath = configPath
        self.syncedProviderCount = syncedProviderCount
        self.skippedProviderNames = skippedProviderNames
        self.sourceFingerprint = sourceFingerprint
        self.configSHA256 = configSHA256
        self.driftDetected = driftDetected
        self.ownershipConflictDetected = ownershipConflictDetected
        self.backupPath = backupPath
        self.syncedAt = syncedAt
    }
}

public enum OpenClawMCPBridgeError: LocalizedError, Sendable {
    case unownedConfig(path: String)

    public var errorDescription: String? {
        switch self {
        case .unownedConfig(let path):
            return "Refusing auto-sync because existing MCP bridge config is not Osaurus-owned: \(path). Run a manual sync to adopt ownership."
        }
    }
}

enum OpenClawMCPBridge {
    struct ProviderEntry: Sendable, Equatable {
        let name: String
        let url: String
        let headers: [String: String]
    }

    private struct MCPorterConfig: Codable, Sendable {
        let imports: [String]
        let mcpServers: [String: MCPServer]
    }

    private struct MCPServer: Codable, Sendable {
        let description: String?
        let baseUrl: String
        let headers: [String: String]?
    }

    private struct BridgeMetadata: Codable, Sendable {
        let owner: String
        let schemaVersion: Int
        let sourceFingerprint: String
        let configSHA256: String
        let updatedAt: Date
        let mode: String
    }

    private static let ownerMarker = "ai.osaurus.openclaw.mcp-bridge"
    private static let schemaVersion = 1
    private static let secureFileMode = 0o600

    static func defaultConfigFileURL() -> URL {
        OsaurusPaths.providers().appendingPathComponent("openclaw-mcporter.json")
    }

    static func writeConfig(
        providers: [ProviderEntry],
        to fileURL: URL,
        mode: OpenClawMCPBridgeSyncMode,
        allowUnownedOverwrite: Bool
    ) throws -> OpenClawMCPBridgeSyncResult {
        let startedAt = Date()
        let providerCount = providers.count
        let modeValue = mode.rawValue
        let targetPath = fileURL.path
        let (config, skippedProviderNames) = buildConfig(providers: providers)
        let sourceFingerprint = try sourceFingerprint(for: providers)
        let metadataURL = metadataFileURL(for: fileURL)
        let backupURL = backupFileURL(for: fileURL)
        let backupMetadataURL = backupMetadataFileURL(for: fileURL)

        let fm = FileManager.default
        let configExists = fm.fileExists(atPath: fileURL.path)
        let existingMetadata = try loadMetadata(from: metadataURL)
        let isOwned = existingMetadata?.owner == ownerMarker
        let ownershipConflictDetected = configExists && !isOwned

        if ownershipConflictDetected, mode == .automatic, !allowUnownedOverwrite {
            throw OpenClawMCPBridgeError.unownedConfig(path: fileURL.path)
        }

        let previousConfigHash = try sha256IfFileExists(fileURL)
        let previousMetadataHash = existingMetadata?.configSHA256
        let driftDetected = isOwned && previousConfigHash != nil && previousConfigHash != previousMetadataHash

        var backupPath: String?
        if configExists {
            try backupFile(from: fileURL, to: backupURL)
            try setSecurePermissions(for: backupURL)
            backupPath = backupURL.path

            if fm.fileExists(atPath: metadataURL.path) {
                try backupFile(from: metadataURL, to: backupMetadataURL)
                try setSecurePermissions(for: backupMetadataURL)
            } else if fm.fileExists(atPath: backupMetadataURL.path) {
                try? fm.removeItem(at: backupMetadataURL)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var configData = try encoder.encode(config)
        if configData.last != 0x0A {
            configData.append(0x0A)
        }

        OsaurusPaths.ensureExistsSilent(fileURL.deletingLastPathComponent())
        try configData.write(to: fileURL, options: [.atomic])
        try setSecurePermissions(for: fileURL)

        let configSHA256 = sha256Hex(configData)
        let now = Date()
        let metadata = BridgeMetadata(
            owner: ownerMarker,
            schemaVersion: schemaVersion,
            sourceFingerprint: sourceFingerprint,
            configSHA256: configSHA256,
            updatedAt: now,
            mode: mode.rawValue
        )
        var metadataData = try encoder.encode(metadata)
        if metadataData.last != 0x0A {
            metadataData.append(0x0A)
        }
        try metadataData.write(to: metadataURL, options: [.atomic])
        try setSecurePermissions(for: metadataURL)

        let result = OpenClawMCPBridgeSyncResult(
            configPath: fileURL.path,
            syncedProviderCount: config.mcpServers.count,
            skippedProviderNames: skippedProviderNames,
            sourceFingerprint: sourceFingerprint,
            configSHA256: configSHA256,
            driftDetected: driftDetected,
            ownershipConflictDetected: ownershipConflictDetected,
            backupPath: backupPath,
            syncedAt: now
        )
        _ = providerCount
        _ = modeValue
        _ = targetPath
        _ = startedAt
        return result
    }

    static func rollbackToBackup(configFileURL: URL) throws -> Bool {
        let startedAt = Date()
        let configPath = configFileURL.path
        let backupURL = backupFileURL(for: configFileURL)
        let metadataURL = metadataFileURL(for: configFileURL)
        let backupMetadataURL = backupMetadataFileURL(for: configFileURL)
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupURL.path) else {
            return false
        }

        if fm.fileExists(atPath: configFileURL.path) {
            try fm.removeItem(at: configFileURL)
        }
        try fm.copyItem(at: backupURL, to: configFileURL)
        try setSecurePermissions(for: configFileURL)

        if fm.fileExists(atPath: backupMetadataURL.path) {
            if fm.fileExists(atPath: metadataURL.path) {
                try fm.removeItem(at: metadataURL)
            }
            try fm.copyItem(at: backupMetadataURL, to: metadataURL)
            try setSecurePermissions(for: metadataURL)
        }
        _ = configPath
        _ = startedAt
        return true
    }

    static func readMetadata(fileURL: URL) -> (owner: String, sourceFingerprint: String, updatedAt: Date)? {
        let metadataURL = metadataFileURL(for: fileURL)
        guard let metadata = try? loadMetadata(from: metadataURL) else {
            return nil
        }
        return (metadata.owner, metadata.sourceFingerprint, metadata.updatedAt)
    }

    private static func loadMetadata(from url: URL) throws -> BridgeMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BridgeMetadata.self, from: data)
    }

    private static func buildConfig(
        providers: [ProviderEntry]
    ) -> (MCPorterConfig, [String]) {
        var mcpServers: [String: MCPServer] = [:]
        var skippedProviderNames: [String] = []
        var usedServerIDs: Set<String> = []

        for provider in providers {
            let trimmedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = provider.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedName.isEmpty ? "unnamed-provider" : trimmedName

            guard !trimmedURL.isEmpty,
                  let endpoint = URL(string: trimmedURL),
                  let scheme = endpoint.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                skippedProviderNames.append(displayName)
                continue
            }

            let serverID = uniqueServerID(for: displayName, used: &usedServerIDs)
            let normalizedHeaders = normalizeHeaders(provider.headers)

            mcpServers[serverID] = MCPServer(
                description: "Synced from Osaurus MCP provider: \(displayName)",
                baseUrl: trimmedURL,
                headers: normalizedHeaders.isEmpty ? nil : normalizedHeaders
            )
        }

        let config = MCPorterConfig(
            imports: [],
            mcpServers: mcpServers
        )
        return (config, skippedProviderNames.sorted())
    }

    private static func sourceFingerprint(for providers: [ProviderEntry]) throws -> String {
        struct CanonicalProvider: Codable {
            let name: String
            let url: String
            let headers: [String: String]
        }

        let canonical = providers
            .map {
                CanonicalProvider(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines),
                    headers: normalizeHeaders($0.headers)
                )
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                if $0.url != $1.url { return $0.url < $1.url }
                return $0.headers.description < $1.headers.description
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        return sha256Hex(data)
    }

    private static func metadataFileURL(for configFileURL: URL) -> URL {
        let baseName = configFileURL.deletingPathExtension().lastPathComponent
        return configFileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).meta.json")
    }

    private static func backupFileURL(for configFileURL: URL) -> URL {
        let baseName = configFileURL.deletingPathExtension().lastPathComponent
        return configFileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).backup.json")
    }

    private static func backupMetadataFileURL(for configFileURL: URL) -> URL {
        let baseName = configFileURL.deletingPathExtension().lastPathComponent
        return configFileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).backup.meta.json")
    }

    private static func backupFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func sha256IfFileExists(_ fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: secureFileMode],
            ofItemAtPath: url.path
        )
    }

    private static func normalizeHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawKey, rawValue) in headers {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            normalized[key] = value
        }
        return normalized
    }

    private static func uniqueServerID(for name: String, used: inout Set<String>) -> String {
        let base = sanitizedServerID(from: name)
        if !used.contains(base) {
            used.insert(base)
            return base
        }

        var index = 2
        while used.contains("\(base)-\(index)") {
            index += 1
        }
        let candidate = "\(base)-\(index)"
        used.insert(candidate)
        return candidate
    }

    private static func sanitizedServerID(from raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let normalized = raw.lowercased().map { char -> Character in
            if allowed.contains(char) {
                return char
            }
            return "-"
        }

        var collapsed: [Character] = []
        for char in normalized {
            if char == "-", collapsed.last == "-" {
                continue
            }
            collapsed.append(char)
        }

        while collapsed.first == "-" {
            collapsed.removeFirst()
        }
        while collapsed.last == "-" {
            collapsed.removeLast()
        }

        let value = String(collapsed)
        return value.isEmpty ? "provider" : value
    }
}
