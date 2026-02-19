//
//  OpenClawInstallerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawInstallerTests {
    @Test func installedLocation_detectsExecutableInSearchPaths() throws {
        let temp = try makeTempDir(prefix: "openclaw-installer-location")
        defer { try? FileManager.default.removeItem(at: temp) }

        let binary = temp.appendingPathComponent("openclaw")
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/bash\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        OpenClawInstaller.hooks = .init(
            searchPaths: { [temp.path] },
            runInstallCommand: { _ in
                .init(status: 0, stdout: "", stderr: "")
            }
        )
        defer { OpenClawInstaller.hooks = nil }

        #expect(OpenClawInstaller.isInstalled() == true)
        #expect(OpenClawInstaller.installedLocation() == binary.path)
    }

    @Test func install_reportsProgressFromJsonEvents() async throws {
        final class ProgressBox: @unchecked Sendable {
            var messages: [String] = []
            let lock = NSLock()

            func append(_ message: String) {
                lock.lock()
                messages.append(message)
                lock.unlock()
            }

            func all() -> [String] {
                lock.lock()
                let copy = messages
                lock.unlock()
                return copy
            }
        }

        OpenClawInstaller.hooks = .init(
            searchPaths: { [] },
            runInstallCommand: { _ in
                .init(
                    status: 0,
                    stdout: """
                    {"event":"progress","message":"Downloading"}
                    {"event":"done","version":"1.2.3"}
                    """,
                    stderr: ""
                )
            }
        )
        defer { OpenClawInstaller.hooks = nil }

        let progress = ProgressBox()
        try await OpenClawInstaller.install { message in
            progress.append(message)
        }
        let messages = progress.all()

        #expect(messages.contains(where: { $0.contains("Installing openclaw CLI") }))
        #expect(messages.contains(where: { $0.contains("Downloading") }))
        #expect(messages.contains(where: { $0.contains("Installed openclaw 1.2.3") }))
    }

    @Test func install_throwsOnFailure() async throws {
        OpenClawInstaller.hooks = .init(
            searchPaths: { [] },
            runInstallCommand: { _ in
                .init(
                    status: 1,
                    stdout: #"{"event":"error","message":"network down"}"#,
                    stderr: ""
                )
            }
        )
        defer { OpenClawInstaller.hooks = nil }

        await #expect(throws: NSError.self) {
            try await OpenClawInstaller.install { _ in }
        }
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
