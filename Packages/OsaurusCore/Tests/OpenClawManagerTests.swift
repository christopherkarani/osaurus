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
