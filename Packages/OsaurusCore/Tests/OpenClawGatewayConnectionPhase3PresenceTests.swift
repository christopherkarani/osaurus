//
//  OpenClawGatewayConnectionPhase3PresenceTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawPresenceCallRecorder {
    private var calls: [(String, [String: OpenClawProtocol.AnyCodable]?)] = []

    func record(_ method: String, _ params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append((method, params))
    }

    func last() -> (String, [String: OpenClawProtocol.AnyCodable]?)? {
        calls.last
    }
}

struct OpenClawGatewayConnectionPhase3PresenceTests {
    @Test
    func systemPresence_decodesConnectedClientRows() async throws {
        let recorder = OpenClawPresenceCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method, params)
            let payload: [[String: Any]] = [
                [
                    "instanceId": "mac-1",
                    "host": "Chris-MacBook-Pro",
                    "version": "1.2.3",
                    "platform": "macos 14.5",
                    "roles": ["chat-client", "tool-executor"],
                    "mode": "chat",
                    "ts": 1_708_345_600_000
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let entries = try await connection.systemPresence()
        let call = try #require(await recorder.last())

        #expect(call.0 == "system-presence")
        #expect(entries.count == 1)
        #expect(entries[0].id == "mac-1")
        #expect(entries[0].displayName == "Chris-MacBook-Pro")
        #expect(entries[0].roles.contains("chat-client"))
        #expect(entries[0].connectedAt.timeIntervalSince1970 > 0)
    }
}
