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
}
