//
//  OpenClawEventProcessor.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol

@MainActor
final class OpenClawEventProcessor {
    private struct AgentEventPayload: Decodable {
        let runId: String
        let seq: Int?
        let stream: String
        let ts: Int?
        let data: [String: OpenClawProtocol.AnyCodable]
    }

    private struct ChatEventPayload: Decodable {
        let runId: String
        let seq: Int?
        let state: String
        let message: OpenClawProtocol.AnyCodable?
        let errorMessage: String?
    }

    private let onTextDelta: ((String) -> Void)?
    private let onSequenceGap: ((Int, Int) -> Void)?
    private let onRunEnded: (() -> Void)?
    private let onSync: (() -> Void)?

    private var deltaProcessor: StreamingDeltaProcessor?
    private var currentRunId: String?
    private var lastSeq: Int = 0

    // MARK: - System Trace Detection
    // OpenClaw responses often append a structured "System:\n\n# Task Execution..."
    // section after the real response text. We detect this boundary and route
    // everything from "System:" onward to thinking (collapsible) rather than content.

    /// Whether we have passed the "System:" trace boundary in this run.
    private var inSystemTrace = false
    /// Buffer for detecting the "\nSystem:\n" marker across delta boundaries.
    private var systemBoundaryBuffer = ""

    /// The primary marker that signals the start of OpenClaw's trace section.
    private static let systemTraceMarker = "\nSystem:\n"

    /// All proper prefixes of the marker, longest first, for partial-match buffering.
    private static let systemTracePartials: [String] = {
        let marker = "\nSystem:\n"
        return (1 ..< marker.count).map { String(marker.prefix($0)) }.reversed()
    }()

    init(
        onTextDelta: ((String) -> Void)? = nil,
        onSequenceGap: ((Int, Int) -> Void)? = nil,
        onRunEnded: (() -> Void)? = nil,
        onSync: (() -> Void)? = nil
    ) {
        self.onTextDelta = onTextDelta
        self.onSequenceGap = onSequenceGap
        self.onRunEnded = onRunEnded
        self.onSync = onSync
    }

    func startRun(runId: String, turn: ChatTurn) {
        currentRunId = runId
        lastSeq = 0
        inSystemTrace = false
        systemBoundaryBuffer = ""
        deltaProcessor = StreamingDeltaProcessor(turn: turn, onSync: onSync)
    }

    func processEvent(_ event: EventFrame, turn: ChatTurn) {
        let eventName = event.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if eventName.contains("chat"), let payload = decodeChatPayload(event.payload) {
            guard payload.runId == currentRunId else { return }
            recordSequence(payload.seq ?? event.seq)
            processChat(payload, turn: turn)
            return
        }

        if eventName.contains("agent"), let payload = decodeAgentPayload(event.payload) {
            guard payload.runId == currentRunId else { return }
            recordSequence(payload.seq ?? event.seq)
            processAgent(payload, turn: turn)
            return
        }
    }

    func endRun(turn _: ChatTurn) {
        // Flush any buffered boundary-detection text as regular content.
        if !systemBoundaryBuffer.isEmpty {
            deltaProcessor?.receiveDelta(systemBoundaryBuffer)
            systemBoundaryBuffer = ""
        }
        deltaProcessor?.finalize()
        deltaProcessor = nil
        currentRunId = nil
        lastSeq = 0
        inSystemTrace = false
        onRunEnded?()
    }

    private func processChat(_ payload: ChatEventPayload, turn: ChatTurn) {
        switch payload.state {
        case "delta":
            if let text = extractChatText(payload.message), !text.isEmpty {
                routeAssistantText(text, turn: turn)
            }
            if let thinking = extractChatThinking(payload.message), !thinking.isEmpty {
                turn.appendThinkingAndNotify(thinking)
            }
        case "final", "aborted":
            endRun(turn: turn)
        case "error":
            let message = payload.errorMessage ?? "OpenClaw run failed."
            appendError(message, to: turn)
            endRun(turn: turn)
        default:
            break
        }
    }

    private func processAgent(_ payload: AgentEventPayload, turn: ChatTurn) {
        switch payload.stream {
        case "assistant":
            if let text = stringValue(payload.data["text"]?.value) ?? stringValue(payload.data["delta"]?.value),
                !text.isEmpty
            {
                routeAssistantText(text, turn: turn)
            }

        case "thinking":
            if let thinking = stringValue(payload.data["text"]?.value) ?? stringValue(payload.data["delta"]?.value),
                !thinking.isEmpty
            {
                turn.appendThinkingAndNotify(thinking)
            }

        case "tool":
            // Flush any pending boundary-detection buffer as content before processing the tool.
            if !systemBoundaryBuffer.isEmpty {
                deltaProcessor?.receiveDelta(systemBoundaryBuffer)
                systemBoundaryBuffer = ""
            }
            deltaProcessor?.flush()
            processTool(data: payload.data, turn: turn)

        case "lifecycle":
            let phase = stringValue(payload.data["phase"]?.value)?.lowercased() ?? ""
            if phase == "end" {
                endRun(turn: turn)
            } else if phase == "error" {
                let message = stringValue(payload.data["error"]?.value)
                    ?? stringValue(payload.data["message"]?.value)
                    ?? "OpenClaw run failed."
                appendError(message, to: turn)
                endRun(turn: turn)
            }

        case "error":
            let message = stringValue(payload.data["message"]?.value)
                ?? stringValue(payload.data["error"]?.value)
                ?? "OpenClaw run failed."
            appendError(message, to: turn)
            endRun(turn: turn)

        case "compaction":
            let phase = stringValue(payload.data["phase"]?.value)?.lowercased() ?? ""
            if phase == "start" {
                turn.appendThinkingAndNotify("[Compacting context…]")
            } else if phase == "end", (payload.data["willRetry"]?.value as? Bool) == true {
                turn.appendThinkingAndNotify("[Compaction complete, retrying response…]")
            }

        default:
            break
        }
    }

    private func processTool(data: [String: OpenClawProtocol.AnyCodable], turn: ChatTurn) {
        let phase = stringValue(data["phase"]?.value)?.lowercased() ?? ""
        guard let toolCallId = stringValue(data["toolCallId"]?.value), !toolCallId.isEmpty else { return }

        switch phase {
        case "start":
            let name = stringValue(data["name"]?.value) ?? "tool"
            let argsJSONString = stringifyArguments(data["args"]?.value) ?? "{}"
            let call = ToolCall(
                id: toolCallId,
                type: "function",
                function: ToolCallFunction(name: name, arguments: argsJSONString)
            )
            if turn.toolCalls == nil {
                turn.toolCalls = []
            }
            if !(turn.toolCalls?.contains(where: { $0.id == toolCallId }) ?? false) {
                turn.toolCalls?.append(call)
            }

            if let partial = stringValue(data["text"]?.value) ?? stringValue(data["partialResult"]?.value) {
                turn.toolResults[toolCallId] = partial
            }
            turn.notifyContentChanged()

        case "update":
            if let partial = stringValue(data["text"]?.value) ?? stringValue(data["partialResult"]?.value) {
                turn.toolResults[toolCallId] = partial
                turn.notifyContentChanged()
            }

        case "result":
            let result = stringifyResult(data["result"]?.value)
                ?? stringValue(data["text"]?.value)
                ?? ""
            turn.toolResults[toolCallId] = result
            turn.notifyContentChanged()

        default:
            break
        }
    }

    // MARK: - System Trace Routing

    /// Routes an assistant text delta to either regular content or thinking,
    /// depending on whether we have crossed the "System:" trace boundary.
    private func routeAssistantText(_ text: String, turn: ChatTurn) {
        if inSystemTrace {
            turn.appendThinkingAndNotify(text)
            return
        }

        let combined = systemBoundaryBuffer + text
        systemBoundaryBuffer = ""

        let marker = Self.systemTraceMarker  // "\nSystem:\n"

        if let markerRange = combined.range(of: marker) {
            // Flush everything before the marker as regular content.
            let contentPart = String(combined[..<markerRange.lowerBound])
            if !contentPart.isEmpty {
                deltaProcessor?.receiveDelta(contentPart)
                onTextDelta?(contentPart)
            }

            // Switch permanently to system-trace (thinking) mode.
            inSystemTrace = true

            // Thinking begins with "System:\n" followed by whatever came after the marker.
            let afterMarker = String(combined[markerRange.upperBound...])
            let thinkingText = "System:\n" + afterMarker
            turn.appendThinkingAndNotify(thinkingText)
            return
        }

        // No full marker found — check if the end of `combined` is a partial prefix
        // of the marker so we can buffer it rather than flushing prematurely.
        if let partial = Self.systemTracePartials.first(where: { combined.hasSuffix($0) }) {
            let flushPart = String(combined.dropLast(partial.count))
            systemBoundaryBuffer = partial
            if !flushPart.isEmpty {
                deltaProcessor?.receiveDelta(flushPart)
                onTextDelta?(flushPart)
            }
            return
        }

        // No match or partial match — flush everything as regular content.
        deltaProcessor?.receiveDelta(combined)
        onTextDelta?(combined)
    }

    private func appendError(_ message: String, to turn: ChatTurn) {
        let line = "Error: \(message)"
        if turn.contentIsEmpty {
            turn.content = line
        } else {
            turn.appendContent("\n\(line)")
            turn.notifyContentChanged()
        }
    }

    private func recordSequence(_ seq: Int?) {
        guard let seq, seq > 0 else { return }
        if lastSeq > 0, seq > lastSeq + 1 {
            // The callback must remain lightweight and non-blocking. Network-side
            // refresh/resync work is handled by the gateway connection actor.
            onSequenceGap?(lastSeq + 1, seq)
        }
        if seq > lastSeq {
            lastSeq = seq
        }
    }

    private func decodeAgentPayload(_ payload: OpenClawProtocol.AnyCodable?) -> AgentEventPayload? {
        guard let payload else { return nil }
        return try? GatewayPayloadDecoding.decode(payload, as: AgentEventPayload.self)
    }

    private func decodeChatPayload(_ payload: OpenClawProtocol.AnyCodable?) -> ChatEventPayload? {
        guard let payload else { return nil }
        return try? GatewayPayloadDecoding.decode(payload, as: ChatEventPayload.self)
    }

    private func extractChatText(_ message: OpenClawProtocol.AnyCodable?) -> String? {
        guard let messageDictionary = message?.value as? [String: OpenClawProtocol.AnyCodable],
            let contentArray = messageDictionary["content"]?.value as? [OpenClawProtocol.AnyCodable]
        else {
            return nil
        }

        var fragments: [String] = []
        for item in contentArray {
            guard let itemDictionary = item.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            if let text = itemDictionary["text"]?.value as? String, !text.isEmpty {
                fragments.append(text)
            }
        }
        return fragments.isEmpty ? nil : fragments.joined()
    }

    private func extractChatThinking(_ message: OpenClawProtocol.AnyCodable?) -> String? {
        guard let messageDictionary = message?.value as? [String: OpenClawProtocol.AnyCodable],
            let contentArray = messageDictionary["content"]?.value as? [OpenClawProtocol.AnyCodable]
        else {
            return nil
        }

        var fragments: [String] = []
        for item in contentArray {
            guard let itemDictionary = item.value as? [String: OpenClawProtocol.AnyCodable] else { continue }
            if let thinking = itemDictionary["thinking"]?.value as? String, !thinking.isEmpty {
                fragments.append(thinking)
            }
        }
        return fragments.isEmpty ? nil : fragments.joined()
    }

    private func stringifyArguments(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: OpenClawProtocol.AnyCodable] {
            let raw = dictionary.mapValues(\.value)
            return serializeJSON(raw)
        }
        if let dictionary = value as? [String: Any] {
            return serializeJSON(dictionary)
        }
        return nil
    }

    private func stringifyResult(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: OpenClawProtocol.AnyCodable] {
            if let contentArray = dictionary["content"]?.value as? [OpenClawProtocol.AnyCodable] {
                let texts = contentArray.compactMap { item -> String? in
                    guard let itemDictionary = item.value as? [String: OpenClawProtocol.AnyCodable] else {
                        return nil
                    }
                    return itemDictionary["text"]?.value as? String
                }
                if !texts.isEmpty {
                    return texts.joined(separator: "\n")
                }
            }
            return serializeJSON(dictionary.mapValues(\.value))
        }
        if let array = value as? [OpenClawProtocol.AnyCodable] {
            let rawArray = array.map(\.value)
            return serializeJSON(rawArray)
        }
        if let dictionary = value as? [String: Any] {
            return serializeJSON(dictionary)
        }
        if let array = value as? [Any] {
            return serializeJSON(array)
        }
        return String(describing: value)
    }

    private func serializeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
