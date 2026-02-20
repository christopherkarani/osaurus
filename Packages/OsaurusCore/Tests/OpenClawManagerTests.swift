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
}
