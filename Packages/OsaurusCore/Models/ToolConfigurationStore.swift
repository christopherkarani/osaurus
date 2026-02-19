//
//  ToolConfigurationStore.swift
//  osaurus
//
//  Persistence for ToolConfiguration
//

import Foundation

@MainActor
enum ToolConfigurationStore {
    /// Override the storage directory during testing. Set to nil to restore default.
    static var overrideDirectory: URL?

    static func load() -> ToolConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try JSONDecoder().decode(ToolConfiguration.self, from: Data(contentsOf: url))
            } catch {
                print("[Osaurus] Failed to load ToolConfiguration: \(error)")
            }
        }
        let defaults = ToolConfiguration()
        save(defaults)
        return defaults
    }

    static func save(_ configuration: ToolConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save ToolConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("ToolConfiguration.json")
        }
        return OsaurusPaths.resolveFile(new: OsaurusPaths.toolConfigFile(), legacy: "ToolConfiguration.json")
    }
}
