//
//  OpenClawGatewayConnectionPhase3SkillsTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawSkillsCallRecorder {
    struct Call: Sendable {
        let method: String
        let params: [String: OpenClawProtocol.AnyCodable]?
    }

    private var calls: [Call] = []

    func record(method: String, params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append(Call(method: method, params: params))
    }

    func all() -> [Call] {
        calls
    }
}

struct OpenClawGatewayConnectionPhase3SkillsTests {
    @Test
    func skillsStatusAndBins_decodeExpectedPayloads() async throws {
        let recorder = OpenClawSkillsCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "skills.status":
                let payload: [String: Any] = [
                    "workspaceDir": "/tmp/skills-workspace",
                    "managedSkillsDir": "/tmp/skills-managed",
                    "skills": [
                        [
                            "name": "my-skill",
                            "description": "Example skill",
                            "source": "local",
                            "filePath": "/tmp/skill/SKILL.md",
                            "baseDir": "/tmp/skill",
                            "skillKey": "my-skill",
                            "always": false,
                            "disabled": false,
                            "eligible": true,
                            "blockedByAllowlist": false,
                            "requirements": [
                                "bins": ["node"],
                                "env": [],
                                "config": [],
                                "os": []
                            ],
                            "missing": [
                                "bins": [],
                                "env": [],
                                "config": [],
                                "os": []
                            ],
                            "configChecks": [],
                            "install": []
                        ]
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "skills.bins":
                let payload: [String: Any] = [
                    "bins": ["node", "uv"]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        let status = try await connection.skillsStatus()
        let bins = try await connection.skillsBins()
        let calls = await recorder.all()

        #expect(calls.count == 2)
        #expect(calls[0].method == "skills.status")
        #expect(calls[1].method == "skills.bins")
        #expect(status.skills.count == 1)
        #expect(status.skills.first?.skillKey == "my-skill")
        #expect(bins == ["node", "uv"])
    }

    @Test
    func skillsInstallAndUpdate_encodeExpectedParams() async throws {
        let recorder = OpenClawSkillsCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "skills.install":
                let payload: [String: Any] = [
                    "ok": true,
                    "message": "installed"
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "skills.update":
                let payload: [String: Any] = [
                    "ok": true,
                    "skillKey": "my-skill"
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        let install = try await connection.skillsInstall(name: "my-skill", installId: "brew:foo")
        let update = try await connection.skillsUpdate(skillKey: "my-skill", enabled: false)
        let calls = await recorder.all()

        #expect(calls.count == 2)
        #expect(calls[0].method == "skills.install")
        #expect(calls[0].params?["name"]?.value as? String == "my-skill")
        #expect(calls[0].params?["installId"]?.value as? String == "brew:foo")
        #expect(install.ok == true)

        #expect(calls[1].method == "skills.update")
        #expect(calls[1].params?["skillKey"]?.value as? String == "my-skill")
        #expect(calls[1].params?["enabled"]?.value as? Bool == false)
        #expect(update.ok == true)
        #expect(update.skillKey == "my-skill")
    }
}
