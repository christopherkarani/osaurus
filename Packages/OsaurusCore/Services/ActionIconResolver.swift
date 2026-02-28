//
//  ActionIconResolver.swift
//  osaurus
//
//  Two-tier icon resolution for tool action rows.
//  Tier 1: Instant static mapping via ToolCallSummaryLogic.toolIcon.
//  Tier 2: Foundation Model inference (macOS 26+) with session-level memoization.
//

import Foundation
import SwiftUI

@MainActor
final class ActionIconResolver: ObservableObject {
    /// Published so ToolActionRow can react when FM inference completes.
    @Published private var cache: [String: String] = [:]

    /// In-flight FM requests (prevent duplicates).
    private var pending: Set<String> = []

    // MARK: - Public API

    /// Returns the best icon synchronously (Tier 1), then triggers Tier 2 inference if available.
    /// Callers should observe this object — icon updates via `@Published cache`.
    func icon(toolName: String, arguments: String, thinkingContext: String?) -> String {
        let key = Self.cacheKey(toolName: toolName, arguments: arguments)

        // Cache hit — may be static or FM-inferred
        if let cached = cache[key] { return cached }

        // Tier 1: static fallback
        let staticIcon = ToolCallSummaryLogic.toolIcon(for: toolName)
        cache[key] = staticIcon

        // Tier 2: fire-and-forget FM inference
        if !pending.contains(key) {
            pending.insert(key)
            Task { [weak self] in
                guard let self else { return }
                if let inferred = await Self.inferIcon(
                    toolName: toolName,
                    arguments: arguments,
                    thinkingContext: thinkingContext
                ) {
                    self.cache[key] = inferred
                }
                self.pending.remove(key)
            }
        }

        return staticIcon
    }

    /// Resolve from cache only (no inference trigger). Used for repeated renders.
    func cachedIcon(toolName: String, arguments: String) -> String {
        let key = Self.cacheKey(toolName: toolName, arguments: arguments)
        return cache[key] ?? ToolCallSummaryLogic.toolIcon(for: toolName)
    }

    // MARK: - Cache Key

    nonisolated static func cacheKey(toolName: String, arguments: String) -> String {
        let argHash = arguments.hash
        return "\(toolName):\(argHash)"
    }

    // MARK: - Curated Symbols

    nonisolated(unsafe) static let curatedSymbols: [String] = [
        "doc.text", "doc.badge.plus", "pencil.line", "terminal", "terminal.fill",
        "magnifyingglass", "list.bullet", "trash", "doc.on.doc", "globe",
        "brain.head.profile", "wrench.and.screwdriver", "gearshape", "network",
        "folder", "arrow.down.doc", "arrow.up.doc", "chart.bar", "photo",
        "text.alignleft", "checkmark.seal", "shield", "key", "lock",
        "cloud.arrow.down", "cloud.arrow.up", "antenna.radiowaves.left.and.right",
        "cpu", "memorychip", "play.fill", "pause.fill", "arrow.clockwise",
        "text.bubble", "envelope", "calendar", "clock", "mappin",
        "testtube.2", "flask.fill", "wand.and.stars", "sparkles", "lightbulb",
    ]

    // MARK: - FM Prompt

    nonisolated static func buildPrompt(toolName: String, arguments: String, thinkingContext: String?) -> String {
        let truncatedArgs = arguments.prefix(200)
        let context = thinkingContext.map { " The AI was thinking: \"\($0.prefix(150))\"" } ?? ""
        return """
        Pick the single best SF Symbol for this AI tool call. \
        Tool: \(toolName)(\(truncatedArgs)).\(context) \
        Choose from: \(curatedSymbols.joined(separator: ", ")). \
        Reply with ONLY the symbol name, nothing else.
        """
    }

    // MARK: - Foundation Model Inference

    private static func inferIcon(
        toolName: String,
        arguments: String,
        thinkingContext: String?
    ) async -> String? {
        guard FoundationModelService.isDefaultModelAvailable() else { return nil }

        let prompt = buildPrompt(
            toolName: toolName,
            arguments: arguments,
            thinkingContext: thinkingContext
        )

        do {
            let result = try await FoundationModelService.generateOneShot(
                prompt: prompt,
                temperature: 0.1,
                maxTokens: 20
            )
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if curatedSymbols.contains(cleaned) {
                return cleaned
            }
        } catch {
            // Silently fall back — icon inference is best-effort
        }
        return nil
    }
}
