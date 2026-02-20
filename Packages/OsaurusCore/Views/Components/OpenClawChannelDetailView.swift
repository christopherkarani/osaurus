//
//  OpenClawChannelDetailView.swift
//  osaurus
//

import SwiftUI

struct OpenClawChannelDetailView: View {
    @Environment(\.theme) private var theme

    let channelId: String
    let channelName: String
    let channelDetailLabel: String?
    let channelSystemImage: String
    let accounts: [ChannelAccountSnapshot]
    let defaultAccountId: String?
    let onLinkAccount: () -> Void
    let onDisconnect: (_ accountId: String?) -> Void
    let onConfigure: () -> Void

    private var statusText: String {
        if accounts.contains(where: { $0.connected || $0.running }) {
            return "Connected"
        }
        if accounts.contains(where: { $0.linked || $0.configured }) {
            return "Disconnected"
        }
        return "Linking"
    }

    private var statusColor: Color {
        switch statusText {
        case "Connected":
            return theme.successColor
        case "Disconnected":
            return theme.warningColor
        default:
            return theme.tertiaryText
        }
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(statusColor.opacity(0.12))
                        Image(systemName: channelSystemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(channelName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        if let channelDetailLabel, !channelDetailLabel.isEmpty {
                            Text(channelDetailLabel)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        Text(channelId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor.opacity(0.12)))
                }

                if accounts.isEmpty {
                    Text("No linked accounts")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    VStack(spacing: 8) {
                        ForEach(accounts) { account in
                            accountRow(account)
                        }
                    }
                }

                HStack(spacing: 8) {
                    HeaderPrimaryButton("Link Account", icon: "link.badge.plus") {
                        onLinkAccount()
                    }
                    HeaderSecondaryButton("Disconnect", icon: "bolt.slash") {
                        onDisconnect(defaultAccountId ?? accounts.first?.accountId)
                    }
                    .disabled(accounts.isEmpty)
                    HeaderSecondaryButton("Configure", icon: "slider.horizontal.3") {
                        onConfigure()
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(channelName) details")
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ChannelAccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accountStatusColor(account))
                    .frame(width: 7, height: 7)

                Text(account.name?.isEmpty == false ? account.name! : account.accountId)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                if let dmPolicy = normalized(account.dmPolicy) {
                    Text(dmPolicy.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }
            }

            HStack(spacing: 8) {
                Text(lastInboundText(account))
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                if let lastError = normalized(account.lastError) {
                    Text(lastError)
                        .font(.system(size: 10))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
    }

    private func accountStatusColor(_ account: ChannelAccountSnapshot) -> Color {
        if account.connected || account.running {
            return theme.successColor
        }
        if account.linked || account.configured {
            return theme.warningColor
        }
        return theme.tertiaryText
    }

    private func lastInboundText(_ account: ChannelAccountSnapshot) -> String {
        guard let date = account.lastInboundAt else {
            return "Last inbound: never"
        }
        return "Last inbound: \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
