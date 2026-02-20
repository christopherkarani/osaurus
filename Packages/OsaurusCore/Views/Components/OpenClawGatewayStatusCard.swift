//
//  OpenClawGatewayStatusCard.swift
//  osaurus
//

import SwiftUI

struct OpenClawGatewayStatusCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var isBusy = false
    @State private var isHeartbeatBusy = false
    @State private var isHovered = false
    @State private var hasAppeared = false
    @State private var showStopConfirmation = false
    @State private var showDisconnectConfirmation = false

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.12))
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Gateway")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            statusBadge
                        }
                        Text("Port \(manager.configuration.gatewayPort)")
                            .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    controls
                }
                if manager.gatewayStatus == .running {
                    heartbeatControls
                }
                if let message = errorMessage, !message.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(message)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.08))
                    )
                }

            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Gateway status: \(statusText)")
            .accessibilityValue(
                manager.gatewayStatus == .running
                    ? "Running on port \(manager.configuration.gatewayPort)"
                    : "Stopped"
            )
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)
        .onHover { isHovered = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
        .themedAlert(
            "Stop OpenClaw Gateway",
            isPresented: $showStopConfirmation,
            message: "This will stop the OpenClaw process and disconnect active runs.",
            primaryButton: .destructive("Stop Gateway") {
                Task { await performStop() }
            },
            secondaryButton: .cancel("Cancel"),
            presentationStyle: .contained
        )
        .themedAlert(
            "Disconnect OpenClaw",
            isPresented: $showDisconnectConfirmation,
            message: "Disconnecting will pause the live OpenClaw event stream. You can reconnect when needed.",
            primaryButton: .destructive("Disconnect") {
                manager.disconnect()
            },
            secondaryButton: .cancel("Cancel"),
            presentationStyle: .contained
        )
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if manager.gatewayStatus == .running {
                HeaderSecondaryButton("Stop", icon: "stop.fill") {
                    showStopConfirmation = true
                }
                .disabled(disableControls)

                if manager.isConnected {
                    HeaderSecondaryButton("Disconnect", icon: "bolt.slash.fill") {
                        showDisconnectConfirmation = true
                    }
                    .disabled(disableControls)
                } else {
                    HeaderPrimaryButton("Connect", icon: "bolt.horizontal.fill") {
                        Task { await performConnect() }
                    }
                    .disabled(disableControls)
                }
            } else {
                HeaderPrimaryButton("Start Gateway", icon: "play.fill") {
                    Task { await performStart() }
                }
                .disabled(disableControls)
            }
        }
    }

    @ViewBuilder
    private var heartbeatControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(
                    isOn: Binding(
                        get: { !manager.heartbeatEnabled },
                        set: { isPaused in
                            Task {
                                await toggleHeartbeat(isPaused: isPaused)
                            }
                        }
                    )
                ) {
                    Text("Pause scheduled runs")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .disabled(disableControls || isHeartbeatBusy)

                Spacer()

                if isHeartbeatBusy {
                    ProgressView().scaleEffect(0.65)
                }
            }

            Text("Last heartbeat: \(heartbeatTimeTextFallback)")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(10)
        .background(theme.tertiaryBackground.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
    }

    private var heartbeatLastTimestampText: String? {
        guard let timestamp = manager.heartbeatLastTimestamp else {
            return nil
        }
        return OpenClawGatewayStatusCard.heartbeatFormatter.string(from: timestamp)
    }

    private var heartbeatTimeTextFallback: String {
        heartbeatLastTimestampText ?? "No heartbeat yet"
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusText: String {
        switch manager.gatewayStatus {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return manager.isConnected ? "Connected" : "Running"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch manager.gatewayStatus {
        case .stopped:
            return theme.tertiaryText
        case .starting:
            return theme.warningColor
        case .running:
            return manager.isConnected ? theme.successColor : theme.accentColor
        case .failed:
            return theme.errorColor
        }
    }

    private var errorMessage: String? {
        if case let .failed(message) = manager.gatewayStatus {
            return message
        }
        if case let .connectionFailed(message) = manager.phase {
            return message
        }
        if case let .gatewayFailed(message) = manager.phase {
            return message
        }
        return manager.lastError
    }

    private var disableControls: Bool {
        isBusy || {
            switch manager.phase {
            case .startingGateway, .connecting, .checkingEnvironment, .installingCLI:
                return true
            default:
                return false
            }
        }()
    }

    private func performStart() async {
        isBusy = true
        defer { isBusy = false }
        try? await manager.startGateway()
    }

    private func performStop() async {
        isBusy = true
        defer { isBusy = false }
        await manager.stopGateway()
    }

    private func performConnect() async {
        isBusy = true
        defer { isBusy = false }
        try? await manager.connect()
    }

    private func toggleHeartbeat(isPaused: Bool) async {
        isHeartbeatBusy = true
        defer { isHeartbeatBusy = false }
        do {
            try await manager.setHeartbeat(enabled: !isPaused)
        } catch {
            // Last error is surfaced on the card in the error panel.
        }
    }

    private static let heartbeatFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

}
