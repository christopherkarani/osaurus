//
//  ToolCallRowView.swift
//  osaurus
//
//  A simplified, monochrome tool call row.
//  Shows status indicator, tool name (monospace), arg preview, and chevron.
//  Expandable to reveal full arguments and result via CollapsibleCodeSection.
//

import AppKit
import SwiftUI

// MARK: - ToolCallRowView

struct ToolCallRowView: View {
    let call: ToolCall
    let result: String?

    @State private var isHovered = false
    @State private var formattedArgs: String?
    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    // MARK: - Computed Properties

    private var isExpanded: Bool {
        expandedStore.isExpanded("row-\(call.id)")
    }

    private var isComplete: Bool {
        result != nil
    }

    private var isRejected: Bool {
        result?.hasPrefix("[REJECTED]") == true
    }

    /// Extract a key argument preview from JSON arguments.
    private var argPreview: String? {
        guard let data = call.function.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else { return nil }

        let priorityKeys = ["path", "file", "file_path", "query", "url", "name", "command", "pattern"]
        for key in priorityKeys {
            if let value = json[key] as? String {
                let clean = value.count > 40 ? String(value.prefix(37)) + "..." : value
                return "\(key): \(clean)"
            }
        }
        if let firstKey = json.keys.sorted().first, let value = json[firstKey] {
            return "\(firstKey): \(String(describing: value).prefix(40))"
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header row
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expandedStore.toggle("row-\(call.id)")
                }
                // Lazily format arguments on first expand
                if expandedStore.isExpanded("row-\(call.id)"), formattedArgs == nil {
                    let rawArgs = call.function.arguments
                    Task.detached(priority: .userInitiated) {
                        let formatted = ToolCallRowJSONFormatter.prettyJSON(rawArgs)
                        await MainActor.run { formattedArgs = formatted }
                    }
                }
            }) {
                HStack(spacing: 8) {
                    // Status indicator
                    statusIndicator

                    // Tool name (monospace)
                    Text(call.function.name)
                        .font(theme.monoFont(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    // Arg preview
                    if let preview = argPreview {
                        Text(preview)
                            .font(theme.font(size: 10, weight: .regular))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText.opacity(isHovered ? 1.0 : 0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                expandedContent
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.accentColor.opacity(isHovered ? 0.04 : 0))
                .animation(.easeOut(duration: 0.2), value: isHovered)
        )
        .shimmerEffect(isActive: !isComplete, accentColor: theme.accentColor)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .id(call.id)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        if !isComplete {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 6, height: 6)
        } else {
            Image(systemName: isRejected ? "xmark" : "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isRejected ? theme.errorColor : theme.successColor)
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Arguments - hide if empty or "{}"
            let currentArgs = formattedArgs ?? call.function.arguments
            let isArgsEmpty =
                currentArgs.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
                || currentArgs.isEmpty

            if !isArgsEmpty {
                CollapsibleCodeSection(
                    title: "Arguments",
                    text: currentArgs,
                    language: "json",
                    previewText: argPreview,
                    sectionId: "row-\(call.id)-args"
                )
            }

            // Result (if complete)
            if let result {
                CollapsibleCodeSection(
                    title: "Result",
                    text: result,
                    language: nil,
                    previewText: ToolCallRowResultPreview.preview(result, maxLength: 80),
                    sectionId: "row-\(call.id)-result"
                )
            }
        }
    }
}

// MARK: - JSON Formatting Utility

/// Formats JSON on a background thread to avoid blocking UI.
/// Separate from InlineToolCallView's private JSONFormatter to avoid coupling.
enum ToolCallRowJSONFormatter {
    static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return raw }

        if let dict = obj as? [String: Any], dict.isEmpty {
            return "{}"
        }

        guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return raw }
        return String(data: pretty, encoding: .utf8) ?? raw
    }
}

// MARK: - Result Preview Utility

/// Generates a short preview string for tool call results.
enum ToolCallRowResultPreview {
    static func preview(_ text: String, maxLength: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try JSON first
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data)
        {
            if let array = json as? [Any] {
                if array.isEmpty { return "Empty array []" }
                let items = array.prefix(3).map { formatValue($0) }
                let preview = items.joined(separator: ", ")
                let suffix = array.count > 3 ? " +\(array.count - 3) more" : ""
                let result = "[\(array.count) items] \(preview)\(suffix)"
                return result.count > maxLength ? String(result.prefix(maxLength - 3)) + "..." : result
            }
            if let dict = json as? [String: Any] {
                if dict.isEmpty { return "Empty object {}" }
                return "{\(dict.count) keys}"
            }
        }

        // Plain text
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let firstLine = lines.first else {
            return trimmed.isEmpty ? "Empty response" : trimmed
        }

        if firstLine.count <= maxLength {
            if lines.count > 1 {
                return "\(firstLine) (+\(lines.count - 1) lines)"
            }
            return firstLine
        }

        return String(firstLine.prefix(maxLength - 3)) + "..."
    }

    private static func formatValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return clean.count > 30 ? String(clean.prefix(27)) + "..." : clean
        case let num as NSNumber:
            return num.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let arr as [Any]:
            return "[\(arr.count) items]"
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}
