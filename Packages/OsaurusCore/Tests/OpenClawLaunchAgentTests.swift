//
//  OpenClawLaunchAgentTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawLaunchAgentTests {
    @Test func commands_andStatusParsing_workWithHooks() async throws {
        final class Recorder: @unchecked Sendable {
            var commands: [[String]] = []
            let lock = NSLock()

            func append(_ command: [String]) {
                lock.lock()
                commands.append(command)
                lock.unlock()
            }
        }

        let recorder = Recorder()
        OpenClawLaunchAgent.hooks = .init(
            runCommand: { args in
                recorder.append(args)
                if args.first == "status" {
                    return .init(
                        success: true,
                        status: 0,
                        stdout: #"{"service":{"loaded":true}}"#,
                        stderr: ""
                    )
                }
                return .init(success: true, status: 0, stdout: "{}", stderr: "")
            }
        )
        defer { OpenClawLaunchAgent.hooks = nil }

        let installError = await OpenClawLaunchAgent.install(port: 18789, bindMode: .loopback)
        #expect(installError == nil)

        let loaded = await OpenClawLaunchAgent.isLoaded()
        #expect(loaded == true)

        let restartError = await OpenClawLaunchAgent.kickstart()
        #expect(restartError == nil)

        let uninstallError = await OpenClawLaunchAgent.uninstall()
        #expect(uninstallError == nil)

        let commands = recorder.commands
        #expect(commands.contains(where: { $0.starts(with: ["install"]) }))
        #expect(commands.contains(where: { $0.starts(with: ["status"]) }))
        #expect(commands.contains(where: { $0.starts(with: ["restart"]) }))
        #expect(commands.contains(where: { $0.starts(with: ["uninstall"]) }))
    }

    @Test func logPath_returnsDeterministicFallback() {
        let path = OpenClawLaunchAgent.logPath()
        #expect(path.contains("gateway.log"))
    }
}
