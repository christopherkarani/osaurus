//
//  OpenClawLaunchAgent.swift
//  osaurus
//

import Foundation

public enum OpenClawLaunchAgent {
    private static let launchAgentLabel = "ai.openclaw.gateway"

    struct Hooks {
        var runCommand: (_ command: [String]) async -> CommandOutput
    }

    struct CommandOutput: Sendable {
        let success: Bool
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated(unsafe) static var hooks: Hooks?

    public static func install(port: Int, bindMode: OpenClawConfiguration.BindMode) async -> String? {
        let result = await runGatewayCommand([
            "install",
            "--force",
            "--port",
            "\(port)",
            "--bind",
            bindMode.rawValue,
            "--json",
        ])
        return result.success ? nil : summarizeError(result)
    }

    public static func uninstall() async -> String? {
        let result = await runGatewayCommand(["uninstall", "--json"])
        return result.success ? nil : summarizeError(result)
    }

    public static func isLoaded() async -> Bool {
        let result = await runGatewayCommand(["status", "--json", "--no-probe"])
        guard result.success else { return false }
        guard let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        if let loaded = json["loaded"] as? Bool {
            return loaded
        }
        if let service = json["service"] as? [String: Any],
            let loaded = service["loaded"] as? Bool
        {
            return loaded
        }
        return false
    }

    public static func kickstart() async -> String? {
        let result = await runGatewayCommand(["restart", "--json"])
        return result.success ? nil : summarizeError(result)
    }

    public static func logPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistPath = home
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
        if let data = try? Data(contentsOf: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            if let stdout = plist["StandardOutPath"] as? String, !stdout.isEmpty {
                return stdout
            }
            if let stderr = plist["StandardErrorPath"] as? String, !stderr.isEmpty {
                return stderr
            }
        }
        return "/tmp/openclaw/openclaw-gateway.log"
    }

    private static func runGatewayCommand(_ args: [String]) async -> CommandOutput {
        if let hooks {
            return await hooks.runCommand(args)
        }

        let executable = OpenClawEnvironment.detectCLIPath() ?? "openclaw"
        let fullCommand = [executable, "gateway"] + args
        return await runCommand(fullCommand)
    }

    private static func runCommand(_ command: [String]) async -> CommandOutput {
        await Task.detached(priority: .utility) {
            guard let executable = command.first else {
                return CommandOutput(success: false, status: 1, stdout: "", stderr: "missing executable")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(command.dropFirst())

            var env = ProcessInfo.processInfo.environment
            if env["PATH"]?.isEmpty != false {
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
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

                let success = process.terminationStatus == 0
                return CommandOutput(
                    success: success,
                    status: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                )
            } catch {
                return CommandOutput(
                    success: false,
                    status: 1,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }
        }.value
    }

    private static func summarizeError(_ output: CommandOutput) -> String {
        if let jsonMessage = jsonError(output.stdout) ?? jsonError(output.stderr) {
            return jsonMessage
        }
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "gateway command failed (exit \(output.status))"
    }

    private static func jsonError(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}")
        else {
            return nil
        }
        let jsonText = String(trimmed[start...end])
        guard let data = jsonText.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
