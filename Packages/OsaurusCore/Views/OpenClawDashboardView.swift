//
//  OpenClawDashboardView.swift
//  osaurus
//

import SwiftUI

struct OpenClawDashboardView: View {
    @ObservedObject private var manager = OpenClawManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var showSetupWizard = false
    @State private var hasAppeared = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -8)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if manager.configuration.isEnabled {
                        configuredContent
                    } else {
                        emptyState
                    }
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            Task {
                await manager.checkEnvironment()
                await manager.refreshStatus()
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            OpenClawSetupWizardSheet(manager: manager)
        }
    }

    private var header: some View {
        ManagerHeaderWithActions(
            title: "OpenClaw",
            subtitle: subtitleText
        ) {
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                Task {
                    await manager.checkEnvironment()
                    await manager.refreshStatus()
                }
            }
            HeaderPrimaryButton(
                manager.configuration.isEnabled ? "Setup" : "Get Started",
                icon: manager.configuration.isEnabled ? "slider.horizontal.3" : "wand.and.stars"
            ) {
                showSetupWizard = true
            }
        }
    }

    private var subtitleText: String {
        switch manager.phase {
        case .notConfigured:
            return "Set up a local OpenClaw gateway for channel-aware chat."
        case .checkingEnvironment:
            return "Checking local OpenClaw requirements…"
        case .environmentBlocked:
            return "Environment setup required before connecting."
        case .installingCLI:
            return "Installing OpenClaw CLI…"
        case .configured:
            return "Gateway configured but not started."
        case .startingGateway:
            return "Starting OpenClaw gateway…"
        case .gatewayRunning:
            return manager.isConnected ? "Gateway running and connected." : "Gateway running."
        case .connecting:
            return "Connecting to gateway websocket…"
        case .connected:
            return "\(manager.channels.count) channels \u{2022} \(manager.availableModels.count) models"
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))…"
        case .gatewayFailed(let message), .connectionFailed(let message):
            return message
        }
    }

    private var configuredContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            OpenClawGatewayStatusCard(manager: manager)

            if !manager.activeSessions.isEmpty {
                sectionTitle("Active Sessions")
                VStack(spacing: 10) {
                    ForEach(manager.activeSessions) { session in
                        OpenClawActiveSessionView(manager: manager, session: session)
                    }
                }
            }

            if !manager.channels.isEmpty {
                sectionTitle("Channels")
                VStack(spacing: 10) {
                    ForEach(manager.channels) { channel in
                        OpenClawChannelCard(channel: channel)
                    }
                }
            }

            if !manager.availableModels.isEmpty {
                sectionTitle("Gateway Models")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(manager.availableModels, id: \.self) { model in
                        Text(model)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.secondaryBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.primaryBorder, lineWidth: 1)
                                    )
                            )
                    }
                }
            }

            if let health = manager.lastHealth {
                sectionTitle("Health")
                GlassListRow {
                    VStack(alignment: .leading, spacing: 8) {
                        metricRow("Version", value: health.version)
                        metricRow("Uptime", value: "\(Int(health.uptime))s")
                        metricRow("Memory", value: String(format: "%.1f MB", health.memoryMB))
                        metricRow("Active Runs", value: "\(health.activeRuns)")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("OpenClaw Is Not Configured")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Install the OpenClaw CLI, configure the gateway, and connect channels from one place.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HeaderPrimaryButton("Get Started", icon: "wand.and.stars") {
                showSetupWizard = true
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.secondaryText)
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
    }
}
