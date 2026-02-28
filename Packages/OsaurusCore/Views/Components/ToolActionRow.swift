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
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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

    // MARK: - Expanded Content (STUB -- filled in Task 4)

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

            // Placeholder content -- replaced in Task 4
            Text(result ?? "")
                .font(theme.font(size: 13, weight: .regular))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 12)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Actions

    private func toggleExpansion() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            expandedStore.toggle(expansionKey)
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
