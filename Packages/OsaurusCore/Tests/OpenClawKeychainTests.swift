//
//  OpenClawKeychainTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawKeychainTests {
    @Test func tokenAndDeviceToken_lifecycle() throws {
        let uniqueService = "ai.osaurus.openclaw.tests.\(UUID().uuidString)"
        OpenClawKeychain.serviceOverride = uniqueService
        defer {
            _ = OpenClawKeychain.deleteToken()
            _ = OpenClawKeychain.deleteDeviceToken()
            OpenClawKeychain.serviceOverride = nil
        }

        #expect(OpenClawKeychain.hasToken() == false)
        #expect(OpenClawKeychain.saveToken("token-1") == true)
        #expect(OpenClawKeychain.hasToken() == true)
        #expect(OpenClawKeychain.getToken() == "token-1")

        #expect(OpenClawKeychain.saveToken("token-2") == true)
        #expect(OpenClawKeychain.getToken() == "token-2")
        #expect(OpenClawKeychain.deleteToken() == true)
        #expect(OpenClawKeychain.getToken() == nil)

        #expect(OpenClawKeychain.saveDeviceToken("device-abc") == true)
        #expect(OpenClawKeychain.getDeviceToken() == "device-abc")
        #expect(OpenClawKeychain.deleteDeviceToken() == true)
        #expect(OpenClawKeychain.getDeviceToken() == nil)
    }
}
