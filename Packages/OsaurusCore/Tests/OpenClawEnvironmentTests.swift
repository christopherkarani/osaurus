//
//  OpenClawEnvironmentTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawEnvironmentTests {
    @Test func semver_parseAndCompare() throws {
        let parsed = Semver.parse("v1.2.3")
        #expect(parsed == Semver(major: 1, minor: 2, patch: 3))

        #expect(Semver.parse("1.2") == nil)
        #expect(Semver.parse("1.2.3-beta.1") == Semver(major: 1, minor: 2, patch: 3))

        let required = Semver(major: 1, minor: 2, patch: 0)
        #expect(Semver(major: 1, minor: 2, patch: 0).compatible(with: required) == true)
        #expect(Semver(major: 1, minor: 3, patch: 0).compatible(with: required) == true)
        #expect(Semver(major: 2, minor: 0, patch: 0).compatible(with: required) == false)
    }

    @Test func check_returnsExpectedStatusesFromHooks() async throws {
        defer { OpenClawEnvironment.hooks = nil }

        OpenClawEnvironment.hooks = .init(
            detectNodePath: { nil },
            detectCLIPath: { "/usr/local/bin/openclaw" },
            versionForExecutable: { _ in "1.0.0" },
            requiredCLIVersion: { nil }
        )
        #expect(await OpenClawEnvironment.check() == .missingNode)

        OpenClawEnvironment.hooks = .init(
            detectNodePath: { "/usr/local/bin/node" },
            detectCLIPath: { nil },
            versionForExecutable: { _ in "1.0.0" },
            requiredCLIVersion: { nil }
        )
        #expect(await OpenClawEnvironment.check() == .missingCLI)

        OpenClawEnvironment.hooks = .init(
            detectNodePath: { "/usr/local/bin/node" },
            detectCLIPath: { "/usr/local/bin/openclaw" },
            versionForExecutable: { path in
                if path.contains("node") { return "22.0.1" }
                return "1.4.0"
            },
            requiredCLIVersion: { "1.2.0" }
        )
        #expect(await OpenClawEnvironment.check() == .ready(nodeVersion: "22.0.1", cliVersion: "1.4.0"))

        OpenClawEnvironment.hooks = .init(
            detectNodePath: { "/usr/local/bin/node" },
            detectCLIPath: { "/usr/local/bin/openclaw" },
            versionForExecutable: { path in
                if path.contains("node") { return "22.0.1" }
                return "1.1.0"
            },
            requiredCLIVersion: { "1.2.0" }
        )
        #expect(await OpenClawEnvironment.check() == .incompatibleVersion(found: "1.1.0", required: "1.2.0"))
    }
}
