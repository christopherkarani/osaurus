//
//  ToolCallSummaryCard.swift
//  osaurus
//
//  A collapsible summary card for grouped tool calls.
//  Collapsed: shows summary label, status icon, chevron.
//  Expanded: shows summary header + list of ToolCallRowView items.
//

import AppKit
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

    // MARK: - Icon mapping

    static func toolIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("cat") || n.contains("view") { return "doc.text" }
        if n.contains("write") || n.contains("create") { return "doc.badge.plus" }
        if n.contains("edit") || n.contains("patch") || n.contains("str_replace") { return "pencil.line" }
        if n.contains("bash") || n.contains("run") || n.contains("exec") || n.contains("command") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("find") { return "magnifyingglass" }
        if n.contains("list") || n.contains("ls") || n.contains("glob") { return "list.bullet" }
        if n.contains("delete") || n.contains("rm") || n.contains("remove") { return "trash" }
        if n.contains("move") || n.contains("rename") || n.contains("copy") { return "doc.on.doc" }
        if n.contains("web") || n.contains("fetch") || n.contains("url") || n.contains("http") { return "globe" }
        return "wrench.and.screwdriver"
    }

    // MARK: - Human title

    /// Priority argument keys to use as the title subject.
    private static let priorityArgKeys = ["path", "file", "file_path", "query", "url", "command", "pattern", "name"]

    static func humanTitle(call: ToolCall) -> String {
        let prefix = actionPrefix(for: call.function.name)
        guard let data = call.function.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            return prefix
        }
        for key in priorityArgKeys {
            if let value = json[key] as? String, !value.isEmpty {
                let truncated = value.count > 60 ? String(value.prefix(57)) + "..." : value
                return "\(prefix) \(truncated)"
            }
        }
        return prefix
    }

    private static func actionPrefix(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("cat") || n.contains("view") { return "Reading" }
        if n.contains("write") || n.contains("create") { return "Writing" }
        if n.contains("edit") || n.contains("patch") || n.contains("str_replace") { return "Editing" }
        if n.contains("bash") || n.contains("run") || n.contains("exec") || n.contains("command") || n.contains("terminal") { return "Running" }
        if n.contains("search") || n.contains("grep") || n.contains("find") { return "Searching" }
        if n.contains("list") || n.contains("ls") || n.contains("glob") { return "Listing" }
        if n.contains("delete") || n.contains("rm") || n.contains("remove") { return "Deleting" }
        if n.contains("move") || n.contains("rename") { return "Moving" }
        if n.contains("copy") { return "Copying" }
        if n.contains("web") || n.contains("fetch") || n.contains("url") || n.contains("http") { return "Fetching" }
        return "Using"
    }

    // MARK: - Content kind

    enum ToolContentKind {
        case file(path: String, content: String?)
        case terminal(command: String, output: String?)
        case search(query: String, results: [SearchResultChip])
        case generic(text: String)
    }

    struct SearchResultChip: Equatable {
        let title: String
        let domain: String
    }

    static func contentKind(call: ToolCall, result: String?) -> ToolContentKind {
        let n = call.function.name.lowercased()
        let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]

        // Terminal
        if n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("command") || n.contains("terminal") {
            let command = args["command"] as? String ?? args["cmd"] as? String ?? call.function.name
            return .terminal(command: command, output: result)
        }

        // Search / web
        if n.contains("search") || n.contains("web") || n.contains("grep") {
            let query = args["query"] as? String ?? args["pattern"] as? String ?? ""
            let chips = parseSearchChips(from: result)
            return .search(query: query, results: chips)
        }

        // File operations
        let filePath = args["path"] as? String ?? args["file"] as? String ?? args["file_path"] as? String
        if filePath != nil || n.contains("read") || n.contains("write") || n.contains("edit") || n.contains("create") || n.contains("list") {
            return .file(path: filePath ?? "", content: result)
        }

        return .generic(text: result ?? "")
    }

    private static func parseSearchChips(from result: String?) -> [SearchResultChip] {
        guard let result else { return [] }
        var chips: [SearchResultChip] = []
        for line in result.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed), let host = url.host {
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                chips.append(SearchResultChip(title: trimmed, domain: domain))
            }
        }
        return Array(chips.prefix(6))
    }
}

// MARK: - ToolCallSummaryCard

struct ToolCallSummaryCard: View {
    let calls: [ToolCallItem]
    let blockId: String
    var onRedirect: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    var body: some View {
        if calls.count == 1, let item = calls.first {
            // Single call: bare ToolActionRow, no wrapper
            ToolActionRow(
                call: item.call,
                result: item.result,
                blockId: blockId,
                isGroupActive: item.result == nil,
                onRedirect: onRedirect
            )
        } else {
            // Multiple calls: parallel group header + children
            ParallelGroupRow(calls: calls, blockId: blockId, onRedirect: onRedirect)
        }
    }
}

// MARK: - ParallelGroupRow

private struct ParallelGroupRow: View {
    let calls: [ToolCallItem]
    let blockId: String
    var onRedirect: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore
    @State private var isHovered = false

    private var expansionKey: String { "tool-group-summary-\(blockId)" }
    private var isExpanded: Bool { expandedStore.isExpanded(expansionKey) }
    private var hasActive: Bool { ToolCallSummaryLogic.hasActiveTools(calls: calls) }

    private var summaryTitle: String {
        ToolCallSummaryLogic.summaryLabel(
            totalCount: calls.count,
            inProgressCount: calls.filter { $0.result == nil }.count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader
                .background(isHovered ? theme.primaryText.opacity(0.04) : Color.clear)
                .animation(.easeInOut(duration: 0.15), value: isHovered)

            if isExpanded {
                childRows
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var groupHeader: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                expandedStore.toggle(expansionKey)
            }
        }) {
            HStack(spacing: 10) {
                // Bare icon — NO container background
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 20))
                    .foregroundColor(theme.tertiaryText)
                    .symbolEffect(.variableColor.iterative, isActive: hasActive)
                    .frame(width: 24, height: 24)

                Text(summaryTitle)
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                // Chevron up/down
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var childRows: some View {
        HStack(alignment: .top, spacing: 0) {
            // Thread line spanning all children
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.leading, 13)
                .scaleEffect(y: isExpanded ? 1 : 0, anchor: .top)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(calls, id: \.call.id) { item in
                    ToolActionRow(
                        call: item.call,
                        result: item.result,
                        blockId: "\(blockId)-\(item.call.id)",
                        isGroupActive: hasActive,
                        onRedirect: onRedirect
                    )
                }
            }
            .padding(.leading, 12)
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
                    result: "import Foundation\nfunc main() {\n    print(\"Hello!\")\n}"
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
                Text("Single Call")
                    .font(.headline)
                    .foregroundColor(.white)

                ToolCallSummaryCard(calls: [calls[0]], blockId: "preview-single")

                Text("Parallel Group")
                    .font(.headline)
                    .foregroundColor(.white)

                ToolCallSummaryCard(calls: calls, blockId: "preview-group")
            }
            .padding()
            .frame(width: 500, height: 500)
            .background(Color(hex: "0c0c0b"))
            .environmentObject(ExpandedBlocksStore())
        }
    }
#endif
