//
//  OpenClawConnectedClientsView.swift
//  osaurus
//

import SwiftUI

struct OpenClawConnectedClientsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var hasLoaded = false

    private var clients: [OpenClawPresenceEntry] {
        manager.connectedClients.sorted { $0.timestampMs > $1.timestampMs }
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                if clients.isEmpty {
                    Text("No connected clients reported.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    ForEach(clients) { client in
                        clientRow(client)
                    }
                }
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            Task { await manager.refreshConnectedClients() }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Connected Clients")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                Task { await manager.refreshConnectedClients() }
            }
        }
    }

    @ViewBuilder
    private func clientRow(_ client: OpenClawPresenceEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(client.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(Self.relativeDateFormatter.localizedString(for: client.connectedAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            HStack(spacing: 8) {
                if let platform = normalized(client.platform) {
                    Text(platform)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                if let version = normalized(client.version) {
                    Text("v\(version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                if let mode = normalized(client.mode) {
                    Text(mode.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
                Spacer()
            }

            if !client.roles.isEmpty {
                HStack(spacing: 6) {
                    ForEach(client.roles, id: \.self) { role in
                        Text(role)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
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
