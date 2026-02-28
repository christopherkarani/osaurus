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

/// Renders a model thinking/reasoning trace as a flat action row.
///
/// Matches the Perplexity Computer visual language: bare SF Symbol icon,
/// medium-weight label, chevron toggle, and an expandable thread-line
/// section for the full thinking text.
///
/// - While streaming: animated brain icon, "Thinking..." label, no chevron.
/// - When done: static icon, "Thought for Ns" label, chevron to expand.
/// - Expanded: italic thinking text with a vertical thread line.
struct ThinkingTraceView: View {

    let thinking: String
    let baseWidth: CGFloat
    let isStreaming: Bool
    let duration: TimeInterval?
    let blockId: String

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore
    @State private var isHovered = false
    @State private var thinkingPulseOpacity: Double = 0.6

    private var isExpanded: Bool {
        expandedStore.isExpanded(blockId)
    }

    private var collapsedLabel: String {
        ThinkingTraceLogic.collapsedLabel(duration: duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowHeader
                .background(isHovered ? theme.primaryText.opacity(0.04) : Color.clear)
                .animation(.easeInOut(duration: 0.15), value: isHovered)

            if isExpanded && !thinking.isEmpty {
                expandedThinking
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        .onHover { hovering in
            isHovered = hovering
            if !isStreaming {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .onAppear {
            if isStreaming {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    thinkingPulseOpacity = 1.0
                }
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                thinkingPulseOpacity = 0.6
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    thinkingPulseOpacity = 1.0
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    thinkingPulseOpacity = 1.0
                }
            }
        }
    }

    // MARK: - Row Header

    private var rowHeader: some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 10) {
                // Bare icon — no container background
                if isStreaming {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 20))
                        .foregroundColor(theme.tertiaryText)
                        .symbolEffect(.variableColor.iterative, isActive: isStreaming)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 20))
                        .foregroundColor(theme.tertiaryText)
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .frame(width: 24, height: 24)
                }

                Text(collapsedLabel)
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .monospacedDigit()
                    .opacity(isStreaming ? thinkingPulseOpacity : 1.0)

                Spacer()

                if !isStreaming {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
    }

    // MARK: - Expanded Thinking

    private var expandedThinking: some View {
        HStack(alignment: .top, spacing: 0) {
            // Vertical thread line aligned with icon center
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.leading, 13)
                .scaleEffect(y: isExpanded ? 1 : 0, anchor: .top)

            ScrollView {
                Text(thinking)
                    .font(theme.font(size: 13, weight: .regular))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .textShimmer(isActive: isStreaming, accentColor: theme.accentColor, period: 2.5)
                    .padding(10)
            }
            .frame(maxHeight: 300)
            .padding(.leading, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Actions

    private func toggleExpansion() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            expandedStore.toggle(blockId)
        }
    }
}
