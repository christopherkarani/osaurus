//
//  UserMessageCardViewTests.swift
//  osaurus
//
//  Tests for UserMessageCardView style constants.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("UserMessageCard Style")
struct UserMessageCardViewTests {
    @Test func cornerRadiusIs12() {
        #expect(UserMessageCardStyle.cornerRadius == 12)
    }

    @Test func noGlass() {
        #expect(UserMessageCardStyle.hasGlass == false)
    }

    @Test func noShadow() {
        #expect(UserMessageCardStyle.hasShadow == false)
    }

    @Test func noEdgeLight() {
        #expect(UserMessageCardStyle.hasEdgeLight == false)
    }

    @Test func backgroundUsesElevated() {
        #expect(UserMessageCardStyle.backgroundTokenName == "tertiaryBackground")
    }
}
