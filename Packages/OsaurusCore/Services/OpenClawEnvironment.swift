//
//  OpenClawEnvironment.swift
//  osaurus
//

import Foundation

public struct Semver: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Semver, rhs: Semver) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func parse(_ raw: String?) -> Semver? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let parts = cleaned.split(separator: ".")
        guard parts.count >= 3,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else {
            return nil
        }

        let patchToken = parts[2].split(separator: "-").first?.split(separator: "+").first
        guard let patchString = patchToken, let patch = Int(patchString) else { return nil }
        return Semver(major: major, minor: minor, patch: patch)
    }

    public func compatible(with required: Semver) -> Bool {
        major == required.major && self >= required
    }
}

public enum OpenClawEnvironmentStatus: Equatable, Sendable {
    case checking
    case ready(nodeVersion: String, cliVersion: String)
    case missingNode
    case missingCLI
    case incompatibleVersion(found: String, required: String)
    case error(String)
}

public enum OpenClawEnvironment {
    struct Hooks {
        var detectNodePath: () -> String?
        var detectCLIPath: () -> String?
        var versionForExecutable: (String) -> String?
        var requiredCLIVersion: () -> String?
    }

    nonisolated(unsafe) static var hooks: Hooks?

    public static func check() async -> OpenClawEnvironmentStatus {
        await Task.detached(priority: .utility) {
            checkSync()
        }.value
    }

    public static func detectNodePath() -> String? {
        if let hooks {
            return hooks.detectNodePath()
        }
        return detectExecutable(named: "node")
    }

    public static func detectCLIPath() -> String? {
        if let hooks {
            return hooks.detectCLIPath()
        }
        if let path = detectExecutable(named: "openclaw") {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localCLI = home.appendingPathComponent(".openclaw/bin/openclaw").path
        if FileManager.default.isExecutableFile(atPath: localCLI) {
            return localCLI
        }
        return nil
    }

    public static func gatewayPort(from config: OpenClawConfiguration) -> Int {
        config.gatewayPort > 0 ? config.gatewayPort : 18789
    }

    private static func checkSync() -> OpenClawEnvironmentStatus {
        guard let nodePath = detectNodePath() else {
            return .missingNode
        }
        guard let cliPath = detectCLIPath() else {
            return .missingCLI
        }

        let nodeVersion = version(for: nodePath) ?? "unknown"
        let cliVersion = version(for: cliPath) ?? "unknown"

        if let requiredRaw = requiredCLIVersion(),
            let required = Semver.parse(requiredRaw),
            let found = Semver.parse(cliVersion),
            !found.compatible(with: required)
        {
            return .incompatibleVersion(found: found.description, required: required.description)
        }

        return .ready(nodeVersion: nodeVersion, cliVersion: cliVersion)
    }

    private static func requiredCLIVersion() -> String? {
        if let hooks {
            return hooks.requiredCLIVersion()
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func version(for executablePath: String) -> String? {
        if let hooks {
            return hooks.versionForExecutable(executablePath)
        }
        guard let output = commandOutput(executablePath: executablePath, arguments: ["--version"]) else {
            return nil
        }
        return normalizedVersion(from: output)
    }

    private static func detectExecutable(named name: String) -> String? {
        let fm = FileManager.default
        for directory in candidateSearchDirectories() {
            let candidate = directory.appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        if let which = commandOutput(executablePath: "/usr/bin/which", arguments: [name])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !which.isEmpty,
            fm.isExecutableFile(atPath: which)
        {
            return which
        }

        return nil
    }

    private static func candidateSearchDirectories() -> [URL] {
        let fm = FileManager.default
        var directories: [URL] = []

        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories.append(contentsOf: envPaths)

        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/bin", isDirectory: true))

        let home = fm.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".openclaw/bin", isDirectory: true))
        directories.append(home.appendingPathComponent(".volta/bin", isDirectory: true))

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fm.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) {
            let bins = versions
                .map { $0.appendingPathComponent("bin", isDirectory: true) }
                .filter { fm.fileExists(atPath: $0.path) }
            directories.append(contentsOf: bins)
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.path).inserted }
    }

    private static func commandOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func normalizedVersion(from raw: String) -> String {
        if let match = raw.range(of: "v?\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
            return String(raw[match]).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
