//
//  OpenClawConfigurationStore.swift
//  osaurus
//

import Foundation

@MainActor
public enum OpenClawConfigurationStore {
    /// Optional directory override for tests.
    public static var overrideDirectory: URL?

    private static var configURL: URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("openclaw.json")
        }
        return OsaurusPaths.config().appendingPathComponent("openclaw.json")
    }

    public static func load(from url: URL? = nil) -> OpenClawConfiguration {
        let fileURL = url ?? configURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return OpenClawConfiguration()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(OpenClawConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load OpenClawConfiguration: \(error)")
            return OpenClawConfiguration()
        }
    }

    public static func save(_ config: OpenClawConfiguration, to url: URL? = nil) {
        let fileURL = url ?? configURL
        OsaurusPaths.ensureExistsSilent(fileURL.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save OpenClawConfiguration: \(error)")
        }
    }
}
