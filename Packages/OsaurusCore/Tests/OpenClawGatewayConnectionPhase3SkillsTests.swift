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
    func skillsStatusBinsAndAgents_decodeExpectedPayloads() async throws {
        let recorder = OpenClawSkillsCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "agents.list":
                let payload: [String: Any] = [
                    "defaultId": "main",
                    "mainKey": "main",
                    "scope": "per-sender",
                    "agents": [
                        [
                            "id": "main",
                            "name": "Main Agent"
                        ],
                        [
                            "id": "writer",
                            "name": "Writer"
                        ]
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
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

        let agents = try await connection.agentsList()
        let status = try await connection.skillsStatus(agentId: "writer")
        let bins = try await connection.skillsBins()
        let calls = await recorder.all()

        #expect(calls.count == 3)
        #expect(calls[0].method == "agents.list")
        #expect(calls[1].method == "skills.status")
        #expect(calls[1].params?["agentId"]?.value as? String == "writer")
        #expect(calls[2].method == "skills.bins")
        #expect(agents.defaultId == "main")
        #expect(agents.agents.map(\.id) == ["main", "writer"])
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

    @Test
    func agentsFilesListGetSet_encodeAndDecodeExpectedPayloads() async throws {
        let recorder = OpenClawSkillsCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "agents.files.list":
                let payload: [String: Any] = [
                    "agentId": "main",
                    "workspace": "/tmp/workspace-main",
                    "files": [
                        [
                            "name": "MEMORY.md",
                            "path": "/tmp/workspace-main/MEMORY.md",
                            "missing": false,
                            "size": 42,
                            "updatedAtMs": 1_700_000_000_000
                        ]
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "agents.files.get":
                let payload: [String: Any] = [
                    "agentId": "main",
                    "workspace": "/tmp/workspace-main",
                    "file": [
                        "name": "MEMORY.md",
                        "path": "/tmp/workspace-main/MEMORY.md",
                        "missing": false,
                        "size": 42,
                        "updatedAtMs": 1_700_000_000_000,
                        "content": "# Memory"
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "agents.files.set":
                let payload: [String: Any] = [
                    "ok": true,
                    "agentId": "main",
                    "workspace": "/tmp/workspace-main",
                    "file": [
                        "name": "MEMORY.md",
                        "path": "/tmp/workspace-main/MEMORY.md",
                        "missing": false,
                        "size": 55,
                        "updatedAtMs": 1_700_000_000_001,
                        "content": "# Updated Memory"
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        let listing = try await connection.agentsFilesList(agentId: "main")
        let fetched = try await connection.agentsFileGet(agentId: "main", name: "MEMORY.md")
        let updated = try await connection.agentsFileSet(
            agentId: "main",
            name: "MEMORY.md",
            content: "# Updated Memory"
        )
        let calls = await recorder.all()

        #expect(calls.count == 3)
        #expect(calls[0].method == "agents.files.list")
        #expect(calls[0].params?["agentId"]?.value as? String == "main")
        #expect(calls[1].method == "agents.files.get")
        #expect(calls[1].params?["name"]?.value as? String == "MEMORY.md")
        #expect(calls[2].method == "agents.files.set")
        #expect(calls[2].params?["content"]?.value as? String == "# Updated Memory")

        #expect(listing.agentId == "main")
        #expect(listing.files.first?.name == "MEMORY.md")
        #expect(fetched.file.content == "# Memory")
        #expect(updated.ok == true)
        #expect(updated.file.content == "# Updated Memory")
    }
}
