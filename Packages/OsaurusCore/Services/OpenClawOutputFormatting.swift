//
//  OpenClawOutputFormatting.swift
//  osaurus
//

import Foundation

enum OpenClawOutputFormatting {
    static let clarificationStartMarker = "---REQUEST_CLARIFICATION_START---"
    static let clarificationEndMarker = "---REQUEST_CLARIFICATION_END---"
    static let completeTaskStartMarker = "---COMPLETE_TASK_START---"
    static let completeTaskEndMarker = "---COMPLETE_TASK_END---"
    static let generatedArtifactStartMarker = "---GENERATED_ARTIFACT_START---"
    static let generatedArtifactEndMarker = "---GENERATED_ARTIFACT_END---"

    private static let systemTraceMarkers = ["\nSystem:\n", "System:\n"]

    struct CompleteTaskPayload {
        let summary: String?
        let success: Bool?
        let artifact: String?
    }

    static func sanitizeVisibleText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        var output = raw
        output = stripSystemTrace(from: output)
        output = stripTaggedBlocks(
            from: output,
            startMarker: clarificationStartMarker,
            endMarker: clarificationEndMarker
        )
        output = stripTaggedBlocks(
            from: output,
            startMarker: completeTaskStartMarker,
            endMarker: completeTaskEndMarker
        )
        output = stripTaggedBlocks(
            from: output,
            startMarker: generatedArtifactStartMarker,
            endMarker: generatedArtifactEndMarker
        )

        return output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func finalizedVisibleText(
        rawAssistantOutput: String,
        currentlyRendered: String
    ) -> String {
        let rendered = sanitizeVisibleText(currentlyRendered)
        let completion = extractCompleteTaskPayload(from: rawAssistantOutput)
        let completionArtifact = completion?.artifact?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let completionSummary = completion?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let generatedArtifact = extractLatestGeneratedArtifactContent(from: rawAssistantOutput)

        if let completionArtifact, shouldPromoteArtifact(completionArtifact, over: rendered) {
            return completionArtifact
        }

        if rendered.isEmpty {
            if let completionArtifact {
                return completionArtifact
            }
            if let generatedArtifact {
                return generatedArtifact
            }
            if let completionSummary {
                return completionSummary
            }
        }

        if rendered.isEmpty, let generatedArtifact {
            return generatedArtifact
        }

        return rendered
    }

    static func formatHistoryText(_ raw: String) -> String {
        finalizedVisibleText(
            rawAssistantOutput: raw,
            currentlyRendered: sanitizeVisibleText(raw)
        )
    }

    static func extractCompleteTaskPayload(from text: String) -> CompleteTaskPayload? {
        guard let jsonBlock = extractLastJSONBlock(
            from: text,
            startMarker: completeTaskStartMarker,
            endMarker: completeTaskEndMarker
        ),
            let data = jsonBlock.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let summary = stringValue(object["summary"])
        let success = boolValue(object["success"])
        let artifact = stringValue(object["artifact"])
        if summary == nil, success == nil, artifact == nil {
            return nil
        }
        return CompleteTaskPayload(
            summary: summary,
            success: success,
            artifact: artifact
        )
    }

    static func extractLatestGeneratedArtifactContent(from text: String) -> String? {
        var cursor = text.startIndex
        var latest: String?

        while cursor < text.endIndex,
            let start = text.range(of: generatedArtifactStartMarker, range: cursor..<text.endIndex),
            let end = text.range(of: generatedArtifactEndMarker, range: start.upperBound..<text.endIndex)
        {
            let body = String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .newlines)
            let lines = body.components(separatedBy: .newlines)
            if lines.count >= 2 {
                let content = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    latest = content
                }
            }
            cursor = end.upperBound
        }

        return latest
    }

    private static func shouldPromoteArtifact(_ artifact: String, over rendered: String) -> Bool {
        if rendered.isEmpty {
            return true
        }
        if looksLikeProgressNarration(rendered) {
            return true
        }
        if artifact.count > rendered.count * 2,
            !rendered.contains("\n#"),
            !rendered.contains("##")
        {
            return true
        }
        return false
    }

    private static func looksLikeProgressNarration(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let progressSignals = [
            "let me ",
            "i'll ",
            "i will ",
            "working on it",
            "good start",
            "i now have",
            "i've fetched",
            "compiling all this",
            "gathering",
            "fetching",
        ]
        let matchCount = progressSignals.reduce(into: 0) { count, token in
            if normalized.contains(token) {
                count += 1
            }
        }
        let sentenceCount = max(1, text.split(separator: ".").count)
        return sentenceCount >= 2 && matchCount >= 2
    }

    private static func stripSystemTrace(from text: String) -> String {
        var output = text
        for marker in systemTraceMarkers {
            if let range = output.range(of: marker) {
                return String(output[..<range.lowerBound])
            }
            if output.hasPrefix(marker) {
                return ""
            }
        }
        return output
    }

    private static func stripTaggedBlocks(
        from text: String,
        startMarker: String,
        endMarker: String
    ) -> String {
        var output = text
        while let startRange = output.range(of: startMarker),
            let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        {
            output.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return output
    }

    private static func extractLastJSONBlock(
        from text: String,
        startMarker: String,
        endMarker: String
    ) -> String? {
        var cursor = text.startIndex
        var payload: String?

        while cursor < text.endIndex,
            let start = text.range(of: startMarker, range: cursor..<text.endIndex),
            let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        {
            let candidate = String(text[start.upperBound..<end.lowerBound])
            let normalized = normalizeJSONBlock(candidate)
            if !normalized.isEmpty {
                payload = normalized
            }
            cursor = end.upperBound
        }

        return payload
    }

    private static func normalizeJSONBlock(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let firstNewline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: firstNewline)...])
            }
            if let closingFence = value.range(of: "```", options: .backwards) {
                value = String(value[..<closingFence.lowerBound])
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }
}

struct OpenClawControlBlockStreamFilter {
    private struct MarkerPair {
        let start: String
        let end: String
    }

    private struct StartMatch {
        let range: Range<String.Index>
        let endMarker: String
    }

    private static let markerPairs: [MarkerPair] = [
        MarkerPair(
            start: OpenClawOutputFormatting.clarificationStartMarker,
            end: OpenClawOutputFormatting.clarificationEndMarker
        ),
        MarkerPair(
            start: OpenClawOutputFormatting.completeTaskStartMarker,
            end: OpenClawOutputFormatting.completeTaskEndMarker
        ),
        MarkerPair(
            start: OpenClawOutputFormatting.generatedArtifactStartMarker,
            end: OpenClawOutputFormatting.generatedArtifactEndMarker
        ),
    ]

    private static let startPartials: [String] = {
        var partials = Set<String>()
        for pair in markerPairs {
            for length in 1 ..< pair.start.count {
                partials.insert(String(pair.start.prefix(length)))
            }
        }
        return partials.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }()

    private var carry = ""
    private var activeEndMarker: String?

    mutating func reset() {
        carry = ""
        activeEndMarker = nil
    }

    mutating func consume(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        var remaining = carry + chunk
        carry = ""
        var visibleOutput = ""

        while !remaining.isEmpty {
            if let activeEndMarker {
                if let endRange = remaining.range(of: activeEndMarker) {
                    remaining = String(remaining[endRange.upperBound...])
                    self.activeEndMarker = nil
                    continue
                }

                let partialLength = Self.longestPartialSuffix(in: remaining, marker: activeEndMarker)
                if partialLength > 0 {
                    carry = String(remaining.suffix(partialLength))
                } else {
                    let keepCount = min(max(activeEndMarker.count - 1, 0), remaining.count)
                    carry = keepCount > 0 ? String(remaining.suffix(keepCount)) : ""
                }
                return visibleOutput
            }

            guard let startMatch = Self.firstStartMarker(in: remaining) else {
                let partialLength = Self.longestStartPartialSuffix(in: remaining)
                if partialLength > 0 {
                    let flushCount = remaining.count - partialLength
                    if flushCount > 0 {
                        visibleOutput += String(remaining.prefix(flushCount))
                    }
                    carry = String(remaining.suffix(partialLength))
                } else {
                    visibleOutput += remaining
                }
                return visibleOutput
            }

            let beforeMarker = String(remaining[..<startMatch.range.lowerBound])
            if !beforeMarker.isEmpty {
                visibleOutput += beforeMarker
            }
            remaining = String(remaining[startMatch.range.upperBound...])
            activeEndMarker = startMatch.endMarker
        }

        return visibleOutput
    }

    mutating func finalize() -> String {
        defer {
            carry = ""
            activeEndMarker = nil
        }

        guard activeEndMarker == nil else { return "" }

        let trailing = carry
        guard !trailing.isEmpty else { return "" }
        if Self.markerPairs.contains(where: { $0.start.hasPrefix(trailing) }) {
            return ""
        }
        return trailing
    }

    private static func firstStartMarker(in text: String) -> StartMatch? {
        var earliest: StartMatch?
        for pair in markerPairs {
            guard let range = text.range(of: pair.start) else { continue }
            let candidate = StartMatch(range: range, endMarker: pair.end)
            if let current = earliest {
                if candidate.range.lowerBound < current.range.lowerBound {
                    earliest = candidate
                }
            } else {
                earliest = candidate
            }
        }
        return earliest
    }

    private static func longestStartPartialSuffix(in text: String) -> Int {
        for partial in startPartials where text.hasSuffix(partial) {
            return partial.count
        }
        return 0
    }

    private static func longestPartialSuffix(in text: String, marker: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let maxLength = min(marker.count - 1, text.count)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if marker.hasPrefix(suffix) {
                return length
            }
        }
        return 0
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
