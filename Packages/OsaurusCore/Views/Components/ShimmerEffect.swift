//
//  ShimmerEffect.swift
//  osaurus
//
//  Reusable shimmer sweep modifier for in-progress states.
//  A translucent gradient band sweeps left-to-right on a loop.
//

import SwiftUI

// MARK: - Logic (testable)

enum ShimmerEffectLogic {
    static let sweepDuration: Double = 1.5
    static let gradientWidthFraction: Double = 0.4

    static func startOffset(viewWidth: CGFloat) -> CGFloat {
        -viewWidth * gradientWidthFraction
    }

    static func endOffset(viewWidth: CGFloat) -> CGFloat {
        viewWidth
    }
}

// MARK: - ViewModifier

struct ShimmerEffectModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color
    let period: Double

    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                GeometryReader { geo in
                    let width = geo.size.width * ShimmerEffectLogic.gradientWidthFraction
                    LinearGradient(
                        colors: [.clear, accentColor.opacity(0.08), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: width)
                    .offset(
                        x: ShimmerEffectLogic.startOffset(viewWidth: geo.size.width)
                            + phase * (geo.size.width + width)
                    )
                    .onAppear {
                        withAnimation(
                            .linear(duration: period)
                                .repeatForever(autoreverses: false)
                        ) {
                            phase = 1
                        }
                    }
                }
                .clipped()
            }
        }
    }
}

// MARK: - View Extension

extension View {
    func shimmerEffect(isActive: Bool, accentColor: Color, period: Double = ShimmerEffectLogic.sweepDuration) -> some View {
        modifier(ShimmerEffectModifier(isActive: isActive, accentColor: accentColor, period: period))
    }
}
