//
//  ToolCallSummaryCard.swift
//  osaurus
//
//  A collapsible summary card for grouped tool calls.
//  Collapsed: shows summary label, status icon, chevron.
//  Expanded: shows summary header + list of ToolCallRowView items.
//

import SwiftUI

// MARK: - ToolCallSummaryLogic (testable)

enum ToolCallSummaryLogic {
    /// Returns "Used N tools" when all complete, or "Running N tools..." when in-progress.
    static func summaryLabel(totalCount: Int, inProgressCount: Int) -> String {
        if inProgressCount > 0 {
            let noun = inProgressCount == 1 ? "tool" : "tools"
            return "Running \(inProgressCount) \(noun)..."
        }
        let noun = totalCount == 1 ? "tool" : "tools"
        return "Used \(totalCount) \(noun)"
    }

    /// Returns the SF Symbol name for the status icon, or nil if in-progress.
    static func statusIcon(isComplete: Bool, isRejected: Bool) -> String? {
        guard isComplete else { return nil }
        return isRejected ? "xmark" : "checkmark"
    }

    /// Returns true if any call has a nil result (still running).
    static func hasActiveTools(calls: [ToolCallItem]) -> Bool {
        calls.contains { $0.result == nil }
    }
}

// MARK: - ToolCallSummaryCard

struct ToolCallSummaryCard: View {
    let calls: [ToolCallItem]

    @State private var isExpanded = false
    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    // MARK: - Computed Properties

    private var hasActive: Bool {
        ToolCallSummaryLogic.hasActiveTools(calls: calls)
    }

    private var hasRejected: Bool {
        calls.contains { $0.result?.hasPrefix("[REJECTED]") == true }
    }

    private var inProgressCount: Int {
        calls.filter { $0.result == nil }.count
    }

    private var summaryLabel: String {
        ToolCallSummaryLogic.summaryLabel(totalCount: calls.count, inProgressCount: inProgressCount)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header (always visible, clickable)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                summaryHeader
            }
            .buttonStyle(.plain)

            // Expanded rows
            if isExpanded {
                expandedRows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    theme.primaryBorder.opacity(0.2),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shimmerEffect(isActive: hasActive, accentColor: theme.accentColor)
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            // Status icon or pulsing dot
            if hasActive {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: hasRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(hasRejected ? theme.errorColor : theme.successColor)
            }

            Text(summaryLabel)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Rows

    private var expandedRows: some View {
        VStack(spacing: 0) {
            Divider()
                .background(theme.primaryBorder.opacity(0.15))

            ForEach(Array(calls.enumerated()), id: \.element.call.id) { index, item in
                ToolCallRowView(call: item.call, result: item.result)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                if index < calls.count - 1 {
                    Divider()
                        .background(theme.primaryBorder.opacity(0.1))
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ToolCallSummaryCard_Previews: PreviewProvider {
        static var previews: some View {
            let calls: [ToolCallItem] = [
                ToolCallItem(
                    call: ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(
                            name: "read_file",
                            arguments: "{\"path\": \"/src/main.swift\"}"
                        )
                    ),
                    result: "import Foundation\n\nfunc main() {\n    print(\"Hello!\")\n}"
                ),
                ToolCallItem(
                    call: ToolCall(
                        id: "call_2",
                        type: "function",
                        function: ToolCallFunction(
                            name: "search_web",
                            arguments: "{\"query\": \"Swift best practices\"}"
                        )
                    ),
                    result: nil
                ),
                ToolCallItem(
                    call: ToolCall(
                        id: "call_3",
                        type: "function",
                        function: ToolCallFunction(
                            name: "run_command",
                            arguments: "{\"command\": \"swift build\"}"
                        )
                    ),
                    result: "[REJECTED] Permission denied"
                ),
            ]

            VStack(spacing: 20) {
                Text("In Progress")
                    .font(.headline)
                    .foregroundColor(.white)

                ToolCallSummaryCard(calls: calls)

                Text("All Complete")
                    .font(.headline)
                    .foregroundColor(.white)

                ToolCallSummaryCard(calls: [
                    ToolCallItem(
                        call: ToolCall(
                            id: "call_4",
                            type: "function",
                            function: ToolCallFunction(
                                name: "list_files",
                                arguments: "{\"path\": \"/src\"}"
                            )
                        ),
                        result: "main.swift\nutils.swift"
                    ),
                ])
            }
            .padding()
            .frame(width: 500, height: 500)
            .background(Color(hex: "0c0c0b"))
            .environmentObject(ExpandedBlocksStore())
        }
    }
#endif
