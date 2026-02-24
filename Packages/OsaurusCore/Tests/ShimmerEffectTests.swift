//
//  ShimmerEffectTests.swift
//  osaurus
//
//  Tests for ShimmerEffect sweep logic and constants.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ShimmerEffect Logic")
struct ShimmerEffectTests {
    @Test func sweepDuration() {
        #expect(ShimmerEffectLogic.sweepDuration == 1.5)
    }

    @Test func gradientWidthFraction() {
        #expect(ShimmerEffectLogic.gradientWidthFraction == 0.4)
    }

    @Test func startOffset() {
        #expect(ShimmerEffectLogic.startOffset(viewWidth: 300) == -120)
    }

    @Test func endOffset() {
        #expect(ShimmerEffectLogic.endOffset(viewWidth: 300) == 300)
    }
}
