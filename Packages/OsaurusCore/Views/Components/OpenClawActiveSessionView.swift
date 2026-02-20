//
//  OpenClawActiveSessionView.swift
//  osaurus
//

import SwiftUI

struct OpenClawActiveSessionView: View {
    @Environment(\.theme) private var theme

    @ObservedObject var manager: OpenClawManager
    let session: OpenClawManager.ActiveSessionInfo
    @State private var hasAppeared = false
    @State private var isHovered = false

    @State private var isStopping = false
    @State private var stopErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let model = session.model, !model.isEmpty {
                            Text(model)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                        Text(statusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(statusColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(statusColor.opacity(0.12)))
                    }
                }

                Spacer(minLength: 8)

                Button {
                    Task { await emergencyStop() }
                } label: {
                    Label("Emergency Stop", systemImage: "stop.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isStopping)
                .help("Immediately block scheduled sends for this session")
                .accessibilityLabel("Emergency stop for \(session.title)")
            }

            if let usageText = usageText {
                Text(usageText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            if let stopErrorMessage, !stopErrorMessage.isEmpty {
                Text(stopErrorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }
        }
        .padding(12)
        .scaleEffect(isHovered ? 1.02 : 1)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .onHover { isHovered = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .thinking:
            return theme.warningColor
        case .usingTool:
            return theme.accentColor
        case .responding:
            return theme.successColor
        }
    }

    private var statusText: String {
        switch session.status {
        case .thinking:
            return "Thinking..."
        case .usingTool(let tool):
            return "Using tool: \(tool)"
        case .responding:
            return "Responding..."
        }
    }

    private var usageText: String? {
        guard let usage = session.usage else { return nil }
        var fields: [String] = []
        if let input = usage.inputTokens {
            fields.append("in \(input)")
        }
        if let output = usage.outputTokens {
            fields.append("out \(output)")
        }
        if let total = usage.totalTokens {
            fields.append("total \(total)")
        }
        guard !fields.isEmpty else { return nil }
        return "Tokens: " + fields.joined(separator: " · ")
    }

    private func emergencyStop() async {
        isStopping = true
        defer { isStopping = false }
        do {
            try await manager.emergencyStopSession(key: session.key)
            stopErrorMessage = nil
        } catch {
            stopErrorMessage = error.localizedDescription
        }
    }
}
