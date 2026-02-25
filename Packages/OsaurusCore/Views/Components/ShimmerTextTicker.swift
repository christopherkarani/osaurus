//
//  ShimmerTextTicker.swift
//  osaurus
//
//  Animated text ticker that displays the latest work-trace line with a
//  left-to-right shimmer gradient sweep and toilet-paper-roll slide-up
//  transitions. Text never streams in character-by-character — only complete
//  lines are shown, and each new line rolls the old one upward.
//

import SwiftUI

// MARK: - Testable Logic

/// Pure logic extracted for unit testing — no SwiftUI dependency.
enum ShimmerTextTickerLogic {

    static let maxLineLength = 120
    static let fallbackText = "Working on it..."

    /// Returns the line that should be displayed.
    ///
    /// When `isStreaming` is true the last line is still being built character-
    /// by-character, so we show the **second-to-last** non-empty line (the last
    /// *complete* one). This prevents visible character-by-character text growth.
    /// When streaming ends we show the actual last line.
    static func displayLine(from text: String, isStreaming: Bool) -> String {
        let nonEmpty = nonEmptyLines(in: text)
        guard !nonEmpty.isEmpty else { return fallbackText }

        if isStreaming, nonEmpty.count >= 2 {
            return truncate(String(nonEmpty[nonEmpty.count - 2]))
        }
        return truncate(String(nonEmpty.last!))
    }

    /// Extracts the last non-empty line from `text`, truncated to `maxLineLength`.
    /// Used by tests and non-streaming paths.
    static func latestLine(from text: String) -> String {
        let nonEmpty = nonEmptyLines(in: text)
        guard let last = nonEmpty.last else { return fallbackText }
        return truncate(String(last))
    }

    /// Counts non-empty lines — the slide-up animation fires only when this changes.
    static func nonEmptyLineCount(in text: String) -> Int {
        nonEmptyLines(in: text).count
    }

    /// Walks activity items in reverse to find the latest streaming (or fallback
    /// non-streaming) thinking/assistant text.
    static func latestStreamingActivity(
        from items: [ActivityItem]
    ) -> (text: String, isStreaming: Bool) {
        // First pass: most recent streaming item
        for item in items.reversed() {
            switch item.kind {
            case .thinking(let t) where t.isStreaming:
                return (t.text, true)
            case .assistant(let a) where a.isStreaming:
                return (a.text, true)
            default:
                continue
            }
        }
        // Second pass: most recent thinking/assistant regardless of streaming state
        for item in items.reversed() {
            switch item.kind {
            case .thinking(let t):
                return (t.text, false)
            case .assistant(let a):
                return (a.text, false)
            default:
                continue
            }
        }
        return ("", false)
    }

    /// Minimum interval between slide-up transitions to prevent visual spazzing
    /// when many traces arrive in rapid succession.
    static let transitionCooldown: TimeInterval = 0.6

    // MARK: - Internals

    private static func nonEmptyLines(in text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Strips common markdown syntax so the ticker shows plain readable text.
    static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Headers: "## Foo" → "Foo"
        s = s.replacingOccurrences(
            of: #"^#{1,6}\s+"#, with: "", options: .regularExpression
        )
        // Bold/italic: **text**, __text__, *text*, _text_
        s = s.replacingOccurrences(
            of: #"(\*{1,3}|_{1,3})(.+?)\1"#, with: "$2", options: .regularExpression
        )
        // Inline code: `code`
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#, with: "$1", options: .regularExpression
        )
        // Links: [text](url) → text
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression
        )
        // Images: ![alt](url) → alt
        s = s.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression
        )
        // List markers: "- ", "* ", "1. "
        s = s.replacingOccurrences(
            of: #"^[\s]*[-*+]\s+"#, with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"^[\s]*\d+\.\s+"#, with: "", options: .regularExpression
        )
        // Blockquote: "> "
        s = s.replacingOccurrences(
            of: #"^>\s?"#, with: "", options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func truncate(_ line: String) -> String {
        let stripped = stripMarkdown(line.trimmingCharacters(in: .whitespaces))
        if stripped.count > maxLineLength {
            return String(stripped.prefix(maxLineLength)) + "..."
        }
        return stripped
    }
}

// MARK: - ShimmerTextTicker View

struct ShimmerTextTicker: View {
    let text: String
    let isStreaming: Bool

    @Environment(\.theme) private var theme
    @State private var shimmerOffset: CGFloat = -0.3
    @State private var lineId = UUID()
    @State private var displayedLine: String = ShimmerTextTickerLogic.fallbackText
    @State private var lastLineCount: Int = 0
    /// Timestamp of the last slide-up animation — used to enforce cooldown.
    @State private var lastTransitionTime: Date = .distantPast
    /// Buffered line waiting for cooldown to expire.
    @State private var pendingLine: String?
    @State private var cooldownTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 6, height: 6)
                .modifier(WorkPulseModifier())

            tickerText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear {
            let line = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: isStreaming)
            displayedLine = line
            lastLineCount = ShimmerTextTickerLogic.nonEmptyLineCount(in: text)
        }
        .onChange(of: text) { _, newText in
            let newCount = ShimmerTextTickerLogic.nonEmptyLineCount(in: newText)
            guard newCount != lastLineCount else { return }
            lastLineCount = newCount

            let newLine = ShimmerTextTickerLogic.displayLine(from: newText, isStreaming: isStreaming)
            guard newLine != displayedLine else { return }

            scheduleTransition(to: newLine)
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                let finalLine = ShimmerTextTickerLogic.displayLine(from: text, isStreaming: false)
                guard finalLine != displayedLine else { return }
                // Final commit bypasses cooldown
                commitTransition(to: finalLine)
            }
        }
    }

    /// Schedules a slide-up, respecting the cooldown so rapid traces don't spazz.
    private func scheduleTransition(to line: String) {
        let elapsed = Date().timeIntervalSince(lastTransitionTime)
        let cooldown = ShimmerTextTickerLogic.transitionCooldown

        if elapsed >= cooldown {
            // Enough time has passed — animate immediately
            commitTransition(to: line)
        } else {
            // Buffer this line and schedule a delayed commit
            pendingLine = line
            cooldownTask?.cancel()
            cooldownTask = Task { @MainActor in
                let remaining = cooldown - elapsed
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if let pending = pendingLine {
                    commitTransition(to: pending)
                    pendingLine = nil
                }
            }
        }
    }

    private func commitTransition(to line: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            displayedLine = line
            lineId = UUID()
        }
        lastTransitionTime = Date()
        cooldownTask?.cancel()
        pendingLine = nil
    }

    @ViewBuilder
    private var tickerText: some View {
        Text(displayedLine)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundColor(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .id(lineId)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                )
            )
            .overlay { shimmerOverlay }
    }

    // Shimmer is always active — this component only renders during execution,
    // so the sweep should always be visible regardless of isStreaming state.
    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: theme.accentColor.opacity(0.55), location: 0.35),
                    .init(color: .white.opacity(0.75), location: 0.5),
                    .init(color: theme.accentColor.opacity(0.55), location: 0.65),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 100)
            .offset(x: shimmerOffset * geometry.size.width)
            .onAppear {
                shimmerOffset = -0.3
                withAnimation(
                    .easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: false)
                ) {
                    shimmerOffset = 1.3
                }
            }
        }
        .mask {
            Text(displayedLine)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("ShimmerTextTicker States") {
        VStack(spacing: 20) {
            ShimmerTextTicker(
                text: "Analyzing the authentication module for potential security vulnerabilities...",
                isStreaming: true
            )

            ShimmerTextTicker(
                text: "Line 1: Reading files\nLine 2: Parsing AST\nLine 3: Generating fix",
                isStreaming: true
            )

            ShimmerTextTicker(
                text: "Analysis complete. Found 3 issues.",
                isStreaming: false
            )

            ShimmerTextTicker(
                text: "",
                isStreaming: false
            )
        }
        .padding()
        .frame(width: 500)
    }
#endif
