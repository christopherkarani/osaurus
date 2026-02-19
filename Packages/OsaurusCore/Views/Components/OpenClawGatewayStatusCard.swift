//
//  OpenClawGatewayStatusCard.swift
//  osaurus
//

import SwiftUI

struct OpenClawGatewayStatusCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var isBusy = false

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
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if manager.gatewayStatus == .running {
                HeaderSecondaryButton("Stop", icon: "stop.fill") {
                    Task { await performStop() }
                }
                .disabled(disableControls)

                if manager.isConnected {
                    HeaderSecondaryButton("Disconnect", icon: "bolt.slash.fill") {
                        manager.disconnect()
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
}
