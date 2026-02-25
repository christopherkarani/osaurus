//
//  ThinkingTraceView.swift
//  osaurus
//
//  Displays model thinking/reasoning traces with auto-collapse behavior.
//  While streaming, shows inline muted italic text. Once finished, collapses
//  to a minimal pill ("Thought for Xs") that can be expanded on click.
//

import SwiftUI

// MARK: - ThinkingTraceLogic

/// Pure logic for thinking trace formatting and state, testable without SwiftUI.
enum ThinkingTraceLogic {

    /// Format a duration into a human-readable string.
    /// Returns "1.5s" for durations under 60 seconds, "2m 5s" for longer.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            // Format with one decimal place, stripping trailing zero if whole number
            let formatted = String(format: "%.1f", seconds)
            return "\(formatted)s"
        } else {
            let minutes = Int(seconds) / 60
            let remainingSeconds = Int(seconds) % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    /// Label shown on the collapsed pill.
    /// Shows "Thought for Xs" when duration is known, "Thinking..." otherwise.
    static func collapsedLabel(duration: TimeInterval?) -> String {
        if let duration {
            return "Thought for \(formatDuration(duration))"
        } else {
            return "Thinking..."
        }
    }

    /// Whether the view should auto-collapse.
    /// Never collapses while streaming; collapses when done with a known duration.
    static func shouldAutoCollapse(isStreaming: Bool, duration: TimeInterval?) -> Bool {
        guard !isStreaming else { return false }
        return duration != nil
    }
}

// MARK: - ThinkingTraceView

/// Renders a model thinking/reasoning trace block.
///
/// - While streaming: displays inline muted italic text (the thinking content).
/// - When done (not streaming): auto-collapses to a small pill ("Thought for Xs").
/// - The pill is clickable to expand/collapse via `ExpandedBlocksStore`.
/// - When expanded: shows full thinking text in a capped `ScrollView`.
struct ThinkingTraceView: View {

    let thinking: String
    let baseWidth: CGFloat
    let isStreaming: Bool
    let duration: TimeInterval?
    let blockId: String

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    private var isExpanded: Bool {
        expandedStore.isExpanded(blockId)
    }

    var body: some View {
        if isStreaming {
            streamingView
        } else {
            collapsedView
        }
    }

    // MARK: - Streaming View

    /// Inline muted italic text shown while the model is still thinking.
    private var streamingView: some View {
        Text(thinking)
            .font(.system(size: 13))
            .italic()
            .foregroundColor(theme.tertiaryText)
            .lineLimit(4)
            .frame(maxWidth: baseWidth, alignment: .leading)
    }

    // MARK: - Collapsed / Expandable View

    /// Collapsed pill with optional expansion to full thinking text.
    private var collapsedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            pillButton
            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
    }

    /// The clickable capsule pill showing "Thought for Xs" and a chevron.
    private var pillButton: some View {
        Button {
            expandedStore.toggle(blockId)
        } label: {
            HStack(spacing: 6) {
                Text(ThinkingTraceLogic.collapsedLabel(duration: duration))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
    }

    /// Full thinking text in a height-capped scroll view.
    private var expandedContent: some View {
        ScrollView {
            Text(thinking)
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
                .frame(maxWidth: baseWidth, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 300)
    }
}
