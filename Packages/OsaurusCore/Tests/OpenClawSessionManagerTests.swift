//
//  OpenClawSessionManagerTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawSessionManagerCallRecorder {
    struct Call: Sendable {
        let method: String
        let params: [String: OpenClawProtocol.AnyCodable]?
    }

    private var calls: [Call] = []

    func append(method: String, params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append(Call(method: method, params: params))
    }

    func all() -> [Call] {
        calls
    }
}

private func encodeJSONObject(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

struct OpenClawSessionManagerTests {
    @Test @MainActor
    func loadSessions_mapsAndSortsByRecentActivity() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "sessions.list")
            return try encodeJSONObject([
                "sessions": [
                    [
                        "key": "agent:main:old",
                        "displayName": "Older Session",
                        "updatedAt": 1_708_345_600_000.0,
                        "lastMessagePreview": "old",
                        "model": "model-a",
                        "contextTokens": 20_000
                    ],
                    [
                        "key": "agent:main:new",
                        "derivedTitle": "Newest Session",
                        "updatedAt": 1_808_345_600_000.0,
                        "lastMessagePreview": "new",
                        "model": "model-b",
                        "contextTokens": 40_000
                    ]
                ]
            ])
        }
        let manager = OpenClawSessionManager(connection: connection)

        try await manager.loadSessions()

        #expect(manager.sessions.count == 2)
        #expect(manager.sessions[0].key == "agent:main:new")
        #expect(manager.sessions[0].title == "Newest Session")
        #expect(manager.sessions[0].lastMessage == "new")
        #expect(manager.sessions[1].key == "agent:main:old")
    }

    @Test @MainActor
    func createSession_setsActiveAndRefreshesSessions() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            if method == "sessions.patch" {
                return try encodeJSONObject(["ok": true, "key": "agent:main:newly-created"])
            }
            if method == "sessions.list" {
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:newly-created",
                            "displayName": "Created Session",
                            "updatedAt": 1_808_345_600_000.0
                        ]
                    ]
                ])
            }
            return try encodeJSONObject([:])
        }
        let manager = OpenClawSessionManager(connection: connection)

        let key = try await manager.createSession(model: "claude-opus")

        #expect(key == "agent:main:newly-created")
        #expect(manager.activeSessionKey == "agent:main:newly-created")
        #expect(manager.sessions.first?.key == "agent:main:newly-created")

        let calls = await recorder.all()
        #expect(calls.count == 2)
        #expect(calls[0].method == "sessions.patch")
        #expect(calls[0].params?["model"]?.value as? String == "claude-opus")
        #expect(calls[1].method == "sessions.list")
    }

    @Test @MainActor
    func patchDeleteAndCompact_forwardToGatewayMethods() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            return try encodeJSONObject([:])
        }
        let manager = OpenClawSessionManager(connection: connection)

        try await manager.patchSession(key: "agent:main:1", sendPolicy: "deny", model: "claude-sonnet")
        manager.setActiveSessionKey("agent:main:1")
        try await manager.deleteSession(key: "agent:main:1")
        try await manager.compactSession(key: "agent:main:2", maxLines: 80)
        try await manager.resetSession(key: "agent:main:3")

        let calls = await recorder.all()
        #expect(calls.count == 4)
        #expect(calls[0].method == "sessions.patch")
        #expect(calls[0].params?["key"]?.value as? String == "agent:main:1")
        #expect(calls[0].params?["sendPolicy"]?.value as? String == "deny")
        #expect(calls[0].params?["model"]?.value as? String == "claude-sonnet")
        #expect(calls[1].method == "sessions.delete")
        #expect(calls[2].method == "sessions.compact")
        #expect(calls[2].params?["maxLines"]?.value as? Int == 80)
        #expect(calls[3].method == "sessions.reset")
        #expect(calls[3].params?["reason"]?.value as? String == "new")
        #expect(manager.activeSessionKey == nil)
    }
}
