//
//  DarkTechCyanThemeTests.swift
//  osaurus
//
//  Tests that Dark and Light themes use the Dark Tech + Cyan palette.
//

import SwiftUI
import Testing

@testable import OsaurusCore

@Suite("Dark Tech + Cyan Theme")
struct DarkTechCyanThemeTests {
    @Test func darkAccentIsCyan() {
        let theme = DarkTheme()
        #expect(theme.accentColor == Color(hex: "06b6d4"))
    }

    @Test func darkPrimaryBackground() {
        let theme = DarkTheme()
        #expect(theme.primaryBackground == Color(hex: "0c0c0c"))
    }

    @Test func darkBubbleCornerRadius() {
        let theme = DarkTheme()
        #expect(theme.bubbleCornerRadius == 12)
    }

    @Test func darkGlassDisabled() {
        let theme = DarkTheme()
        #expect(theme.glassEnabled == false)
    }

    @Test func darkEdgeLightDisabled() {
        let theme = DarkTheme()
        #expect(theme.showEdgeLight == false)
    }

    @Test func lightAccentIsCyan() {
        let theme = LightTheme()
        #expect(theme.accentColor == Color(hex: "0891b2"))
    }

    @Test func lightPrimaryBackground() {
        let theme = LightTheme()
        #expect(theme.primaryBackground == Color(hex: "fafafa"))
    }
}
