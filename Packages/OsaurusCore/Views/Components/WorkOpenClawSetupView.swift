//
//  WorkOpenClawSetupView.swift
//  osaurus
//
//  Shown in Work mode when OpenClaw is not configured.
//

import SwiftUI

struct WorkOpenClawSetupView: View {
    @ObservedObject private var openClawManager = OpenClawManager.shared
    @Environment(\.theme) private var theme

    @State private var hasAppeared = false
    @State private var showingSetup = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    setupState
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) { hasAppeared = true }
            }
        }
        .onDisappear { hasAppeared = false }
        .sheet(isPresented: $showingSetup) {
            OpenClawSetupWizardSheet(manager: openClawManager)
        }
    }

    // MARK: - Setup State

    private var setupState: some View {
        VStack(spacing: 28) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "work-openclaw")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation(), value: hasAppeared)

            VStack(spacing: 12) {
                Text("Work")
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text("OpenClaw is required to use Work mode.")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }

            Button {
                showingSetup = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("Set up OpenClaw")
                }
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }
}
