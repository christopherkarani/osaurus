//
//  OpenClawManagerTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
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
        OpenClawManager._testSetReconnectToastDelayNanoseconds(0)
        defer {
            OpenClawManager._testSetReconnectToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
            OpenClawManager._testSetGatewayHooks(nil)
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)
        await manager._testHandleConnectionState(.connected)
        await manager._testHandleConnectionState(.reconnecting(attempt: 2))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await manager._testHandleConnectionState(.reconnected)
        await manager._testHandleConnectionState(.disconnected)
        await manager._testHandleConnectionState(.failed("simulated failure"))

        #expect(events.contains(.connected))
        #expect(events.contains(.reconnecting(attempt: 2)))
        #expect(events.contains(.reconnected))
        #expect(events.contains(.failed("simulated failure")))

        if let connectedIndex = events.firstIndex(of: .connected),
            let reconnectingIndex = events.firstIndex(of: .reconnecting(attempt: 2)),
            let reconnectedIndex = events.firstIndex(of: .reconnected),
            let failedIndex = events.firstIndex(of: .failed("simulated failure"))
        {
            #expect(connectedIndex < reconnectingIndex)
            #expect(reconnectingIndex < reconnectedIndex)
            #expect(reconnectedIndex < failedIndex)
        } else {
            Issue.record("Expected required connection lifecycle events, got \(events)")
        }
        await manager._testResetConnectionObservation()
    }

    @Test
    func duplicateConnectedState_doesNotEmitDuplicateToast() async {
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
        await manager._testHandleConnectionState(.connected)

        #expect(events == [.connected])
    }

    @Test
    func reconnectToasts_areSuppressedWhenConnectionRecoversBeforeDelay() async {
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
        OpenClawManager._testSetReconnectToastDelayNanoseconds(220_000_000)
        defer {
            OpenClawManager._testSetReconnectToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
            OpenClawManager._testSetGatewayHooks(nil)
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager._testHandleConnectionState(.reconnecting(attempt: 1))
        try? await Task.sleep(nanoseconds: 40_000_000)
        await manager._testHandleConnectionState(.reconnected)
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(events.contains(.reconnecting(attempt: 1)) == false)
        #expect(events.contains(.reconnected) == false)
        await manager._testResetConnectionObservation()
    }

    @Test
    func connectedToast_isSuppressedWhenImmediatelyFollowingReconnected() async {
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
        OpenClawManager._testSetReconnectToastDelayNanoseconds(0)
        defer {
            OpenClawManager._testSetReconnectToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
            OpenClawManager._testSetGatewayHooks(nil)
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager._testHandleConnectionState(.reconnecting(attempt: 3))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await manager._testHandleConnectionState(.reconnected)
        await manager._testHandleConnectionState(.connected)

        let connectedCount = events.reduce(0) { count, event in
            count + (event == .connected ? 1 : 0)
        }

        #expect(events.contains(.reconnecting(attempt: 3)))
        #expect(events.contains(.reconnected))
        #expect(connectedCount == 0)
        await manager._testResetConnectionObservation()
    }

    @Test
    func authFailureToast_isCancelledWhenConnectionRecoversQuickly() async {
        let manager = OpenClawManager.shared
        var events: [OpenClawManager.ToastEvent] = []
        let authFailure = "Gateway authentication failed: unauthorized: device token mismatch"

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
        OpenClawManager._testSetAuthFailureToastDelayNanoseconds(200_000_000)
        defer {
            OpenClawManager._testSetAuthFailureToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
            OpenClawManager._testSetGatewayHooks(nil)
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)

        await manager._testHandleConnectionState(.failed(authFailure))
        try? await Task.sleep(nanoseconds: 50_000_000)
        await manager._testHandleConnectionState(.connected)
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(events.contains(.connected))
        #expect(events.contains(.failed(authFailure)) == false)
        await manager._testResetConnectionObservation()
    }

    @Test
    func authFailureToast_isEmittedWhenFailurePersists() async {
        let manager = OpenClawManager.shared
        var events: [OpenClawManager.ToastEvent] = []
        let authFailure = "Gateway authentication failed. Reconfigure credentials."

        OpenClawManager._testSetToastSink { event in
            events.append(event)
        }
        OpenClawManager._testSetAuthFailureToastDelayNanoseconds(75_000_000)
        defer {
            OpenClawManager._testSetAuthFailureToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)

        await manager._testHandleConnectionState(.failed(authFailure))
        try? await Task.sleep(nanoseconds: 180_000_000)

        #expect(events == [.failed(authFailure)])
        await manager._testResetConnectionObservation()
    }

    @Test
    func authFailureToast_reschedulesAndEmitsAtMostOnceAcrossAuthFailureVariants() async {
        let manager = OpenClawManager.shared
        var events: [OpenClawManager.ToastEvent] = []
        let mismatchFailure = "Gateway authentication failed: unauthorized: device token mismatch"
        let reconfigureFailure = "Gateway authentication failed. Reconfigure credentials."

        OpenClawManager._testSetToastSink { event in
            events.append(event)
        }
        OpenClawManager._testSetAuthFailureToastDelayNanoseconds(120_000_000)
        defer {
            OpenClawManager._testSetAuthFailureToastDelayNanoseconds(nil)
            OpenClawManager._testResetToastSink()
        }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)

        await manager._testHandleConnectionState(.failed(mismatchFailure))
        try? await Task.sleep(nanoseconds: 20_000_000)
        await manager._testHandleConnectionState(.failed(reconfigureFailure))
        try? await Task.sleep(nanoseconds: 220_000_000)

        #expect(events == [.failed(reconfigureFailure)])
        await manager._testResetConnectionObservation()
    }

    @Test
    func localAuthRecoveryPredicate_requiresLoopbackAndNoCustomEndpoint() {
        let loopback = URL(string: "ws://127.0.0.1:18789/ws")!
        let remote = URL(string: "wss://gateway.example.com/ws")!
        let message = "unauthorized: device token mismatch (rotate/reissue device token)"

        #expect(
            OpenClawManager._testShouldAttemptLocalAuthRecovery(
                message: message,
                endpoint: loopback,
                hasCustomGatewayURL: false
            )
        )
        #expect(
            OpenClawManager._testShouldAttemptLocalAuthRecovery(
                message: message,
                endpoint: loopback,
                hasCustomGatewayURL: true
            ) == false
        )
        #expect(
            OpenClawManager._testShouldAttemptLocalAuthRecovery(
                message: message,
                endpoint: remote,
                hasCustomGatewayURL: false
            ) == false
        )
    }

    @Test
    func localAuthRecoveryPredicate_ignoresNonAuthFailures() {
        let loopback = URL(string: "ws://127.0.0.1:18789/ws")!

        #expect(
            OpenClawManager._testShouldAttemptLocalAuthRecovery(
                message: "network timeout",
                endpoint: loopback,
                hasCustomGatewayURL: false
            ) == false
        )
    }

    @Test
    func gatewayConnectionPending_reflectsStartupAndConnectStates() {
        let manager = OpenClawManager.shared

        manager._testSetConnectionState(.disconnected, gatewayStatus: .starting)
        #expect(manager.isGatewayConnectionPending == true)
        #expect(manager.gatewayConnectionReadinessMessage?.contains("starting") == true)

        manager._testSetConnectionState(.connecting, gatewayStatus: .running)
        #expect(manager.isGatewayConnectionPending == true)
        #expect(manager.gatewayConnectionReadinessMessage?.contains("connecting") == true)
    }

    @Test
    func gatewayConnectionPending_isFalseWhenConnectedOrIdleRunning() {
        let manager = OpenClawManager.shared

        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)
        #expect(manager.isGatewayConnectionPending == false)
        #expect(manager.gatewayConnectionReadinessMessage == nil)

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        #expect(manager.isGatewayConnectionPending == false)
        #expect(manager.gatewayConnectionReadinessMessage == nil)
    }

    @Test
    func gatewayCredentialSourceOrder_prefersLocalDeviceSourcesForLoopback() {
        let sources = OpenClawManager._testGatewayCredentialSourceOrder(
            keychainAuth: "kc-auth",
            keychainDevice: "kc-device",
            launchAgent: "launch-agent-token",
            deviceAuthFile: "device-auth-token",
            pairedRegistry: "paired-token",
            legacyConfig: "legacy-token",
            preferLocalGatewaySources: true
        )

        #expect(
            sources == [
                "local-device-auth-file",
                "local-paired-registry",
                "local-legacy-config",
                "local-launch-agent-plist",
                "keychain-device-auth",
                "keychain-auth",
            ]
        )
    }

    @Test
    func gatewayCredentialSourceOrder_dedupesDuplicateTokenValues() {
        let sources = OpenClawManager._testGatewayCredentialSourceOrder(
            keychainAuth: "duplicate-a",
            keychainDevice: "duplicate-b",
            launchAgent: "duplicate-a",
            deviceAuthFile: "duplicate-b",
            pairedRegistry: "duplicate-b",
            legacyConfig: "unique-c",
            preferLocalGatewaySources: true
        )

        #expect(
            sources == [
                "local-device-auth-file",
                "local-legacy-config",
                "local-launch-agent-plist",
            ]
        )
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
    func refreshStatus_unsupportedHeartbeatStatusMethod_isGracefullySkippedAndMemoized() async {
        let manager = OpenClawManager.shared

        actor Counter {
            private var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let counter = Counter()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                heartbeatStatus: {
                    await counter.increment()
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "unknown method: heartbeat.status"]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshStatus()
        await manager.refreshStatus()

        #expect(await counter.value() == 1)
        #expect(manager.connectionState == .connected)
        await manager._testResetConnectionObservation()
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
    func refreshSkills_skillsBinsUnauthorized_isGracefullySkippedAndMemoized() async {
        let manager = OpenClawManager.shared

        actor Counter {
            private var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let counter = Counter()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                agentsList: {
                    OpenClawGatewayAgentsListResponse(
                        defaultId: "main",
                        mainKey: "main",
                        scope: "per-sender",
                        agents: [OpenClawGatewayAgentSummary(id: "main", name: "Main")]
                    )
                },
                skillsStatus: {
                    OpenClawSkillStatusReport(
                        workspaceDir: "/tmp/workspace",
                        managedSkillsDir: "/tmp/managed",
                        skills: []
                    )
                },
                skillsBins: {
                    await counter.increment()
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 19,
                        userInfo: [NSLocalizedDescriptionKey: "unauthorized role: operator"]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshSkills()
        await manager.refreshSkills()

        #expect(await counter.value() == 1)
        #expect(manager.skillsBins == [])
        #expect(manager.skillsReport != nil)
        await manager._testResetConnectionObservation()
    }

    @Test
    func refreshSkills_defaultsToGatewayDefaultAgentWhenSelectionIsStale() async {
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

        manager._testSetConnectionState(.disconnected, gatewayStatus: .stopped)
        await manager.selectSkillsAgent("stale-agent")

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                agentsList: {
                    OpenClawGatewayAgentsListResponse(
                        defaultId: "writer",
                        mainKey: "main",
                        scope: "per-sender",
                        agents: [
                            OpenClawGatewayAgentSummary(id: "main", name: "Main Agent"),
                            OpenClawGatewayAgentSummary(id: "writer", name: "Writer")
                        ]
                    )
                },
                skillsStatus: {
                    OpenClawSkillStatusReport(
                        workspaceDir: "/tmp/workspace",
                        managedSkillsDir: "/tmp/managed",
                        skills: [skill]
                    )
                },
                skillsBins: { ["node"] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshSkills()

        #expect(manager.skillsAgents.map(\.id) == ["main", "writer"])
        #expect(manager.selectedSkillsAgentId == "writer")
        #expect(manager.skillsReport?.skills.count == 1)
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
    func syncMCPProvidersToOpenClaw_routesThroughDetailedSkillUpdateHook() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor Recorder {
            var skillKey: String?
            var enabled: Bool?
            var env: [String: String]?

            func record(skillKey: String, enabled: Bool?, env: [String: String]?) {
                self.skillKey = skillKey
                self.enabled = enabled
                self.env = env
            }

            func values() -> (String?, Bool?, [String: String]?) {
                (skillKey, enabled, env)
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
                skillsUpdateDetailed: { skillKey, enabled, _, env in
                    await recorder.record(skillKey: skillKey, enabled: enabled, env: env)
                    return OpenClawSkillUpdateResult(ok: true, skillKey: skillKey)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        let outputURL = tempDir.appendingPathComponent("mcporter.json")

        let result = try await manager.syncMCPProvidersToOpenClaw(
            enableMcporterSkill: true,
            providerEntriesOverride: [
                .init(name: "Example MCP", url: "https://mcp.example.com/sse", headers: [:])
            ],
            outputURLOverride: outputURL
        )

        let (skillKey, enabled, env) = await recorder.values()
        #expect(skillKey == "mcporter")
        #expect(enabled == true)
        #expect(env?["MCPORTER_CONFIG"] == outputURL.path)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(manager.mcpBridgeLastSyncResult == result)
        #expect(manager.mcpBridgeLastSyncMode == .manual)
        #expect(manager.mcpBridgeLastSyncError == nil)
    }

    @Test
    func syncMCPProvidersToOpenClaw_skillUpdateFailure_rollsBackBridgeConfig() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let seedConfig = """
        {"imports":[],"mcpServers":{"seed":{"baseUrl":"https://seed.example.com/sse"}}}
        """
        guard let seedData = seedConfig.data(using: .utf8) else {
            Issue.record("Failed to encode seed config")
            return
        }
        try seedData.write(to: outputURL)

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                skillsStatus: {
                    OpenClawSkillStatusReport(workspaceDir: "/tmp", managedSkillsDir: "/tmp", skills: [])
                },
                skillsBins: { [] },
                skillsUpdateDetailed: { _, _, _, _ in
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 501,
                        userInfo: [NSLocalizedDescriptionKey: "simulated mcporter update failure"]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await #expect(throws: NSError.self) {
            _ = try await manager.syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: [
                    .init(name: "Example MCP", url: "https://mcp.example.com/sse", headers: [:])
                ],
                outputURLOverride: outputURL
            )
        }

        let restoredData = try Data(contentsOf: outputURL)
        let restoredString = String(data: restoredData, encoding: .utf8) ?? ""
        #expect(restoredString.contains("seed.example.com"))
        #expect(manager.mcpBridgeLastSyncError?.contains("Restored previous bridge config from backup.") == true)
        #expect(manager.mcpBridgeIsSyncing == false)
    }

    @Test
    func syncMCPProvidersToOpenClaw_notConnected_setsStructuredErrorState() async {
        let manager = OpenClawManager.shared
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)

        await #expect(throws: NSError.self) {
            _ = try await manager.syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: [],
                outputURLOverride: nil
            )
        }

        #expect(manager.mcpBridgeLastSyncErrorState?.code == .notConnected)
        #expect(manager.mcpBridgeLastSyncErrorState?.retryable == true)
        #expect(manager.mcpBridgeLastSyncErrorState?.mode == .manual)
    }

    @Test
    func syncMCPProvidersToOpenClaw_missingMcporter_installsThenUpdates() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let mcporterSkill = OpenClawSkillStatus(
            name: "mcporter",
            description: "MCP bridge skill",
            source: "market",
            filePath: "/tmp/mcporter/SKILL.md",
            baseDir: "/tmp/mcporter",
            skillKey: "mcporter",
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
            install: [
                OpenClawSkillInstallOption(
                    id: "npm:@openclaw/mcporter",
                    kind: "npm",
                    label: "Install mcporter",
                    bins: ["node"]
                )
            ]
        )

        actor Recorder {
            var installCalls = 0
            var updateCalls = 0
            var lastInstallId: String?

            func recordInstall(installId: String) {
                installCalls += 1
                lastInstallId = installId
            }

            func nextUpdateCall() -> Int {
                updateCalls += 1
                return updateCalls
            }

            func snapshot() -> (Int, Int, String?) {
                (installCalls, updateCalls, lastInstallId)
            }
        }
        let recorder = Recorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                skillsStatus: {
                    OpenClawSkillStatusReport(
                        workspaceDir: "/tmp/workspace",
                        managedSkillsDir: "/tmp/managed",
                        skills: [mcporterSkill]
                    )
                },
                skillsBins: { [] },
                skillsInstall: { _, installId, _ in
                    await recorder.recordInstall(installId: installId)
                    return OpenClawSkillInstallResult(
                        ok: true,
                        message: "installed",
                        stdout: nil,
                        stderr: nil,
                        code: 0
                    )
                },
                skillsUpdateDetailed: { _, _, _, _ in
                    let call = await recorder.nextUpdateCall()
                    if call == 1 {
                        throw NSError(
                            domain: "OpenClawManagerTests",
                            code: 404,
                            userInfo: [NSLocalizedDescriptionKey: "mcporter skill not found"]
                        )
                    }
                    return OpenClawSkillUpdateResult(ok: true, skillKey: "mcporter")
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        let result = try await manager.syncMCPProvidersToOpenClaw(
            enableMcporterSkill: true,
            providerEntriesOverride: [
                .init(name: "Example MCP", url: "https://mcp.example.com/sse", headers: [:])
            ],
            outputURLOverride: outputURL
        )

        let (installCalls, updateCalls, lastInstallId) = await recorder.snapshot()
        #expect(result.configPath == outputURL.path)
        #expect(installCalls == 1)
        #expect(updateCalls == 2)
        #expect(lastInstallId == "npm:@openclaw/mcporter")
        #expect(manager.mcpBridgeLastSyncErrorState == nil)
        #expect(manager.mcpBridgeLastSyncError == nil)
    }

    @Test
    func retryLastMCPBridgeSync_replaysLastManualSyncAfterFailure() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")

        actor Recorder {
            var updateCalls = 0
            var envPaths: [String] = []

            func record(env: [String: String]?) -> Int {
                updateCalls += 1
                if let configPath = env?["MCPORTER_CONFIG"] {
                    envPaths.append(configPath)
                }
                return updateCalls
            }

            func snapshot() -> (Int, [String]) {
                (updateCalls, envPaths)
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
                skillsUpdateDetailed: { _, _, _, env in
                    let call = await recorder.record(env: env)
                    if call == 1 {
                        throw NSError(
                            domain: "OpenClawManagerTests",
                            code: 500,
                            userInfo: [NSLocalizedDescriptionKey: "simulated transient update failure"]
                        )
                    }
                    return OpenClawSkillUpdateResult(ok: true, skillKey: "mcporter")
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await #expect(throws: NSError.self) {
            _ = try await manager.syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: [
                    .init(name: "Retry Provider", url: "https://retry.example.com/sse", headers: [:])
                ],
                outputURLOverride: outputURL
            )
        }

        #expect(manager.mcpBridgeLastSyncErrorState?.code == .mcporterUpdateFailed)
        #expect(manager.mcpBridgeLastSyncErrorState?.retryable == true)

        let retryResult = try await manager.retryLastMCPBridgeSync()
        #expect(retryResult.configPath == outputURL.path)
        #expect(manager.mcpBridgeLastSyncErrorState == nil)

        let (updateCalls, envPaths) = await recorder.snapshot()
        #expect(updateCalls == 2)
        #expect(envPaths.count == 2)
        #expect(envPaths.allSatisfy { $0 == outputURL.path })
    }

    @Test
    func syncMCPProvidersToOpenClaw_automaticUnownedConfig_setsStructuredSkipError() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-auto-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")
        let seedConfig = """
        {"imports":[],"mcpServers":{"seed":{"baseUrl":"https://seed.example.com/sse"}}}
        """
        try #require(seedConfig.data(using: .utf8)).write(to: outputURL)

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await #expect(throws: OpenClawMCPBridgeError.self) {
            _ = try await manager.syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: [
                    .init(name: "Example MCP", url: "https://mcp.example.com/sse", headers: [:])
                ],
                outputURLOverride: outputURL,
                mode: .automatic,
                allowUnownedOverwrite: false
            )
        }

        #expect(manager.mcpBridgeLastSyncErrorState?.code == .automaticSyncSkipped)
        #expect(manager.mcpBridgeLastSyncErrorState?.mode == .automatic)
        #expect(manager.mcpBridgeLastSyncErrorState?.retryable == true)
    }

    // MARK: - pollHealth reconnect trigger

    @Test
    func pollHealth_failure_doesNotDeclareGatewayFailedOnFirstTransientError() async {
        let manager = OpenClawManager.shared

        actor ConnectCallRecorder {
            var callCount = 0
            func record() { callCount += 1 }
            func count() -> Int { callCount }
        }
        let connectCalls = ConnectCallRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "health endpoint unavailable"]
                    )
                },
                gatewayConnect: {
                    await connectCalls.record()
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 100,
                        userInfo: [NSLocalizedDescriptionKey: "simulated connect failure"]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager._testPollHealth()

        // Reconnect was attempted before declaring failure.
        #expect(await connectCalls.count() == 1)

        // First failure stays in reconnecting state (transient budget), not hard failed.
        #expect(manager.connectionState == .reconnecting(attempt: 1))
        #expect(manager.phase == .reconnecting(attempt: 1))
        switch manager.gatewayStatus {
        case .running:
            break
        default:
            Issue.record("Expected gatewayStatus.running after first transient health failure, got \(manager.gatewayStatus)")
        }
    }

    @Test
    func pollHealth_failure_declaresGatewayFailedAfterThreshold() async {
        let manager = OpenClawManager.shared

        actor ConnectCallRecorder {
            var callCount = 0
            func record() { callCount += 1 }
            func count() -> Int { callCount }
        }
        let connectCalls = ConnectCallRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "health endpoint unavailable"]
                    )
                },
                gatewayConnect: {
                    await connectCalls.record()
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 100,
                        userInfo: [NSLocalizedDescriptionKey: "simulated connect failure"]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager._testPollHealth()
        await manager._testPollHealth()
        await manager._testPollHealth()

        #expect(await connectCalls.count() == 3)
        switch manager.gatewayStatus {
        case .failed:
            break
        default:
            Issue.record("Expected gatewayStatus.failed after repeated health + reconnect failures, got \(manager.gatewayStatus)")
        }
    }

    @Test
    func pollHealth_failure_reconnectSuccess_restoresConnectedState() async {
        let manager = OpenClawManager.shared

        actor ConnectCallRecorder {
            var callCount = 0
            func record() { callCount += 1 }
            func count() -> Int { callCount }
        }
        let connectCalls = ConnectCallRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "health check failed"]
                    )
                },
                gatewayConnect: {
                    await connectCalls.record()
                    // Succeeds — simulates gateway recovered
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager._testPollHealth()

        #expect(await connectCalls.count() == 1)
        #expect(manager.connectionState == .connected)
        #expect(manager.phase == .connected)
        #expect(manager.lastError == nil)
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

    @Test
    func addProvider_seedsDiscoveredModelsIntoConfigPatch() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            var baseHash: String?
            var callCount = 0

            func record(raw: String, baseHash: String) {
                self.raw = raw
                self.baseHash = baseHash
                callCount += 1
            }

            func snapshot() -> (String?, String?, Int) {
                (raw, baseHash, callCount)
            }
        }
        let recorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-1")
                },
                configPatch: { raw, baseHash in
                    await recorder.record(raw: raw, baseHash: baseHash)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                },
                discoverProviderModels: { _, _ in
                    [
                        OpenClawManager.ProviderSeedModel(
                            id: "foundation",
                            name: "foundation",
                            reasoning: false,
                            contextWindow: 128_000,
                            maxTokens: 8_192
                        ),
                        OpenClawManager.ProviderSeedModel(
                            id: "qwen2.5-coder",
                            name: "qwen2.5-coder",
                            reasoning: true
                        ),
                    ]
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let discoveredCount = try await manager.addProvider(
            id: "osaurus",
            baseUrl: "http://127.0.0.1:1337/v1",
            apiCompatibility: "openai-completions",
            apiKey: nil,
            seedModelsFromEndpoint: true,
            requireSeededModels: true
        )

        #expect(discoveredCount == 2)

        let (rawPatch, baseHash, callCount) = await recorder.snapshot()
        #expect(callCount == 1)
        #expect(baseHash == "base-hash-1")

        let rawPatchValue = try #require(rawPatch)
        let patchData = try #require(rawPatchValue.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let models = json["models"] as? [String: Any]
        let providers = models?["providers"] as? [String: Any]
        let osaurus = providers?["osaurus"] as? [String: Any]
        let seeded = osaurus?["models"] as? [[String: Any]]
        let placeholderAPIKey = osaurus?["apiKey"] as? String
        let firstModelID = seeded?.first?["id"] as? String
        let lastModelID = seeded?.last?["id"] as? String

        #expect(seeded?.count == 2)
        #expect(placeholderAPIKey == "osaurus-local")
        #expect(firstModelID == "foundation")
        #expect(lastModelID == "qwen2.5-coder")
    }

    @Test
    func addProvider_explicitApiKeyOverridesLocalPlaceholder() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            func record(raw: String) { self.raw = raw }
            func payload() -> String? { raw }
        }
        let recorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-3")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                },
                discoverProviderModels: { _, _ in
                    [OpenClawManager.ProviderSeedModel(id: "foundation", name: "foundation")]
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        _ = try await manager.addProvider(
            id: "osaurus",
            baseUrl: "http://127.0.0.1:1337/v1",
            apiCompatibility: "openai-completions",
            apiKey: "real-key",
            seedModelsFromEndpoint: true,
            requireSeededModels: true
        )

        let rawPatch = try #require(await recorder.payload())
        let patchData = try #require(rawPatch.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let models = json["models"] as? [String: Any]
        let providers = models?["providers"] as? [String: Any]
        let osaurus = providers?["osaurus"] as? [String: Any]

        #expect((osaurus?["apiKey"] as? String) == "real-key")
    }

    @Test
    func addProvider_moonshotSeedsDefaultKimiModelWhenDiscoveryIsDisabled() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            func record(raw: String) { self.raw = raw }
            func payload() -> String? { raw }
        }
        let recorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-moonshot")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let configuredModelCount = try await manager.addProvider(
            id: "moonshot",
            baseUrl: "https://api.moonshot.ai/v1",
            apiCompatibility: "openai-completions",
            apiKey: "sk-moonshot-test",
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        #expect(configuredModelCount == 1)

        let rawPatch = try #require(await recorder.payload())
        let patchData = try #require(rawPatch.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let models = json["models"] as? [String: Any]
        let providers = models?["providers"] as? [String: Any]
        let moonshot = providers?["moonshot"] as? [String: Any]
        let seeded = moonshot?["models"] as? [[String: Any]]

        #expect((moonshot?["apiKey"] as? String) == "sk-moonshot-test")
        #expect(seeded?.count == 1)
        #expect(seeded?.first?["id"] as? String == "kimi-k2.5")
        #expect(seeded?.first?["name"] as? String == "Kimi K2.5")
        #expect(seeded?.first?["contextWindow"] as? Int == 256_000)
        #expect(seeded?.first?["maxTokens"] as? Int == 8_192)
    }

    @Test
    func addProvider_moonshotExistingProvider_stillBackfillsAllowlistModelEntry() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            var callCount = 0
            func record(raw: String) {
                self.raw = raw
                callCount += 1
            }
            func snapshot() -> (String?, Int) { (raw, callCount) }
        }
        let recorder = PatchRecorder()

        let existingConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "moonshot": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://api.moonshot.ai/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "apiKey": OpenClawProtocol.AnyCodable("sk-moonshot-test"),
                        "models": OpenClawProtocol.AnyCodable([
                            OpenClawProtocol.AnyCodable([
                                "id": OpenClawProtocol.AnyCodable("kimi-k2.5"),
                                "name": OpenClawProtocol.AnyCodable("Kimi K2.5"),
                                "reasoning": OpenClawProtocol.AnyCodable(false),
                                "contextWindow": OpenClawProtocol.AnyCodable(256_000),
                                "maxTokens": OpenClawProtocol.AnyCodable(8_192)
                            ])
                        ])
                    ])
                ])
            ]),
            "agents": OpenClawProtocol.AnyCodable([
                "defaults": OpenClawProtocol.AnyCodable([
                    "models": OpenClawProtocol.AnyCodable([
                        "anthropic/claude-sonnet-4-6": OpenClawProtocol.AnyCodable([
                            "alias": OpenClawProtocol.AnyCodable("sonnet")
                        ])
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: existingConfig, baseHash: "base-hash-moonshot-existing")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let configuredModelCount = try await manager.addProvider(
            id: "moonshot",
            baseUrl: "https://api.moonshot.ai/v1",
            apiCompatibility: "openai-completions",
            apiKey: "sk-moonshot-test",
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        #expect(configuredModelCount == 1)
        let (rawPatch, callCount) = await recorder.snapshot()
        #expect(callCount == 1)

        let rawPatchValue = try #require(rawPatch)
        let patchData = try #require(rawPatchValue.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let agents = json["agents"] as? [String: Any]
        let defaults = agents?["defaults"] as? [String: Any]
        let models = defaults?["models"] as? [String: Any]
        let moonshotAllowlist = models?["moonshot/kimi-k2.5"] as? [String: Any]

        #expect(moonshotAllowlist?["alias"] as? String == "Kimi")
    }

    @Test
    func addProvider_kimiCodingSeedsDefaultModelsWhenDiscoveryIsDisabled() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            func record(raw: String) { self.raw = raw }
            func payload() -> String? { raw }
        }
        let recorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-kimi-coding")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let configuredModelCount = try await manager.addProvider(
            id: "kimi-coding",
            baseUrl: "https://api.kimi.com/coding",
            apiCompatibility: "anthropic-messages",
            apiKey: "sk-kimi-coding-test",
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        #expect(configuredModelCount == 1)

        let rawPatch = try #require(await recorder.payload())
        let patchData = try #require(rawPatch.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let modelsSection = json["models"] as? [String: Any]
        let providers = modelsSection?["providers"] as? [String: Any]
        let kimiCoding = providers?["kimi-coding"] as? [String: Any]
        let seeded = kimiCoding?["models"] as? [[String: Any]]
        let seededIDs = Set((seeded ?? []).compactMap { $0["id"] as? String })

        #expect((kimiCoding?["apiKey"] as? String) == "sk-kimi-coding-test")
        #expect((kimiCoding?["api"] as? String) == "anthropic-messages")
        #expect((kimiCoding?["baseUrl"] as? String) == "https://api.kimi.com/coding")
        #expect(seededIDs.contains("k2p5"))
        #expect(seededIDs.contains("kimi-k2-thinking") == false)

        let agents = json["agents"] as? [String: Any]
        let defaults = agents?["defaults"] as? [String: Any]
        let allowlist = defaults?["models"] as? [String: Any]
        let k2p5 = allowlist?["kimi-coding/k2p5"] as? [String: Any]

        #expect(k2p5?["alias"] as? String == "Kimi K2.5")
        #expect(allowlist?["kimi-coding/kimi-k2-thinking"] == nil)
    }

    @Test
    func addProvider_minimaxLegacyPreset_canonicalizesToAnthropicConfig() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            func record(raw: String) { self.raw = raw }
            func payload() -> String? { raw }
        }
        let recorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-minimax")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let configuredModelCount = try await manager.addProvider(
            id: "minimax",
            baseUrl: "https://api.minimax.io/v1",
            apiCompatibility: "openai-completions",
            apiKey: "sk-minimax-test",
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        #expect(configuredModelCount == 0)

        let rawPatch = try #require(await recorder.payload())
        let patchData = try #require(rawPatch.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let modelsSection = json["models"] as? [String: Any]
        let providers = modelsSection?["providers"] as? [String: Any]
        let minimax = providers?["minimax"] as? [String: Any]

        #expect((minimax?["api"] as? String) == "anthropic-messages")
        #expect((minimax?["baseUrl"] as? String) == "https://api.minimax.io/anthropic")
        #expect((minimax?["apiKey"] as? String) == "sk-minimax-test")
        #expect((minimax?["models"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test
    func migrateLegacyMiniMaxProviderEndpointIfNeeded_rewritesLegacyV1EndpointAndAPI() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            var calls = 0
            func record(raw: String) {
                self.raw = raw
                calls += 1
            }
            func snapshot() -> (String?, Int) { (raw, calls) }
        }
        let recorder = PatchRecorder()

        let legacyConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "minimax": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://api.minimax.io/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "apiKey": OpenClawProtocol.AnyCodable("sk-minimax-test"),
                        "models": OpenClawProtocol.AnyCodable([])
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: legacyConfig, baseHash: "base-hash-minimax-legacy")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let migrated = try await manager.migrateLegacyMiniMaxProviderEndpointIfNeeded()
        #expect(migrated == true)

        let (rawPatch, callCount) = await recorder.snapshot()
        #expect(callCount == 1)

        let rawPatchValue = try #require(rawPatch)
        let patchData = try #require(rawPatchValue.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let modelsSection = json["models"] as? [String: Any]
        let providers = modelsSection?["providers"] as? [String: Any]
        let minimax = providers?["minimax"] as? [String: Any]

        #expect((minimax?["baseUrl"] as? String) == "https://api.minimax.io/anthropic")
        #expect((minimax?["api"] as? String) == "anthropic-messages")
        #expect((minimax?["apiKey"] as? String) == "sk-minimax-test")
    }

    @Test
    func migrateLegacyMiniMaxProviderEndpointIfNeeded_noopWhenAlreadyCanonical() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var calls = 0
            func record() { calls += 1 }
            func callCount() -> Int { calls }
        }
        let recorder = PatchRecorder()

        let canonicalConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "minimax": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://api.minimax.io/anthropic"),
                        "api": OpenClawProtocol.AnyCodable("anthropic-messages"),
                        "apiKey": OpenClawProtocol.AnyCodable("sk-minimax-test"),
                        "models": OpenClawProtocol.AnyCodable([])
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: canonicalConfig, baseHash: "base-hash-minimax-canonical")
                },
                configPatch: { _, _ in
                    await recorder.record()
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let migrated = try await manager.migrateLegacyMiniMaxProviderEndpointIfNeeded()
        #expect(migrated == false)
        #expect(await recorder.callCount() == 0)
    }

    @Test
    func migrateLegacyKimiCodingProviderEndpointIfNeeded_rewritesLegacyMoonshotAnthropicBaseUrl() async throws {
        let manager = OpenClawManager.shared

        actor PatchRecorder {
            var raw: String?
            var calls = 0
            func record(raw: String) {
                self.raw = raw
                calls += 1
            }
            func snapshot() -> (String?, Int) { (raw, calls) }
        }
        let recorder = PatchRecorder()

        let legacyConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "kimi-coding": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://api.moonshot.ai/anthropic"),
                        "api": OpenClawProtocol.AnyCodable("anthropic-messages"),
                        "apiKey": OpenClawProtocol.AnyCodable("sk-kimi-coding-test"),
                        "models": OpenClawProtocol.AnyCodable([
                            OpenClawProtocol.AnyCodable([
                                "id": OpenClawProtocol.AnyCodable("k2p5"),
                                "name": OpenClawProtocol.AnyCodable("Kimi K2.5"),
                                "reasoning": OpenClawProtocol.AnyCodable(true)
                            ])
                        ])
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: legacyConfig, baseHash: "base-hash-kimi-legacy")
                },
                configPatch: { raw, _ in
                    await recorder.record(raw: raw)
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let migrated = try await manager.migrateLegacyKimiCodingProviderEndpointIfNeeded()
        #expect(migrated == true)

        let (rawPatch, callCount) = await recorder.snapshot()
        #expect(callCount == 1)

        let rawPatchValue = try #require(rawPatch)
        let patchData = try #require(rawPatchValue.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let modelsSection = json["models"] as? [String: Any]
        let providers = modelsSection?["providers"] as? [String: Any]
        let kimiCoding = providers?["kimi-coding"] as? [String: Any]

        #expect((kimiCoding?["baseUrl"] as? String) == "https://api.kimi.com/coding")
        #expect((kimiCoding?["api"] as? String) == "anthropic-messages")
        #expect((kimiCoding?["apiKey"] as? String) == "sk-kimi-coding-test")
    }

    @Test
    func syncMCPProvidersToOpenClaw_redactsSensitiveValuesInErrorState() async throws {
        let manager = OpenClawManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-mcp-sync-redaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("mcporter.json")

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                skillsStatus: {
                    OpenClawSkillStatusReport(workspaceDir: "/tmp", managedSkillsDir: "/tmp", skills: [])
                },
                skillsBins: { [] },
                skillsUpdateDetailed: { _, _, _, _ in
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 500,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Authorization: Bearer sk-live-secret token=abc123 apiKey=real-key"
                        ]
                    )
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await #expect(throws: NSError.self) {
            _ = try await manager.syncMCPProvidersToOpenClaw(
                enableMcporterSkill: true,
                providerEntriesOverride: [
                    .init(name: "Example MCP", url: "https://mcp.example.com/sse", headers: [:])
                ],
                outputURLOverride: outputURL
            )
        }

        let message = manager.mcpBridgeLastSyncError ?? ""
        #expect(message.contains("[REDACTED]"))
        #expect(message.contains("sk-live-secret") == false)
        #expect(message.contains("abc123") == false)
        #expect(message.contains("real-key") == false)
    }

    @Test
    func fetchConfiguredProviders_localPlaceholderKey_notReportedAsCredential() async throws {
        let manager = OpenClawManager.shared
        manager._testSetProviderState(
            availableModels: [
                OpenClawProtocol.ModelChoice(
                    id: "foundation",
                    name: "Foundation",
                    provider: "osaurus",
                    contextwindow: 16_000,
                    reasoning: false
                )
            ],
            configuredProviders: []
        )

        let config: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "osaurus": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("http://127.0.0.1:1337/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "apiKey": OpenClawProtocol.AnyCodable("osaurus-local")
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: config, baseHash: "base-hash-placeholder")
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        try await manager.fetchConfiguredProviders()

        let provider = try #require(manager.configuredProviders.first { $0.id == "osaurus" })
        #expect(provider.hasApiKey == false)
        #expect(provider.needsKey == false)
        #expect(provider.readinessReason == .ready)
    }

    @Test
    func addProvider_requireSeededModels_throwsWhenDiscoveryIsEmpty() async {
        let manager = OpenClawManager.shared

        actor PatchCallState {
            var patchCalled = false
            func markCalled() { patchCalled = true }
            func wasCalled() -> Bool { patchCalled }
        }
        let patchState = PatchCallState()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-2")
                },
                configPatch: { _, _ in
                    await patchState.markCalled()
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                },
                discoverProviderModels: { _, _ in [] }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        do {
            _ = try await manager.addProvider(
                id: "osaurus",
                baseUrl: "http://127.0.0.1:1337/v1",
                apiCompatibility: "openai-completions",
                apiKey: nil,
                seedModelsFromEndpoint: true,
                requireSeededModels: true
            )
            Issue.record("Expected addProvider to throw when no models are discovered.")
        } catch {
            #expect(error.localizedDescription.contains("No models were discovered"))
        }

        #expect(await patchState.wasCalled() == false)
    }

    @Test
    func addProvider_osaurusLocal_startsServerBeforeDiscoveryWhenHealthIsDown() async throws {
        let manager = OpenClawManager.shared

        actor LifecycleRecorder {
            var healthy = false
            var startCalls = 0
            var discoveryCalls = 0

            func health() -> Bool { healthy }

            func start() {
                startCalls += 1
                healthy = true
            }

            func recordDiscovery() {
                discoveryCalls += 1
            }

            func snapshot() -> (Bool, Int, Int) {
                (healthy, startCalls, discoveryCalls)
            }
        }
        let recorder = LifecycleRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-osaurus-bootstrap")
                },
                configPatch: { _, _ in
                    ConfigPatchResult(ok: true, path: nil, restart: false)
                },
                discoverProviderModels: { _, _ in
                    await recorder.recordDiscovery()
                    return [OpenClawManager.ProviderSeedModel(id: "foundation", name: "foundation")]
                },
                osaurusLocalHealthCheck: {
                    await recorder.health()
                },
                osaurusLocalStart: {
                    await recorder.start()
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let discoveredCount = try await manager.addProvider(
            id: "osaurus",
            baseUrl: "http://127.0.0.1:1337/v1",
            apiCompatibility: "openai-completions",
            apiKey: nil,
            seedModelsFromEndpoint: true,
            requireSeededModels: true
        )

        let (healthy, startCalls, discoveryCalls) = await recorder.snapshot()
        #expect(discoveredCount == 1)
        #expect(healthy == true)
        #expect(startCalls == 1)
        #expect(discoveryCalls == 1)
    }

    @Test
    func addProvider_osaurusLocal_retriesDiscoveryAfterUnreachableBootstrapFailure() async throws {
        let manager = OpenClawManager.shared

        actor LifecycleRecorder {
            var healthy = false
            var startCalls = 0
            var discoveryCalls = 0

            func health() -> Bool { healthy }

            func start() {
                startCalls += 1
                healthy = true
            }

            func nextDiscoveryCall() -> Int {
                discoveryCalls += 1
                return discoveryCalls
            }

            func snapshot() -> (Int, Int) {
                (startCalls, discoveryCalls)
            }
        }
        let recorder = LifecycleRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: nil, baseHash: "base-hash-osaurus-retry")
                },
                configPatch: { _, _ in
                    ConfigPatchResult(ok: true, path: nil, restart: false)
                },
                discoverProviderModels: { _, _ in
                    let call = await recorder.nextDiscoveryCall()
                    if call == 1 {
                        throw ProviderDiscoveryError.unreachable("http://127.0.0.1:1337/v1/models")
                    }
                    return [OpenClawManager.ProviderSeedModel(id: "foundation", name: "foundation")]
                },
                osaurusLocalHealthCheck: {
                    await recorder.health()
                },
                osaurusLocalStart: {
                    await recorder.start()
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        let discoveredCount = try await manager.addProvider(
            id: "osaurus",
            baseUrl: "http://127.0.0.1:1337/v1",
            apiCompatibility: "openai-completions",
            apiKey: nil,
            seedModelsFromEndpoint: true,
            requireSeededModels: true
        )

        let (startCalls, discoveryCalls) = await recorder.snapshot()
        #expect(discoveredCount == 1)
        #expect(startCalls == 1)
        #expect(discoveryCalls == 2)
    }

    @Test
    func addProvider_idempotentWhenConfigAlreadyMatches_skipsPatch() async throws {
        let manager = OpenClawManager.shared

        actor PatchCounter {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let patchCounter = PatchCounter()

        let existingConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "openrouter": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://openrouter.ai/api/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "models": OpenClawProtocol.AnyCodable([OpenClawProtocol.AnyCodable]())
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: existingConfig, baseHash: "base-hash-idempotent")
                },
                configPatch: { _, _ in
                    await patchCounter.increment()
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        _ = try await manager.addProvider(
            id: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            apiCompatibility: "openai-completions",
            apiKey: nil,
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        #expect(await patchCounter.value() == 0)
    }

    @Test
    func removeProvider_idempotentWhenProviderMissing_skipsPatch() async throws {
        let manager = OpenClawManager.shared

        actor PatchCounter {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let patchCounter = PatchCounter()

        let existingConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "openrouter": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://openrouter.ai/api/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "models": OpenClawProtocol.AnyCodable([OpenClawProtocol.AnyCodable]())
                    ])
                ])
            ])
        ]

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    ConfigGetResult(config: existingConfig, baseHash: "base-hash-remove-idempotent")
                },
                configPatch: { _, _ in
                    await patchCounter.increment()
                    return ConfigPatchResult(ok: true, path: nil, restart: false)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        try await manager.removeProvider(id: "missing-provider")
        #expect(await patchCounter.value() == 0)
    }

    @Test
    func addProvider_retriesOnStaleBaseHashAndUsesFreshHash() async throws {
        let manager = OpenClawManager.shared

        actor ConfigSequence {
            var call = 0

            func next() -> ConfigGetResult {
                call += 1
                switch call {
                case 1:
                    return ConfigGetResult(config: nil, baseHash: "base-hash-1")
                case 2:
                    return ConfigGetResult(config: nil, baseHash: "base-hash-2")
                default:
                    return ConfigGetResult(config: nil, baseHash: "base-hash-2")
                }
            }
        }
        actor PatchRecorder {
            var hashes: [String] = []
            var callCount = 0

            func patch(raw _: String, baseHash: String) throws -> ConfigPatchResult {
                callCount += 1
                hashes.append(baseHash)
                if callCount == 1 {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "baseHash mismatch: stale revision"]
                    )
                }
                return ConfigPatchResult(ok: true, path: nil, restart: false)
            }

            func snapshot() -> (Int, [String]) {
                (callCount, hashes)
            }
        }
        let configSequence = ConfigSequence()
        let patchRecorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    await configSequence.next()
                },
                configPatch: { raw, baseHash in
                    try await patchRecorder.patch(raw: raw, baseHash: baseHash)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        _ = try await manager.addProvider(
            id: "retry-provider",
            baseUrl: "https://example.com/v1",
            apiCompatibility: "openai-completions",
            apiKey: "test-key",
            seedModelsFromEndpoint: false,
            requireSeededModels: false
        )

        let (callCount, hashes) = await patchRecorder.snapshot()
        #expect(callCount == 2)
        #expect(hashes == ["base-hash-1", "base-hash-2"])
    }

    @Test
    func removeProvider_retriesOnStaleBaseHashAndUsesFreshHash() async throws {
        let manager = OpenClawManager.shared

        let existingProviderConfig: [String: OpenClawProtocol.AnyCodable] = [
            "models": OpenClawProtocol.AnyCodable([
                "providers": OpenClawProtocol.AnyCodable([
                    "retry-remove": OpenClawProtocol.AnyCodable([
                        "baseUrl": OpenClawProtocol.AnyCodable("https://example.com/v1"),
                        "api": OpenClawProtocol.AnyCodable("openai-completions"),
                        "models": OpenClawProtocol.AnyCodable([OpenClawProtocol.AnyCodable]())
                    ])
                ])
            ])
        ]

        actor ConfigSequence {
            var call = 0
            let existingProviderConfig: [String: OpenClawProtocol.AnyCodable]

            init(existingProviderConfig: [String: OpenClawProtocol.AnyCodable]) {
                self.existingProviderConfig = existingProviderConfig
            }

            func next() -> ConfigGetResult {
                call += 1
                switch call {
                case 1:
                    return ConfigGetResult(config: existingProviderConfig, baseHash: "remove-base-hash-1")
                case 2:
                    return ConfigGetResult(config: existingProviderConfig, baseHash: "remove-base-hash-2")
                default:
                    return ConfigGetResult(config: nil, baseHash: "remove-base-hash-2")
                }
            }
        }
        actor PatchRecorder {
            var hashes: [String] = []
            var callCount = 0

            func patch(baseHash: String) throws -> ConfigPatchResult {
                callCount += 1
                hashes.append(baseHash)
                if callCount == 1 {
                    throw NSError(
                        domain: "OpenClawManagerTests",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "stale baseHash conflict"]
                    )
                }
                return ConfigPatchResult(ok: true, path: nil, restart: false)
            }

            func snapshot() -> (Int, [String]) {
                (callCount, hashes)
            }
        }
        let configSequence = ConfigSequence(existingProviderConfig: existingProviderConfig)
        let patchRecorder = PatchRecorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                configGetFull: {
                    await configSequence.next()
                },
                configPatch: { _, baseHash in
                    try await patchRecorder.patch(baseHash: baseHash)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        try await manager.removeProvider(id: "retry-remove")

        let (callCount, hashes) = await patchRecorder.snapshot()
        #expect(callCount == 2)
        #expect(hashes == ["remove-base-hash-1", "remove-base-hash-2"])
    }

    @Test
    func discoverProviderModels_openAIShape_parsesModels() async throws {
        let manager = OpenClawManager.shared
        let payload = """
        {
          "data": [
            { "id": "gpt-4o-mini", "name": "GPT-4o mini", "contextWindow": 128000, "maxTokens": 8192 }
          ]
        }
        """
        let data = try #require(payload.data(using: .utf8))
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1337/v1/models")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let models = try await manager._testDiscoverProviderModels(
            baseUrl: "http://127.0.0.1:1337/v1",
            apiKey: nil,
            fetch: { _ in (data, response) }
        )

        #expect(models.count == 1)
        #expect(models.first?.id == "gpt-4o-mini")
        #expect(models.first?.name == "GPT-4o mini")
        #expect(models.first?.contextWindow == 128_000)
    }

    @Test
    func discoverProviderModels_ollamaLikeShape_parsesModels() async throws {
        let manager = OpenClawManager.shared
        let payload = """
        {
          "models": [
            { "name": "qwen2.5-coder:latest", "model": "qwen2.5-coder:latest" }
          ]
        }
        """
        let data = try #require(payload.data(using: .utf8))
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:11434/models")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let models = try await manager._testDiscoverProviderModels(
            baseUrl: "http://127.0.0.1:11434",
            apiKey: nil,
            fetch: { _ in (data, response) }
        )

        #expect(models.count == 1)
        #expect(models.first?.id == "qwen2.5-coder:latest")
        #expect(models.first?.name == "qwen2.5-coder:latest")
    }

    @Test
    func discoverProviderModels_emptyShape_returnsNoModels() async throws {
        let manager = OpenClawManager.shared
        let payload = """
        { "data": [] }
        """
        let data = try #require(payload.data(using: .utf8))
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1337/models")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let models = try await manager._testDiscoverProviderModels(
            baseUrl: "http://127.0.0.1:1337",
            apiKey: nil,
            fetch: { _ in (data, response) }
        )

        #expect(models.isEmpty)
    }

    @Test
    func discoverProviderModels_malformedPayload_throwsTypedError() async throws {
        let manager = OpenClawManager.shared
        let malformed = Data("not-json".utf8)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1337/models")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        do {
            _ = try await manager._testDiscoverProviderModels(
                baseUrl: "http://127.0.0.1:1337",
                apiKey: nil,
                fetch: { _ in (malformed, response) }
            )
            Issue.record("Expected malformed provider models payload to throw.")
        } catch let error as ProviderDiscoveryError {
            #expect(error == .malformedPayload)
        }
    }

    @Test
    func discoverProviderModels_timeoutOnLocalEndpoint_retriesAndRecovers() async throws {
        let manager = OpenClawManager.shared
        actor AttemptCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
            func value() -> Int { count }
        }
        let counter = AttemptCounter()
        let payload = """
        { "data": [ { "id": "foundation" } ] }
        """
        let data = try #require(payload.data(using: .utf8))
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1337/v1/models")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let models = try await manager._testDiscoverProviderModels(
            baseUrl: "http://127.0.0.1:1337/v1",
            apiKey: nil,
            fetch: { _ in
                let attempt = await counter.next()
                if attempt < 3 {
                    throw URLError(.timedOut)
                }
                return (data, response)
            }
        )

        #expect(models.count == 1)
        #expect(await counter.value() == 3)
    }

    @Test
    func providerReadinessReason_noKey_returnsActionableMessage() async {
        let manager = OpenClawManager.shared
        manager._testSetProviderState(
            availableModels: [
                OpenClawProtocol.ModelChoice(
                    id: "gpt-4o-mini",
                    name: "GPT-4o mini",
                    provider: "openrouter",
                    contextwindow: 128_000,
                    reasoning: false
                )
            ],
            configuredProviders: [
                OpenClawManager.ProviderInfo(
                    id: "openrouter",
                    name: "Openrouter",
                    modelCount: 1,
                    hasApiKey: false,
                    needsKey: true,
                    readinessReason: .noKey
                )
            ]
        )

        let reason = manager.providerReadinessReason(forModelId: "openclaw-model:gpt-4o-mini")
        #expect(reason == .noKey)
        #expect(OpenClawManager.providerReadinessMessage(for: reason).contains("API key"))
    }

    @Test
    func providerReadinessReason_usesOverrideAndNoModelsFallback() async {
        let manager = OpenClawManager.shared
        manager._testSetProviderState(
            availableModels: [
                OpenClawProtocol.ModelChoice(
                    id: "qwen2.5-coder",
                    name: "Qwen2.5 Coder",
                    provider: "osaurus",
                    contextwindow: 32_000,
                    reasoning: true
                )
            ],
            configuredProviders: [
                OpenClawManager.ProviderInfo(
                    id: "osaurus",
                    name: "Osaurus",
                    modelCount: 1,
                    hasApiKey: true,
                    needsKey: false,
                    readinessReason: .ready
                )
            ],
            readinessOverrides: ["osaurus": .unreachable]
        )

        #expect(manager.providerReadinessReason(forModelId: "openclaw-model:qwen2.5-coder") == .unreachable)
        #expect(
            OpenClawManager.providerReadinessMessage(for: .unreachable).contains("unreachable")
        )

        manager._testSetProviderState(
            availableModels: [],
            configuredProviders: [
                OpenClawManager.ProviderInfo(
                    id: "osaurus",
                    name: "Osaurus",
                    modelCount: 0,
                    hasApiKey: true,
                    needsKey: false,
                    readinessReason: .noModels
                )
            ]
        )
        #expect(manager.providerReadinessReason(forModelId: "openclaw-model:missing") == .noModels)
    }

    @Test
    func providerReadinessReason_acceptsProviderQualifiedModelReferences() async {
        let manager = OpenClawManager.shared
        manager._testSetProviderState(
            availableModels: [
                OpenClawProtocol.ModelChoice(
                    id: "moonshotai/kimi-k2",
                    name: "Kimi K2",
                    provider: "openrouter",
                    contextwindow: 128_000,
                    reasoning: true
                )
            ],
            configuredProviders: [
                OpenClawManager.ProviderInfo(
                    id: "openrouter",
                    name: "OpenRouter",
                    modelCount: 1,
                    hasApiKey: true,
                    needsKey: true,
                    readinessReason: .ready
                )
            ]
        )

        #expect(
            manager.providerReadinessReason(
                forModelId: "openclaw-model:openrouter/moonshotai/kimi-k2"
            ) == .ready
        )
    }

    @Test
    func canonicalModelReference_prefixesProviderForBareModelIds() async {
        let manager = OpenClawManager.shared
        let previousModels = manager.availableModels
        let previousProviders = manager.configuredProviders
        defer {
            manager._testSetProviderState(
                availableModels: previousModels,
                configuredProviders: previousProviders
            )
        }

        manager._testSetProviderState(
            availableModels: [
                OpenClawProtocol.ModelChoice(
                    id: "foundation",
                    name: "Foundation",
                    provider: "anthropic",
                    contextwindow: 16_000,
                    reasoning: false
                ),
                OpenClawProtocol.ModelChoice(
                    id: "foundation",
                    name: "Foundation",
                    provider: "osaurus",
                    contextwindow: 16_000,
                    reasoning: false
                )
            ],
            configuredProviders: [
                OpenClawManager.ProviderInfo(
                    id: "anthropic",
                    name: "Anthropic",
                    modelCount: 1,
                    hasApiKey: false,
                    needsKey: true,
                    readinessReason: .noKey
                ),
                OpenClawManager.ProviderInfo(
                    id: "osaurus",
                    name: "Osaurus",
                    modelCount: 1,
                    hasApiKey: true,
                    needsKey: false,
                    readinessReason: .ready
                )
            ]
        )

        #expect(manager.canonicalModelReference(for: "foundation") == "osaurus/foundation")
        #expect(manager.canonicalModelReference(for: "osaurus/foundation") == "osaurus/foundation")
        #expect(manager.canonicalModelReference(for: "unknown-model") == "unknown-model")
    }

    // MARK: - refreshStatus concurrency

    @Test
    func refreshStatus_runsIndependentCallsConcurrently() async {
        let manager = OpenClawManager.shared

        actor Recorder {
            var callOrder: [String] = []

            func record(_ label: String) {
                callOrder.append(label)
            }

            func snapshot() -> [String] {
                callOrder
            }
        }
        let recorder = Recorder()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: {
                    await recorder.record("channels-start")
                    try await Task.sleep(nanoseconds: 50_000_000)
                    await recorder.record("channels-end")
                    return []
                },
                modelsList: {
                    await recorder.record("models-start")
                    try await Task.sleep(nanoseconds: 50_000_000)
                    await recorder.record("models-end")
                    return []
                },
                health: {
                    await recorder.record("health-start")
                    try await Task.sleep(nanoseconds: 50_000_000)
                    await recorder.record("health-end")
                    return [:]
                },
                heartbeatStatus: {
                    await recorder.record("heartbeat-start")
                    try await Task.sleep(nanoseconds: 50_000_000)
                    await recorder.record("heartbeat-end")
                    return OpenClawHeartbeatStatus(enabled: true, lastHeartbeatAt: nil)
                }
            )
        )
        defer { OpenClawManager._testSetGatewayHooks(nil) }

        manager._testSetConnectionState(.connected, gatewayStatus: .running)
        await manager.refreshStatus()

        let order = await recorder.snapshot()

        // If calls run concurrently, models-start and/or health-start should appear
        // before channels-end (they started while channels was still sleeping).
        guard let channelsEndIndex = order.firstIndex(of: "channels-end") else {
            Issue.record("channels-end not found in call order: \(order)")
            return
        }

        let modelsStartedBeforeChannelsEnd = order.firstIndex(of: "models-start").map { $0 < channelsEndIndex } ?? false
        let healthStartedBeforeChannelsEnd = order.firstIndex(of: "health-start").map { $0 < channelsEndIndex } ?? false

        #expect(
            modelsStartedBeforeChannelsEnd || healthStartedBeforeChannelsEnd,
            "Expected models or health to start before channels finished, but call order was serial: \(order)"
        )
    }
}
