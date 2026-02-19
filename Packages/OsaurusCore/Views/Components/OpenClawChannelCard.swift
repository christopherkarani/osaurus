//
//  OpenClawChannelCard.swift
//  osaurus
//

import SwiftUI

struct OpenClawChannelCard: View {
    @Environment(\.theme) private var theme

    let channel: OpenClawManager.ChannelInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(statusColor.opacity(0.12))
                Image(systemName: channel.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(channel.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor.opacity(0.12)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(channel.name) channel")
        .accessibilityValue(
            channel.isConnected ? "Connected" : channel.isLinked ? "Linked but disconnected" : "Not linked"
        )
    }

    private var statusColor: Color {
        if channel.isConnected {
            return theme.successColor
        }
        if channel.isLinked {
            return theme.warningColor
        }
        return theme.tertiaryText
    }

    private var statusText: String {
        if channel.isConnected { return "Connected" }
        if channel.isLinked { return "Linked" }
        return "Not Linked"
    }
}
