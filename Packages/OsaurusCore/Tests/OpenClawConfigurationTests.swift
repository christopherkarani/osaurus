//
//  OpenClawConfigurationTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct OpenClawConfigurationTests {
    @Test func codableRoundTrip_preservesFields() throws {
        let configuration = OpenClawConfiguration(
            isEnabled: true,
            gatewayPort: 19191,
            gatewayURL: "wss://gateway.example.com/ws",
            gatewayHealthURL: "https://gateway.example.com/health",
            bindMode: .lan,
            autoStartGateway: false,
            autoSyncMCPBridge: false,
            installPath: "/tmp/openclaw",
            lastKnownVersion: "1.2.3"
        )

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(OpenClawConfiguration.self, from: encoded)

        #expect(decoded == configuration)
    }

    @Test func decoder_usesDefaultsForMissingFields() throws {
        let partial: [String: Any] = [
            "isEnabled": true
        ]
        let data = try JSONSerialization.data(withJSONObject: partial)
        let decoded = try JSONDecoder().decode(OpenClawConfiguration.self, from: data)

        #expect(decoded.isEnabled == true)
        #expect(decoded.gatewayPort == 18789)
        #expect(decoded.gatewayURL == nil)
        #expect(decoded.gatewayHealthURL == nil)
        #expect(decoded.bindMode == .loopback)
        #expect(decoded.autoStartGateway == true)
        #expect(decoded.autoSyncMCPBridge == true)
        #expect(decoded.installPath == "~/.openclaw")
        #expect(decoded.lastKnownVersion == nil)
    }

    @Test func bindMode_rawValueRoundTrip() throws {
        let data = "\"lan\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenClawConfiguration.BindMode.self, from: data)
        #expect(decoded == .lan)

        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(data: encoded, encoding: .utf8) == "\"lan\"")
    }
}
