//
//  OpenClawManagerOnboardingTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct OpenClawManagerOnboardingTests {
    @Test
    func refreshOnboardingState_marksRequiredWhenBootstrapFileExists() async {
        let manager = OpenClawManager.shared
        let originalConfig = manager.configuration
        var config = originalConfig
        config.isEnabled = true
        config.gatewayURL = nil
        manager._testSetConfiguration(config)
        defer {
            manager._testSetConfiguration(originalConfig)
            OpenClawManager._testSetGatewayHooks(nil)
        }

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
                agentsFilesList: { _ in
                    OpenClawAgentFilesListResponse(
                        agentId: "main",
                        workspace: "/tmp/workspace-main",
                        files: [
                            OpenClawAgentWorkspaceFile(
                                name: "BOOTSTRAP.md",
                                path: "/tmp/workspace-main/BOOTSTRAP.md",
                                missing: false,
                                size: 1024,
                                updatedAtMs: 1_708_000_000_000,
                                content: nil
                            )
                        ]
                    )
                }
            )
        )

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshOnboardingState(force: true)

        #expect(manager.onboardingState == .required)
        #expect(manager.isLocalOnboardingGateRequired == true)
    }

    @Test
    func refreshOnboardingState_marksNotRequiredWhenBootstrapMissingFromListing() async {
        let manager = OpenClawManager.shared
        let originalConfig = manager.configuration
        var config = originalConfig
        config.isEnabled = true
        config.gatewayURL = nil
        manager._testSetConfiguration(config)
        defer {
            manager._testSetConfiguration(originalConfig)
            OpenClawManager._testSetGatewayHooks(nil)
        }

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
                agentsFilesList: { _ in
                    OpenClawAgentFilesListResponse(
                        agentId: "main",
                        workspace: "/tmp/workspace-main",
                        files: [
                            OpenClawAgentWorkspaceFile(
                                name: "IDENTITY.md",
                                path: "/tmp/workspace-main/IDENTITY.md",
                                missing: false,
                                size: 1024,
                                updatedAtMs: 1_708_000_000_000,
                                content: nil
                            )
                        ]
                    )
                }
            )
        )

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshOnboardingState(force: true)

        #expect(manager.onboardingState == .notRequired)
        #expect(manager.isLocalOnboardingGateRequired == false)
    }

    @Test
    func refreshOnboardingState_usesNotRequiredForCustomGatewayEndpoint() async {
        let manager = OpenClawManager.shared
        let originalConfig = manager.configuration
        var config = originalConfig
        config.isEnabled = true
        config.gatewayURL = "wss://gateway.example.com/ws"
        manager._testSetConfiguration(config)
        defer {
            manager._testSetConfiguration(originalConfig)
            OpenClawManager._testSetGatewayHooks(nil)
        }

        actor Calls {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }
        let calls = Calls()

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                agentsList: {
                    await calls.increment()
                    throw NSError(
                        domain: "OpenClawManagerOnboardingTests",
                        code: 501,
                        userInfo: [NSLocalizedDescriptionKey: "should not query agents for custom gateway"]
                    )
                }
            )
        )

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshOnboardingState(force: true)

        #expect(await calls.value() == 0)
        #expect(manager.onboardingState == .notRequired)
        #expect(manager.isLocalOnboardingGateRequired == false)
    }

    @Test
    func refreshOnboardingState_reportsFailureWhenAgentListingErrors() async {
        let manager = OpenClawManager.shared
        let originalConfig = manager.configuration
        var config = originalConfig
        config.isEnabled = true
        config.gatewayURL = nil
        manager._testSetConfiguration(config)
        defer {
            manager._testSetConfiguration(originalConfig)
            OpenClawManager._testSetGatewayHooks(nil)
        }

        OpenClawManager._testSetGatewayHooks(
            .init(
                channelsStatus: { [] },
                modelsList: { [] },
                health: { [:] },
                agentsList: {
                    throw NSError(
                        domain: "OpenClawManagerOnboardingTests",
                        code: 777,
                        userInfo: [NSLocalizedDescriptionKey: "simulated onboarding listing failure"]
                    )
                }
            )
        )

        await manager._testResetConnectionObservation()
        manager._testSetConnectionState(.connected, gatewayStatus: .running)

        await manager.refreshOnboardingState(force: true)

        switch manager.onboardingState {
        case .failed(let message):
            #expect(message.contains("simulated onboarding listing failure"))
        default:
            Issue.record("Expected onboarding state to be failed, got \(manager.onboardingState)")
        }
        #expect(manager.isLocalOnboardingGateRequired == false)
    }
}
