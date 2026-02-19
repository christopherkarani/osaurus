//
//  ChatSessionOpenClawModeTests.swift
//  osaurusTests
//

import Foundation
import Testing
@testable import OsaurusCore

private struct RouterStubService: ModelService {
    let id: String
    let handledPrefixes: [String]

    func isAvailable() -> Bool { true }

    func handles(requestedModel: String?) -> Bool {
        guard let requestedModel else { return false }
        return handledPrefixes.contains { requestedModel.hasPrefix($0) }
    }

    func generateOneShot(
        messages _: [ChatMessage],
        parameters _: GenerationParameters,
        requestedModel _: String?
    ) async throws -> String {
        ""
    }

    func streamDeltas(
        messages _: [ChatMessage],
        parameters _: GenerationParameters,
        requestedModel _: String?,
        stopSequences _: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

struct ChatSessionOpenClawModeTests {
    @Test @MainActor
    func chatSession_helpersConvertSelectionAndRuntimeIdentifiers() async throws {
        let selected = ChatSession.openClawSelectionModelIdentifier(modelId: "claude-opus")
        #expect(selected == "openclaw-model:claude-opus")
        #expect(ChatSession.extractOpenClawModelId(from: selected) == "claude-opus")

        let runtime = ChatSession.openClawRuntimeModelIdentifier(sessionKey: "agent:main:test")
        #expect(runtime == "openclaw:agent:main:test")
        #expect(ChatSession.extractOpenClawSessionKey(from: runtime) == "agent:main:test")

        let session = ChatSession()
        session.openClawSessionKey = "agent:main:test"
        #expect(session.isOpenClawSession == true)
        #expect(session.runtimeOpenClawModelIdentifier() == "openclaw:agent:main:test")
    }

    @Test
    func modelRouter_resolvesOpenClawIdentifiersToGatewayService() async throws {
        let local = RouterStubService(id: "local", handledPrefixes: ["foundation"])
        let gateway = RouterStubService(id: "openclaw", handledPrefixes: ["openclaw:", "openclaw-model:"])

        let runtimeRoute = ModelServiceRouter.resolve(
            requestedModel: "openclaw:agent:main:abc",
            services: [local],
            remoteServices: [gateway]
        )
        switch runtimeRoute {
        case .service(let service, let effectiveModel):
            #expect(service.id == "openclaw")
            #expect(effectiveModel == "openclaw:agent:main:abc")
        case .none:
            Issue.record("Expected router to resolve OpenClaw runtime identifier")
        }

        let preSessionRoute = ModelServiceRouter.resolve(
            requestedModel: "openclaw-model:claude-opus",
            services: [local],
            remoteServices: [gateway]
        )
        switch preSessionRoute {
        case .service(let service, let effectiveModel):
            #expect(service.id == "openclaw")
            #expect(effectiveModel == "openclaw-model:claude-opus")
        case .none:
            Issue.record("Expected router to resolve OpenClaw pre-session identifier")
        }
    }

    @Test
    func chatSessionData_persistsOpenClawSessionKeyWithBackwardCompatibleDecode() async throws {
        let source = ChatSessionData(
            id: UUID(),
            title: "Gateway Session",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            selectedModel: "openclaw:agent:main:abc",
            turns: [],
            agentId: nil,
            openClawSessionKey: "agent:main:abc"
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: encoded)
        #expect(decoded.openClawSessionKey == "agent:main:abc")

        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Legacy",
          "createdAt": \(Int(Date().timeIntervalSince1970)),
          "updatedAt": \(Int(Date().timeIntervalSince1970)),
          "selectedModel": "foundation",
          "turns": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ChatSessionData.self, from: legacyJSON)
        #expect(legacy.openClawSessionKey == nil)
    }
}
