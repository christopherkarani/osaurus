//
//  ToolActionRow.swift
//  osaurus
//
//  A flat, minimal tool action row in the Perplexity Computer style.
//  Used by ToolCallSummaryCard (.toolCallGroup) and ActivityGroupView (.activityGroup).
//

import AppKit
import SwiftUI

// MARK: - ToolActionRow

struct ToolActionRow: View {
    let call: ToolCall
    let result: String?
    let blockId: String
    var isGroupActive: Bool = false
    var onRedirect: ((String) -> Void)? = nil

    @State private var isHovered = false
    @State private var showRedirectField = false
    @State private var redirectText = ""
    @State private var settleScale: CGFloat = 1.0

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    // MARK: - Computed

    private var expansionKey: String { "tool-row-\(call.id)-\(blockId)" }
    private var isExpanded: Bool { expandedStore.isExpanded(expansionKey) }
    private var isRunning: Bool { result == nil }
    private var isRejected: Bool { result?.hasPrefix("[REJECTED]") == true }
    private var iconName: String { ToolCallSummaryLogic.toolIcon(for: call.function.name) }
    private var title: String { ToolCallSummaryLogic.humanTitle(call: call) }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowHeader
                .background(isHovered ? theme.primaryText.opacity(0.04) : Color.clear)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .shimmerEffect(isActive: isRunning, accentColor: theme.accentColor.opacity(0.5), period: 2.5)

            if isExpanded {
                expandedContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            if showRedirectField {
                redirectInput
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: showRedirectField)
        .scaleEffect(settleScale)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onChange(of: result) { oldValue, newValue in
            if oldValue == nil && newValue != nil {
                settleScale = 1.01
                withAnimation(.easeOut(duration: 0.2)) {
                    settleScale = 1.0
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(isRunning ? "Running" : "Complete")
        .accessibilityHint(isRunning ? "" : "Double-click to expand")
    }

    // MARK: - Row Header

    private var rowHeader: some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 10) {
                // BARE icon -- NO container background (Perplexity style)
                statusIcon

                Text(title)
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText) // muted gray, NOT primaryText
                    .lineLimit(1)

                Spacer()

                // Metadata -- visible while running, hover-only when done
                if isRunning || isHovered {
                    metaLabel
                }

                // Chevron -- up/down, NOT rotating right
                if !isRunning {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .contentTransition(.symbolEffect(.replace))
                }

                // Redirect affordance
                if isGroupActive && isRunning && isHovered, onRedirect != nil {
                    redirectButton
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
    }

    // MARK: - Status Icon (bare, no container)

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundColor(theme.tertiaryText)
                .symbolEffect(.variableColor.iterative, isActive: isRunning)
                .frame(width: 24, height: 24)
        } else if isRejected {
            Image(systemName: "xmark.circle")
                .font(.system(size: 20))
                .foregroundColor(theme.errorColor)
                .symbolEffect(.bounce.down, value: isRejected)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundColor(theme.tertiaryText)
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - Meta Label

    private var metaLabel: some View {
        Text(call.function.name)
            .font(theme.font(size: 12, weight: .regular).monospacedDigit())
            .foregroundColor(theme.tertiaryText)
            .lineLimit(1)
    }

    // MARK: - Redirect Button

    private var redirectButton: some View {
        Button(action: { showRedirectField.toggle() }) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(5)
        }
        .buttonStyle(.plain)
        .help("Add context for the agent")
    }

    // MARK: - Redirect Input

    private var redirectInput: some View {
        HStack(spacing: 8) {
            TextField("Add context for the agent...", text: $redirectText)
                .textFieldStyle(.plain)
                .font(theme.font(size: 13, weight: .regular))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.secondaryBackground)
                )
                .onSubmit {
                    if !redirectText.trimmingCharacters(in: .whitespaces).isEmpty {
                        onRedirect?(redirectText)
                        redirectText = ""
                        showRedirectField = false
                    }
                }

            Button("Cancel") {
                redirectText = ""
                showRedirectField = false
            }
            .buttonStyle(.plain)
            .font(theme.font(size: 12, weight: .medium))
            .foregroundColor(theme.tertiaryText)
        }
        .padding(.leading, 38)
        .padding(.bottom, 8)
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // Thread line
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.leading, 13)
                .scaleEffect(y: isExpanded ? 1 : 0, anchor: .top)

            // Content
            expandedBody
                .padding(.leading, 12)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        switch ToolCallSummaryLogic.contentKind(call: call, result: result) {
        case let .file(path, content):
            FileExpandedContent(path: path, content: content)
        case let .terminal(command, output):
            TerminalExpandedContent(command: command, output: output)
        case let .search(query, results):
            SearchExpandedContent(query: query, results: results)
        case let .generic(text):
            if text.isEmpty {
                Text("No output")
                    .font(theme.font(size: 12, weight: .regular))
                    .foregroundColor(theme.tertiaryText)
            } else {
                Text(text)
                    .font(theme.font(size: 13, weight: .regular))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func toggleExpansion() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            expandedStore.toggle(expansionKey)
        }
    }
}

// MARK: - DiffParser

enum DiffLineKind { case added, removed, context, header }

struct DiffLine: Equatable {
    let kind: DiffLineKind
    let text: String
}

enum DiffParser {
    static func isDiff(_ text: String) -> Bool {
        text.hasPrefix("@@") || text.hasPrefix("---") || text.hasPrefix("+++")
    }

    static func parse(_ diff: String) -> [DiffLine] {
        diff.components(separatedBy: "\n").compactMap { line in
            if line.hasPrefix("@@") { return DiffLine(kind: .header, text: line) }
            if line.hasPrefix("+") { return DiffLine(kind: .added, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, text: String(line.dropFirst())) }
            if line.hasPrefix(" ") { return DiffLine(kind: .context, text: String(line.dropFirst())) }
            if line.isEmpty { return nil }
            return DiffLine(kind: .context, text: line)
        }
    }
}

// MARK: - FileExpandedContent

private struct FileExpandedContent: View {
    let path: String
    let content: String?

    @Environment(\.theme) private var theme
    @State private var showFull = false

    private var isDiff: Bool { DiffParser.isDiff(content ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)

            if let content, !content.isEmpty {
                if isDiff {
                    DiffView(diff: content)
                } else {
                    TerminalBlock(text: content, maxLines: showFull ? nil : 8) {
                        showFull = true
                    }
                }
            }
        }
    }
}

// MARK: - TerminalExpandedContent

private struct TerminalExpandedContent: View {
    let command: String
    let output: String?

    @Environment(\.theme) private var theme
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // "Running command:" sub-header label
            Text("Running command:")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            // Command text
            Text(command)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)

            if let output, !output.isEmpty {
                TerminalBlock(text: output, maxLines: showFull ? nil : 8) {
                    showFull = true
                }
            } else if output == nil {
                Text("Running...")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

// MARK: - SearchExpandedContent

private struct SearchExpandedContent: View {
    let query: String
    let results: [ToolCallSummaryLogic.SearchResultChip]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Text(query)
                    .font(theme.font(size: 13, weight: .regular))
                    .italic()
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, chip in
                        HStack(spacing: 5) {
                            Image(systemName: "globe")
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                            Text(chip.domain)
                                .font(theme.font(size: 12, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    if results.count > 6 {
                        Text("+\(results.count - 6) more")
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - TerminalBlock

struct TerminalBlock: View {
    let text: String
    let maxLines: Int?
    let onShowMore: (() -> Void)?

    @Environment(\.theme) private var theme

    private var lines: [String] { text.components(separatedBy: "\n") }
    private var displayLines: [String] {
        guard let max = maxLines else { return lines }
        return Array(lines.prefix(max))
    }
    private var hasMore: Bool {
        guard let max = maxLines else { return false }
        return lines.count > max
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color(red: 0.067, green: 0.071, blue: 0.078))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if hasMore, let onShowMore {
                Button("Show more") { onShowMore() }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - DiffView

private struct DiffView: View {
    let diff: String
    @Environment(\.theme) private var theme

    private var lines: [DiffLine] { DiffParser.parse(diff) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                diffLineView(line)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(gutterColor(line.kind))
                .frame(width: 16, alignment: .center)
                .padding(.vertical, 1)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(textColor(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
                .textSelection(.enabled)
        }
        .background(bgColor(line.kind))
        .padding(.horizontal, 4)
    }

    private func bgColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return Color(red: 0.18, green: 0.33, blue: 0.20).opacity(0.4)
        case .removed: return Color(red: 0.40, green: 0.12, blue: 0.12).opacity(0.4)
        case .header:  return theme.secondaryBackground.opacity(0.5)
        case .context: return Color.clear
        }
    }

    private func textColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return Color(red: 0.56, green: 0.93, blue: 0.56)
        case .removed: return Color(red: 0.95, green: 0.55, blue: 0.55)
        case .header:  return theme.tertiaryText
        case .context: return theme.secondaryText
        }
    }

    private func gutterColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return Color(red: 0.56, green: 0.93, blue: 0.56)
        case .removed: return Color(red: 0.95, green: 0.55, blue: 0.55)
        default:       return theme.tertiaryText
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ToolActionRow_Previews: PreviewProvider {
        static var previews: some View {
            let completedCall = ToolCall(
                id: "call_1",
                type: "function",
                function: ToolCallFunction(
                    name: "read_file",
                    arguments: "{\"path\": \"/src/main.swift\"}"
                )
            )
            let runningCall = ToolCall(
                id: "call_2",
                type: "function",
                function: ToolCallFunction(
                    name: "bash",
                    arguments: "{\"command\": \"swift build\"}"
                )
            )
            let rejectedCall = ToolCall(
                id: "call_3",
                type: "function",
                function: ToolCallFunction(
                    name: "run_command",
                    arguments: "{\"command\": \"rm -rf /\"}"
                )
            )

            VStack(spacing: 2) {
                ToolActionRow(
                    call: completedCall,
                    result: "import Foundation\n\nfunc main() { print(\"Hello\") }",
                    blockId: "preview-1"
                )
                ToolActionRow(
                    call: runningCall,
                    result: nil,
                    blockId: "preview-2",
                    isGroupActive: true
                )
                ToolActionRow(
                    call: rejectedCall,
                    result: "[REJECTED] Permission denied",
                    blockId: "preview-3"
                )
            }
            .padding()
            .frame(width: 500, height: 300)
            .background(Color(hex: "0c0c0b"))
            .environmentObject(ExpandedBlocksStore())
        }
    }
#endif
