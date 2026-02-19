//
//  OpenClawChatHistoryLoader.swift
//  osaurus
//

import Foundation
import OpenClawKit
import OpenClawProtocol

@MainActor
enum OpenClawChatHistoryLoader {
    private struct GatewayHistoryMessage: Decodable {
        let role: String
        let content: [GatewayHistoryContent]
        let timestamp: Double?
        let toolCallId: String?
        let toolName: String?

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case timestamp
            case toolCallId
            case tool_call_id
            case toolName
            case tool_name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
            toolCallId =
                try container.decodeIfPresent(String.self, forKey: .toolCallId)
                ?? container.decodeIfPresent(String.self, forKey: .tool_call_id)
            toolName =
                try container.decodeIfPresent(String.self, forKey: .toolName)
                ?? container.decodeIfPresent(String.self, forKey: .tool_name)

            if let arrayContent = try? container.decode([GatewayHistoryContent].self, forKey: .content) {
                content = arrayContent
            } else if let textContent = try? container.decode(String.self, forKey: .content) {
                content = [
                    GatewayHistoryContent(
                        type: "text",
                        text: textContent,
                        thinking: nil,
                        id: nil,
                        name: nil,
                        arguments: nil,
                        content: nil
                    )
                ]
            } else {
                content = []
            }
        }
    }

    private struct GatewayHistoryContent: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let arguments: OpenClawProtocol.AnyCodable?
        let content: OpenClawProtocol.AnyCodable?
    }

    static func loadHistory(
        sessionKey: String,
        connection: OpenClawGatewayConnection = .shared,
        limit: Int? = 200
    ) async throws -> [ChatTurn] {
        let payload = try await connection.chatHistory(sessionKey: sessionKey, limit: limit)
        return mapTurns(from: payload.messages ?? [])
    }

    static func mapTurns(from messages: [OpenClawProtocol.AnyCodable]) -> [ChatTurn] {
        let decoded = messages.compactMap { item in
            try? GatewayPayloadDecoding.decode(item, as: GatewayHistoryMessage.self)
        }

        var turns: [ChatTurn] = []
        var assistantTurnByToolCallId: [String: ChatTurn] = [:]
        var latestAssistantTurn: ChatTurn?

        for message in decoded {
            switch normalizedRole(message.role) {
            case .user:
                let text = extractDisplayText(from: message)
                let turn = ChatTurn(role: .user, content: text)
                turns.append(turn)

            case .assistant:
                let text = extractDisplayText(from: message)
                let turn = ChatTurn(role: .assistant, content: text)

                let thinking = extractThinkingText(from: message)
                if !thinking.isEmpty {
                    turn.appendThinking(thinking)
                }

                let toolCalls = extractToolCalls(from: message)
                if !toolCalls.isEmpty {
                    turn.toolCalls = toolCalls
                    for call in toolCalls {
                        assistantTurnByToolCallId[call.id] = turn
                    }
                }

                if !turn.contentIsEmpty || turn.hasThinking || !(turn.toolCalls?.isEmpty ?? true) {
                    turns.append(turn)
                    latestAssistantTurn = turn
                }

            case .tool:
                guard let toolCallId = resolveToolCallId(from: message) else { continue }
                let resultText = extractDisplayText(from: message)
                guard !resultText.isEmpty else { continue }

                if let owner = assistantTurnByToolCallId[toolCallId] ?? latestAssistantTurn {
                    attachToolResult(
                        toolCallId: toolCallId,
                        resultText: resultText,
                        message: message,
                        into: owner
                    )
                    assistantTurnByToolCallId[toolCallId] = owner
                }

            case .other:
                continue
            }
        }

        return turns
    }

    private enum HistoryRole {
        case user
        case assistant
        case tool
        case other
    }

    private static func normalizedRole(_ role: String) -> HistoryRole {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "tool":
            return .tool
        default:
            return .other
        }
    }

    private static func extractDisplayText(from message: GatewayHistoryMessage) -> String {
        var pieces: [String] = []

        for item in message.content {
            if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                pieces.append(text)
                continue
            }
            if let payloadText = stringifyContentPayload(item.content), !payloadText.isEmpty {
                pieces.append(payloadText)
            }
        }

        return pieces.joined(separator: "\n")
    }

    private static func extractThinkingText(from message: GatewayHistoryMessage) -> String {
        message.content
            .compactMap { $0.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func extractToolCalls(from message: GatewayHistoryMessage) -> [ToolCall] {
        var calls: [ToolCall] = []

        for (index, item) in message.content.enumerated() {
            let looksLikeToolCall: Bool = {
                if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return true
                }
                let type = item.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                return type == "toolcall" || type == "tool_use" || type == "tool"
            }()
            guard looksLikeToolCall else { continue }

            let callId =
                item.id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? message.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "\(message.timestamp ?? 0)-\(index)"

            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "tool"

            let arguments = stringifyArguments(item.arguments) ?? "{}"
            calls.append(
                ToolCall(
                    id: callId,
                    type: "function",
                    function: ToolCallFunction(name: name, arguments: arguments)
                )
            )
        }

        return calls
    }

    private static func resolveToolCallId(from message: GatewayHistoryMessage) -> String? {
        if let direct = message.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
            return direct
        }
        for item in message.content {
            if let id = item.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private static func attachToolResult(
        toolCallId: String,
        resultText: String,
        message: GatewayHistoryMessage,
        into turn: ChatTurn
    ) {
        if turn.toolCalls == nil {
            turn.toolCalls = []
        }
        if turn.toolCalls?.contains(where: { $0.id == toolCallId }) == false {
            let fallbackName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "tool"
            let fallbackCall = ToolCall(
                id: toolCallId,
                type: "function",
                function: ToolCallFunction(name: fallbackName, arguments: "{}")
            )
            turn.toolCalls?.append(fallbackCall)
        }
        turn.toolResults[toolCallId] = resultText
        turn.notifyContentChanged()
    }

    private static func stringifyArguments(_ value: OpenClawProtocol.AnyCodable?) -> String? {
        guard let value else { return nil }
        if let text = value.value as? String {
            return text
        }
        return serializeJSON(value.value)
    }

    private static func stringifyContentPayload(_ value: OpenClawProtocol.AnyCodable?) -> String? {
        guard let value else { return nil }
        if let text = value.value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return serializeJSON(value.value)
    }

    private static func serializeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
