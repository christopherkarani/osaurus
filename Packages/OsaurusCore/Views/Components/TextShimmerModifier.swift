//
//  TextShimmerModifier.swift
//  osaurus
//
//  A subtle text-level shimmer for streaming AI content.
//  Distinct from ShimmerEffectModifier (cards/containers).
//  Applies a gentle gradient sweep + foreground opacity oscillation.
//

import SwiftUI

struct TextShimmerModifier: ViewModifier {
    let isActive: Bool
    let accentColor: Color
    let period: Double

    @State private var phase: CGFloat = 0

    init(isActive: Bool, accentColor: Color, period: Double = 2.0) {
        self.isActive = isActive
        self.accentColor = accentColor
        self.period = period
    }

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? (0.7 + 0.3 * (0.5 + 0.5 * sin(Double(phase) * .pi * 2))) : 1.0)
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, accentColor.opacity(0.06), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: -geo.size.width * 0.5 + phase * geo.size.width * 1.5)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard isActive else { return }
                withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    phase = 0
                    withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        phase = 0
                    }
                }
            }
    }
}

extension View {
    func textShimmer(isActive: Bool, accentColor: Color, period: Double = 2.0) -> some View {
        modifier(TextShimmerModifier(isActive: isActive, accentColor: accentColor, period: period))
    }
}
