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
    func createSession_modelNotAllowed_recoversByPatchingAllowlistAndRetries() async throws {
        actor RecoveryState {
            var sessionsPatchAttempts = 0
            var configPatchRaw: String?
            var configPatchBaseHash: String?

            func nextSessionsPatchAttempt() -> Int {
                sessionsPatchAttempts += 1
                return sessionsPatchAttempts
            }

            func recordConfigPatch(raw: String?, baseHash: String?) {
                configPatchRaw = raw
                configPatchBaseHash = baseHash
            }

            func snapshot() -> (Int, String?, String?) {
                (sessionsPatchAttempts, configPatchRaw, configPatchBaseHash)
            }
        }

        let recorder = OpenClawSessionManagerCallRecorder()
        let recoveryState = RecoveryState()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)

            switch method {
            case "sessions.patch":
                let attempt = await recoveryState.nextSessionsPatchAttempt()
                if attempt == 1 {
                    throw NSError(
                        domain: "OpenClawSessionManagerTests",
                        code: 400,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "sessions.patch: [INVALID_REQUEST] model not allowed: osaurus/foundation"
                        ]
                    )
                }
                return try encodeJSONObject(["ok": true, "key": "agent:main:recovered"])

            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "agents": [
                            "defaults": [
                                "models": [
                                    "anthropic/claude-sonnet-4-6": [:]
                                ]
                            ]
                        ]
                    ],
                    "baseHash": "base-hash-recovery"
                ])

            case "config.patch":
                await recoveryState.recordConfigPatch(
                    raw: params?["raw"]?.value as? String,
                    baseHash: params?["baseHash"]?.value as? String
                )
                return try encodeJSONObject([
                    "ok": true,
                    "restart": false
                ])

            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:recovered",
                            "displayName": "Recovered Session",
                            "updatedAt": 1_808_345_600_000.0
                        ]
                    ]
                ])

            default:
                return try encodeJSONObject([:])
            }
        }

        let manager = OpenClawSessionManager(connection: connection)
        let key = try await manager.createSession(model: "osaurus/foundation")

        #expect(key == "agent:main:recovered")
        #expect(manager.activeSessionKey == "agent:main:recovered")
        #expect(manager.sessions.first?.key == "agent:main:recovered")

        let calls = await recorder.all()
        #expect(calls.count == 5)
        #expect(calls[0].method == "sessions.patch")
        #expect(calls[1].method == "config.get")
        #expect(calls[2].method == "config.patch")
        #expect(calls[3].method == "sessions.patch")
        #expect(calls[4].method == "sessions.list")

        let (attempts, rawPatch, baseHash) = await recoveryState.snapshot()
        #expect(attempts == 2)
        #expect(baseHash == "base-hash-recovery")

        let rawPatchValue = try #require(rawPatch)
        let patchData = try #require(rawPatchValue.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: patchData)
        let json = try #require(jsonObject as? [String: Any])
        let agents = json["agents"] as? [String: Any]
        let defaults = agents?["defaults"] as? [String: Any]
        let models = defaults?["models"] as? [String: Any]

        #expect(models?["osaurus/foundation"] != nil)
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

    @Test @MainActor
    func createSession_bareKimiModel_qualifiesToMoonshotWhenConfigured() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "moonshot": [
                                    "baseUrl": "https://api.moonshot.ai/v1",
                                    "api": "openai-completions",
                                    "apiKey": "__OPENCLAW_REDACTED__"
                                ]
                            ]
                        ]
                    ]
                ])
            case "sessions.patch":
                return try encodeJSONObject(["ok": true, "key": "agent:main:moonshot-kimi"])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:moonshot-kimi",
                            "displayName": "Moonshot Session",
                            "updatedAt": 1_808_345_600_000.0,
                            "model": "moonshot/kimi-k2.5"
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }
        let manager = OpenClawSessionManager(connection: connection)

        let key = try await manager.createSession(model: "kimi-k2.5")
        #expect(key == "agent:main:moonshot-kimi")

        let calls = await recorder.all()
        #expect(calls.count == 3)
        #expect(calls[0].method == "config.get")
        #expect(calls[1].method == "sessions.patch")
        #expect(calls[1].params?["model"]?.value as? String == "moonshot/kimi-k2.5")
        #expect(calls[2].method == "sessions.list")
    }

    @Test @MainActor
    func createSession_bareKimiModel_qualifiesToKimiCodingWhenOnlyKimiCodingConfigured() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "kimi-coding": [
                                    "baseUrl": "https://api.kimi.com/coding",
                                    "api": "anthropic-messages",
                                    "apiKey": "__OPENCLAW_REDACTED__"
                                ]
                            ]
                        ]
                    ]
                ])
            case "sessions.patch":
                return try encodeJSONObject(["ok": true, "key": "agent:main:kimi-coding-k2p5"])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:kimi-coding-k2p5",
                            "displayName": "Kimi Coding Session",
                            "updatedAt": 1_808_345_600_000.0,
                            "model": "kimi-coding/k2p5"
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }
        let manager = OpenClawSessionManager(connection: connection)

        let key = try await manager.createSession(model: "kimi-k2.5")
        #expect(key == "agent:main:kimi-coding-k2p5")

        let calls = await recorder.all()
        #expect(calls.count == 3)
        #expect(calls[0].method == "config.get")
        #expect(calls[1].method == "sessions.patch")
        #expect(calls[1].params?["model"]?.value as? String == "kimi-coding/k2p5")
        #expect(calls[2].method == "sessions.list")
    }

    @Test @MainActor
    func createSession_bareKimiThinkingModel_prefersMoonshotWhenConfigured() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "moonshot": [
                                    "baseUrl": "https://api.moonshot.ai/v1",
                                    "api": "openai-completions",
                                    "apiKey": "__OPENCLAW_REDACTED__"
                                ],
                                "kimi-coding": [
                                    "baseUrl": "https://api.kimi.com/coding",
                                    "api": "anthropic-messages",
                                    "apiKey": "__OPENCLAW_REDACTED__"
                                ]
                            ]
                        ]
                    ]
                ])
            case "sessions.patch":
                return try encodeJSONObject(["ok": true, "key": "agent:main:moonshot-thinking"])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:moonshot-thinking",
                            "displayName": "Moonshot Thinking",
                            "updatedAt": 1_808_345_600_000.0,
                            "model": "moonshot/kimi-k2-thinking"
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }
        let manager = OpenClawSessionManager(connection: connection)

        let key = try await manager.createSession(model: "kimi-k2-thinking")
        #expect(key == "agent:main:moonshot-thinking")

        let calls = await recorder.all()
        #expect(calls.count == 3)
        #expect(calls[0].method == "config.get")
        #expect(calls[1].method == "sessions.patch")
        #expect(calls[1].params?["model"]?.value as? String == "moonshot/kimi-k2-thinking")
        #expect(calls[2].method == "sessions.list")
    }

    @Test @MainActor
    func createSession_bareKimiThinkingModel_fallsBackToKimiCodingK2p5WhenMoonshotMissing() async throws {
        let recorder = OpenClawSessionManagerCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.append(method: method, params: params)
            switch method {
            case "config.get":
                return try encodeJSONObject([
                    "config": [
                        "models": [
                            "providers": [
                                "kimi-coding": [
                                    "baseUrl": "https://api.kimi.com/coding",
                                    "api": "anthropic-messages",
                                    "apiKey": "__OPENCLAW_REDACTED__"
                                ]
                            ]
                        ]
                    ]
                ])
            case "sessions.patch":
                return try encodeJSONObject(["ok": true, "key": "agent:main:kimi-coding-k2p5-thinking-fallback"])
            case "sessions.list":
                return try encodeJSONObject([
                    "sessions": [
                        [
                            "key": "agent:main:kimi-coding-k2p5-thinking-fallback",
                            "displayName": "Kimi Coding",
                            "updatedAt": 1_808_345_600_000.0,
                            "model": "kimi-coding/k2p5"
                        ]
                    ]
                ])
            default:
                return try encodeJSONObject([:])
            }
        }
        let manager = OpenClawSessionManager(connection: connection)

        let key = try await manager.createSession(model: "kimi-k2-thinking")
        #expect(key == "agent:main:kimi-coding-k2p5-thinking-fallback")

        let calls = await recorder.all()
        #expect(calls.count == 3)
        #expect(calls[0].method == "config.get")
        #expect(calls[1].method == "sessions.patch")
        #expect(calls[1].params?["model"]?.value as? String == "kimi-coding/k2p5")
        #expect(calls[2].method == "sessions.list")
    }
}
