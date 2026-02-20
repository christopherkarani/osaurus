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
        OpenClawConnectedClientsViewLogic.sortedClients(manager.connectedClients)
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
            .accessibilityLabel("Refresh connected clients")
        }
    }

    @ViewBuilder
    private func clientRow(_ client: OpenClawPresenceEntry) -> some View {
        let connectedText = Self.relativeDateFormatter.localizedString(for: client.connectedAt, relativeTo: Date())

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(client.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(connectedText)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            HStack(spacing: 8) {
                if let deviceId = normalized(client.deviceId) {
                    Text(deviceId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
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

            if !client.scopes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(client.scopes, id: \.self) { scope in
                        Text(scope)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.secondaryBackground))
                    }
                    Spacer()
                }
            }

            if !client.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(client.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            OpenClawConnectedClientsViewLogic.accessibilityLabel(for: client, connectedText: connectedText)
        )
        .accessibilityValue(OpenClawConnectedClientsViewLogic.accessibilityValue(for: client))
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

enum OpenClawConnectedClientsViewLogic {
    static func sortedClients(_ entries: [OpenClawPresenceEntry]) -> [OpenClawPresenceEntry] {
        entries.sorted { lhs, rhs in
            if lhs.timestampMs != rhs.timestampMs {
                return lhs.timestampMs > rhs.timestampMs
            }
            return lhs.primaryIdentity.localizedCaseInsensitiveCompare(rhs.primaryIdentity) == .orderedAscending
        }
    }

    static func accessibilityLabel(for client: OpenClawPresenceEntry, connectedText: String) -> String {
        let mode = normalized(client.mode)?.lowercased() ?? "unknown"
        return "\(client.displayName), identity \(client.primaryIdentity), status \(mode), connected \(connectedText)"
    }

    static func accessibilityValue(for client: OpenClawPresenceEntry) -> String {
        let roles = joinedOrNone(client.roles)
        let scopes = joinedOrNone(client.scopes)
        let tags = joinedOrNone(client.tags)
        return "Roles: \(roles). Scopes: \(scopes). Tags: \(tags)."
    }

    private static func joinedOrNone(_ values: [String]) -> String {
        let normalizedValues = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalizedValues.isEmpty ? "none" : normalizedValues.joined(separator: ", ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
