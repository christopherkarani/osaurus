//
//  OpenClawManagerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct OpenClawManagerTests {
    @Test
    func toastSink_capturesConnectionEvents() async {
        let manager = OpenClawManager.shared
        var events: [OpenClawManager.ToastEvent] = []

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] }
            )
        )
        OpenClawManager._testSetToastSink { event in
            events.append(event)
        }
        defer {
            OpenClawManager._testResetToastSink()
            OpenClawManager._testSetGatewayHooks(nil)
        }

        await manager._testHandleConnectionState(.connected)
        await manager._testHandleConnectionState(.reconnecting(attempt: 2))
        await manager._testHandleConnectionState(.reconnected)
        await manager._testHandleConnectionState(.disconnected)
        await manager._testHandleConnectionState(.failed("simulated failure"))

        #expect(events.count == 5)
        #expect(events[0] == .connected)
        #expect(events[1] == .reconnecting(attempt: 2))
        #expect(events[2] == .reconnected)
        #expect(events[3] == .disconnected)
        #expect(events[4] == .failed("simulated failure"))
    }

    @Test
    func setHeartbeat_updatesHeartbeatStateFromRPCHooks() async {
        let manager = OpenClawManager.shared
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        actor RequestedHeartbeatEnabledState {
            var value: Bool?
            init(_ value: Bool? = nil) {
                self.value = value
            }
            func set(_ value: Bool?) {
                self.value = value
            }
            func get() -> Bool? {
                value
            }
        }
        let requestedHeartbeatEnabled = RequestedHeartbeatEnabledState()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                heartbeatStatus: {
                    OpenClawHeartbeatStatus(enabled: false, lastHeartbeatAt: expectedDate)
                },
                setHeartbeats: { enabled in
                    await requestedHeartbeatEnabled.set(enabled)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        try? await manager.setHeartbeat(enabled: false)
        let actualRequestedHeartbeatEnabled = await requestedHeartbeatEnabled.get()

        #expect(actualRequestedHeartbeatEnabled == false)
        #expect(manager.heartbeatEnabled == false)
        #expect(manager.heartbeatLastTimestamp == expectedDate)
    }

    @Test
    func refreshStatus_failureTransitionsToConnectionFailed() async {
        let manager = OpenClawManager.shared
        let expected = "simulated channels failure"

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: expected]
                    )
                },
                modelsList: { [] },
                health: { [:] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshStatus()

        switch manager.connectionState {
        case .failed(let message):
            #expect(message.contains(expected))
        default:
            Issue.record("Expected connectionState.failed after refreshStatus error")
        }

        switch manager.phase {
        case .connectionFailed(let message):
            #expect(message.contains(expected))
        default:
            Issue.record("Expected phase.connectionFailed after refreshStatus error")
        }

        #expect(manager.isConnected == false)
        #expect(manager.lastError?.contains(expected) == true)
    }

    @Test
    func disconnectChannel_routesThroughGatewayHook() async {
        let manager = OpenClawManager.shared
        actor LogoutRecorder {
            var channelId: String?
            var accountId: String?

            func record(channelId: String, accountId: String?) {
                self.channelId = channelId
                self.accountId = accountId
            }

            func values() -> (String?, String?) {
                (channelId, accountId)
            }
        }
        let recorder = LogoutRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                channelsLogout: { channelId, accountId in
                    await recorder.record(channelId: channelId, accountId: accountId)
                },
                modelsList: { [] },
                health: { [:] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        try? await manager.disconnectChannel(channelId: "telegram", accountId: "acct-1")

        let (channelId, accountId) = await recorder.values()
        #expect(channelId == "telegram")
        #expect(accountId == "acct-1")
    }

    @Test
    func refreshCron_populatesStatusAndJobsFromHooks() async {
        let manager = OpenClawManager.shared
        let job = OpenClawCronJob(
            id: "job-1",
            name: "Hourly check",
            description: nil,
            enabled: true,
            schedule: OpenClawCronSchedule(kind: .every, at: nil, everyMs: 3_600_000, expr: nil, tz: nil),
            state: OpenClawCronJobState(lastStatus: "ok")
        )

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                cronStatus: {
                    OpenClawCronStatus(
                        enabled: true,
                        jobs: 1,
                        storePath: "/tmp/cron.json",
                        nextWakeAt: Date(timeIntervalSince1970: 1_708_345_600)
                    )
                },
                cronList: { [job] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshCron()

        #expect(manager.cronStatus?.enabled == true)
        #expect(manager.cronStatus?.jobs == 1)
        #expect(manager.cronJobs.count == 1)
        #expect(manager.cronJobs.first?.id == "job-1")
    }

    @Test
    func setCronJobEnabled_routesThroughGatewayHook() async {
        let manager = OpenClawManager.shared

        actor Recorder {
            var jobId: String?
            var enabled: Bool?

            func record(jobId: String, enabled: Bool) {
                self.jobId = jobId
                self.enabled = enabled
            }

            func values() -> (String?, Bool?) {
                (jobId, enabled)
            }
        }
        let recorder = Recorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                cronStatus: {
                    OpenClawCronStatus(enabled: true, jobs: 0, storePath: nil, nextWakeAt: nil)
                },
                cronList: { [] },
                cronSetEnabled: { jobId, enabled in
                    await recorder.record(jobId: jobId, enabled: enabled)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        try? await manager.setCronJobEnabled(jobId: "job-2", enabled: false)

        let (jobId, enabled) = await recorder.values()
        #expect(jobId == "job-2")
        #expect(enabled == false)
    }

    @Test
    func refreshSkills_populatesReportAndBinsFromHooks() async {
        let manager = OpenClawManager.shared
        let skill = OpenClawSkillStatus(
            name: "my-skill",
            description: "Example skill",
            source: "local",
            filePath: "/tmp/SKILL.md",
            baseDir: "/tmp",
            skillKey: "my-skill",
            bundled: false,
            primaryEnv: nil,
            emoji: nil,
            homepage: nil,
            always: false,
            disabled: false,
            blockedByAllowlist: false,
            eligible: true,
            requirements: OpenClawSkillRequirementSet(),
            missing: OpenClawSkillRequirementSet(),
            configChecks: [],
            install: []
        )

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                skillsStatus: {
                    OpenClawSkillStatusReport(
                        workspaceDir: "/tmp/workspace",
                        managedSkillsDir: "/tmp/managed",
                        skills: [skill]
                    )
                },
                skillsBins: { ["node", "uv"] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshSkills()

        #expect(manager.skillsReport?.skills.count == 1)
        #expect(manager.skillsReport?.skills.first?.skillKey == "my-skill")
        #expect(manager.skillsBins == ["node", "uv"])
    }

    @Test
    func updateSkillEnabled_routesThroughGatewayHook() async {
        let manager = OpenClawManager.shared

        actor Recorder {
            var skillKey: String?
            var enabled: Bool?

            func record(skillKey: String, enabled: Bool?) {
                self.skillKey = skillKey
                self.enabled = enabled
            }

            func values() -> (String?, Bool?) {
                (skillKey, enabled)
            }
        }
        let recorder = Recorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                skillsStatus: {
                    OpenClawSkillStatusReport(workspaceDir: "/tmp", managedSkillsDir: "/tmp", skills: [])
                },
                skillsBins: { [] },
                skillsUpdate: { skillKey, enabled in
                    await recorder.record(skillKey: skillKey, enabled: enabled)
                    return OpenClawSkillUpdateResult(ok: true, skillKey: skillKey)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        try? await manager.updateSkillEnabled(skillKey: "my-skill", enabled: false)

        let (skillKey, enabled) = await recorder.values()
        #expect(skillKey == "my-skill")
        #expect(enabled == false)
    }

    @Test
    func refreshConnectedClients_populatesPresenceRowsFromHook() async {
        let manager = OpenClawManager.shared
        let entry = OpenClawPresenceEntry(
            instanceId: "node-1",
            host: "Node-Host",
            ip: "10.0.0.2",
            version: "1.0.0",
            platform: "macos",
            deviceFamily: "Mac",
            modelIdentifier: "Mac15,6",
            roles: ["chat-client"],
            scopes: [],
            mode: "chat",
            lastInputSeconds: 3,
            reason: "node-connected",
            text: "Node: Node-Host",
            timestampMs: 1_708_345_600_000
        )

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                systemPresence: { [entry] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshConnectedClients()

        #expect(manager.connectedClients.count == 1)
        #expect(manager.connectedClients.first?.id == "node-1")
        #expect(manager.connectedClients.first?.roles == ["chat-client"])
    }
}
