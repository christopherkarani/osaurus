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
                    "deviceId": "device-123",
                    "instanceId": "mac-1",
                    "host": "Chris-MacBook-Pro",
                    "version": "1.2.3",
                    "platform": "macos 14.5",
                    "roles": ["chat-client", "tool-executor"],
                    "scopes": ["operator.read", "operator.admin"],
                    "tags": ["desktop"],
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
        #expect(entries[0].id == "device-123")
        #expect(entries[0].displayName == "Chris-MacBook-Pro")
        #expect(entries[0].roles.contains("chat-client"))
        #expect(entries[0].tags == ["desktop"])
        #expect(entries[0].connectedAt.timeIntervalSince1970 > 0)
    }

    @Test
    func systemPresence_normalizesSecondTimestamps() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "system-presence")
            let payload: [[String: Any]] = [
                [
                    "deviceId": "device-seconds",
                    "host": "Seconds-Host",
                    "ts": 1_708_345_600
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let entries = try await connection.systemPresence()

        #expect(entries.count == 1)
        #expect(entries[0].id == "device-seconds")
        #expect(abs(entries[0].connectedAt.timeIntervalSince1970 - 1_708_345_600) < 0.5)
    }

    @Test
    func systemPresence_normalizesStringSecondTimestamps() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "system-presence")
            let payload: [[String: Any]] = [
                [
                    "instanceId": "instance-string-ts",
                    "host": "StringTsHost",
                    "ts": "1708345600"
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let entries = try await connection.systemPresence()

        #expect(entries.count == 1)
        #expect(entries[0].id == "instance-string-ts")
        #expect(abs(entries[0].connectedAt.timeIntervalSince1970 - 1_708_345_600) < 0.5)
    }

    @Test
    func systemPresence_identityFallbackPrefersDeviceThenInstanceThenHostThenIP() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "system-presence")
            let payload: [[String: Any]] = [
                [
                    "deviceId": "device-first",
                    "instanceId": "instance-first",
                    "host": "host-first",
                    "ip": "10.0.0.10",
                    "ts": 1_708_345_600_000
                ],
                [
                    "instanceId": "instance-only",
                    "host": "host-second",
                    "ip": "10.0.0.11",
                    "ts": 1_708_345_601_000
                ],
                [
                    "host": "host-only",
                    "ip": "10.0.0.12",
                    "ts": 1_708_345_602_000
                ],
                [
                    "ip": "10.0.0.13",
                    "ts": 1_708_345_603_000
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let entries = try await connection.systemPresence()

        #expect(entries.count == 4)
        #expect(entries.map(\.id) == ["device-first", "instance-only", "host-only", "10.0.0.13"])
        #expect(entries.map(\.displayName) == ["host-first", "host-second", "host-only", "10.0.0.13"])
    }
}
