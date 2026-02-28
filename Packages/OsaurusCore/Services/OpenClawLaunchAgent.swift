//
//  OpenClawLaunchAgent.swift
//  osaurus
//

import Foundation
import Terra

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

    public static func install(port: Int, bindMode: OpenClawConfiguration.BindMode, token: String? = nil) async -> String? {
        var args = ["install", "--force", "--port", "\(port)", "--bind", bindMode.rawValue, "--json"]
        if let token, !token.isEmpty {
            args += ["--token", token]
        }
        let result = await runGatewayCommand(args)
        return result.success ? nil : summarizeError(result)
    }

    public static func uninstall() async -> String? {
        let result = await runGatewayCommand(["uninstall", "--json"])
        if result.success { return nil }
        // Fallback: force-remove via launchctl bootout (handles lock-held / KeepAlive cases)
        let uid = getuid()
        let bootout = await runCommand([
            "/bin/launchctl", "bootout", "gui/\(uid)/\(launchAgentLabel)",
        ])
        return bootout.success ? nil : summarizeError(result)
    }

    /// Kills any process currently listening on `port` via SIGTERM, then waits
    /// up to `waitMs` milliseconds for the port to become free.
    public static func killProcessOnPort(_ port: Int, waitMs: Int = 1500) async {
        let startedAt = Date()
        await Task.detached(priority: .utility) {
            // lsof -ti :<port> prints the PID(s) listening on that port
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-ti", ":\(port)"]
            let pipe = Pipe()
            lsof.standardOutput = pipe
            lsof.standardError = Pipe()
            guard (try? lsof.run()) != nil else { return }
            lsof.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for pidStr in output.split(whereSeparator: \.isNewline) {
                if let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    kill(pid, SIGTERM)
                }
            }
            // Wait for the port to be vacated
            let deadline = Date().addingTimeInterval(Double(waitMs) / 1000)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                check.arguments = ["-ti", ":\(port)"]
                check.standardOutput = Pipe()
                check.standardError = Pipe()
                guard (try? check.run()) != nil else { break }
                check.waitUntilExit()
                if check.terminationStatus != 0 { break }  // port is free
            }
        }.value
        _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.launchagent.kill_port", id: nil)) {
            scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.launchagent.port": .int(port),
                "osaurus.openclaw.launchagent.wait_ms": .int(waitMs),
                "osaurus.openclaw.launchagent.latency_ms": .double(Date().timeIntervalSince(startedAt) * 1000),
            ])
        }
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
        let startedAt = Date()
        if let hooks {
            let output = await hooks.runCommand(args)
            _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.launchagent.command", id: nil)) {
                scope in
                scope.setAttributes([
                    Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                    Terra.Keys.Terra.openClawGateway: .bool(true),
                    Terra.Keys.GenAI.providerName: .string("openclaw"),
                    "osaurus.openclaw.launchagent.command": .string("hook"),
                    "osaurus.openclaw.launchagent.args.count": .int(args.count),
                    "osaurus.openclaw.launchagent.success": .bool(output.success),
                    "osaurus.openclaw.launchagent.status": .int(Int(output.status)),
                    "osaurus.openclaw.launchagent.latency_ms": .double(Date().timeIntervalSince(startedAt) * 1000),
                ])
            }
            return output
        }

        let executable = OpenClawEnvironment.detectCLIPath() ?? "openclaw"
        let fullCommand = [executable, "gateway"] + args
        let output = await runCommand(fullCommand)
        _ = await Terra.withAgentInvocationSpan(agent: .init(name: "openclaw.launchagent.command", id: nil)) { scope in
            scope.setAttributes([
                Terra.Keys.Terra.runtime: .string("openclaw_gateway"),
                Terra.Keys.Terra.openClawGateway: .bool(true),
                Terra.Keys.GenAI.providerName: .string("openclaw"),
                "osaurus.openclaw.launchagent.command": .string(args.first ?? "gateway"),
                "osaurus.openclaw.launchagent.args.count": .int(args.count),
                "osaurus.openclaw.launchagent.success": .bool(output.success),
                "osaurus.openclaw.launchagent.status": .int(Int(output.status)),
                "osaurus.openclaw.launchagent.latency_ms": .double(Date().timeIntervalSince(startedAt) * 1000),
            ])
        }
        return output
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
            let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            if let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = extraPaths + ":" + existing
            } else {
                env["PATH"] = extraPaths
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
