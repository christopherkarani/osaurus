//
//  OpenClawInstaller.swift
//  osaurus
//

import Foundation

public enum OpenClawInstaller {
    struct Hooks {
        var searchPaths: () -> [String]
        var runInstallCommand: (_ command: [String]) throws -> CommandOutput
    }

    struct CommandOutput: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct InstallEvent: Decodable {
        let event: String
        let version: String?
        let message: String?
    }

    nonisolated(unsafe) static var hooks: Hooks?

    public static func isInstalled() -> Bool {
        installedLocation() != nil
    }

    public static func installedLocation() -> String? {
        let fm = FileManager.default
        for path in searchPaths() {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("openclaw").path
            guard fm.fileExists(atPath: candidate), fm.isExecutableFile(atPath: candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    public static func install(onProgress: @escaping @Sendable (String) -> Void) async throws {
        onProgress("Installing openclaw CLI…")
        let command = installScriptCommand()
        let output = try runInstallCommand(command)
        let events = parseInstallEvents(output.stdout)

        for event in events {
            if let message = event.message, !message.isEmpty {
                onProgress(message)
            }
        }

        if output.status == 0 {
            if let done = events.last(where: { $0.event == "done" }),
                let version = done.version,
                !version.isEmpty
            {
                onProgress("Installed openclaw \(version).")
            } else {
                onProgress("Installed openclaw.")
            }
            return
        }

        if let errorEvent = events.last(where: { $0.event == "error" }),
            let message = errorEvent.message,
            !message.isEmpty
        {
            throw NSError(
                domain: "OpenClawInstaller",
                code: Int(output.status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "OpenClawInstaller",
            code: Int(output.status),
            userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "install failed" : stderr]
        )
    }

    private static func searchPaths() -> [String] {
        if let hooks {
            return hooks.searchPaths()
        }
        let defaultPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return defaultPaths + [
            "\(home)/.openclaw/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
    }

    private static func installScriptCommand() -> [String] {
        let prefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
            .path
        let script = """
        curl -fsSL https://openclaw.bot/install-cli.sh | \
        bash -s -- --json --no-onboard --prefix \(shellEscape(prefix))
        """
        return ["/bin/bash", "-lc", script]
    }

    private static func runInstallCommand(_ command: [String]) throws -> CommandOutput {
        if let hooks {
            return try hooks.runInstallCommand(command)
        }

        guard let executable = command.first else {
            throw NSError(
                domain: "OpenClawInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing install executable"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return CommandOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func parseInstallEvents(_ output: String) -> [InstallEvent] {
        let decoder = JSONDecoder()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(InstallEvent.self, from: data)
            }
    }

    private static func shellEscape(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
