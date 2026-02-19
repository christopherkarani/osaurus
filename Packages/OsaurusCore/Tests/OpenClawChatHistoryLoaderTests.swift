//
//  OpenClawChatHistoryLoaderTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private func encodeJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

struct OpenClawChatHistoryLoaderTests {
    @Test @MainActor
    func loadHistory_mapsUserAssistantThinkingAndText() async throws {
        let connection = OpenClawGatewayConnection { method, params in
            #expect(method == "chat.history")
            #expect(params?["sessionKey"]?.value as? String == "agent:main:test")
            return try encodeJSON([
                "sessionKey": "agent:main:test",
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "text", "text": "Hello"]
                        ]
                    ],
                    [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hi there"],
                            ["type": "text", "thinking": "Let me reason"]
                        ]
                    ]
                ]
            ])
        }

        let turns = try await OpenClawChatHistoryLoader.loadHistory(
            sessionKey: "agent:main:test",
            connection: connection
        )

        #expect(turns.count == 2)
        #expect(turns[0].role == .user)
        #expect(turns[0].content == "Hello")
        #expect(turns[1].role == .assistant)
        #expect(turns[1].content == "Hi there")
        #expect(turns[1].thinking.contains("Let me reason"))
    }

    @Test @MainActor
    func loadHistory_stitchesToolResultIntoAssistantTurn() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "chat.history")
            return try encodeJSON([
                "sessionKey": "agent:main:tool",
                "messages": [
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "toolCall",
                                "id": "tool-1",
                                "name": "search_web",
                                "arguments": ["q": "swift"]
                            ],
                            ["type": "text", "text": "Checking that for you"]
                        ]
                    ],
                    [
                        "role": "tool",
                        "toolCallId": "tool-1",
                        "toolName": "search_web",
                        "content": [
                            ["type": "text", "text": "result body"]
                        ]
                    ]
                ]
            ])
        }

        let turns = try await OpenClawChatHistoryLoader.loadHistory(
            sessionKey: "agent:main:tool",
            connection: connection
        )

        #expect(turns.count == 1)
        let assistant = turns[0]
        #expect(assistant.role == .assistant)
        #expect(assistant.toolCalls?.first?.id == "tool-1")
        #expect(assistant.toolCalls?.first?.function.name == "search_web")
        #expect(assistant.toolResults["tool-1"] == "result body")
    }

    @Test @MainActor
    func loadHistory_handlesStringContentPayloads() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "chat.history")
            return try encodeJSON([
                "sessionKey": "agent:main:string",
                "messages": [
                    [
                        "role": "assistant",
                        "content": "plain string content"
                    ]
                ]
            ])
        }

        let turns = try await OpenClawChatHistoryLoader.loadHistory(
            sessionKey: "agent:main:string",
            connection: connection
        )

        #expect(turns.count == 1)
        #expect(turns[0].content == "plain string content")
    }
}
