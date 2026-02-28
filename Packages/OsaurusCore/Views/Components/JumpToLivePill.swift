//
//  JumpToLivePill.swift
//  osaurus
//
//  Floating pill shown when user scrolls up during active execution.
//  Tapping re-pins to the live position.
//

import SwiftUI

struct JumpToLivePill: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isPulsing ? 1.3 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                Text("Working...")
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.secondaryBackground)
                    .shadow(color: theme.shadowColor.opacity(0.2), radius: 8, x: 0, y: 4)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear { isPulsing = true }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .bottom))
        ))
    }
}
