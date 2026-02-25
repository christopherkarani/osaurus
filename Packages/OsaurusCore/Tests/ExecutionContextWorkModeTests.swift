//
//  ExecutionContextWorkModeTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ExecutionContextWorkModeTests {
    @Test
    func prepare_workMode_ignoresNonOpenClawChatSelection() async {
        let context = ExecutionContext(
            mode: .work,
            agentId: UUID()
        )

        guard let workSession = context.workSession else {
            Issue.record("Expected work session to be created for work mode context")
            return
        }

        let baseline = workSession.selectedModel
        context.chatSession.selectedModel = "foundation"

        await context.prepare()

        #expect(workSession.selectedModel != "foundation")

        if let selected = workSession.selectedModel {
            #expect(
                selected.hasPrefix(OpenClawModelService.modelPrefix)
                    || selected.hasPrefix(OpenClawModelService.sessionPrefix)
            )
        } else {
            #expect(baseline == nil)
        }
    }

    @Test
    func prepare_workMode_preservesOpenClawChatSelection() async {
        let context = ExecutionContext(
            mode: .work,
            agentId: UUID()
        )

        guard let workSession = context.workSession else {
            Issue.record("Expected work session to be created for work mode context")
            return
        }

        context.chatSession.selectedModel = "openclaw-model:test-model"

        await context.prepare()

        #expect(workSession.selectedModel == "openclaw-model:test-model")
    }

    @Test
    func start_workMode_surfacesProviderReadinessFailureForHeadlessFlow() async {
        let manager = OpenClawManager.shared
        manager._testSetConnectionState(.disconnected, gatewayStatus: .running)

        let context = ExecutionContext(
            mode: .work,
            agentId: UUID()
        )

        context.chatSession.selectedModel = "openclaw-model:test-model"
        await context.prepare()

        do {
            try await context.start(prompt: "Run diagnostics")
            Issue.record("Expected headless work start to fail when OpenClaw is disconnected")
        } catch {
            #expect(error.localizedDescription.contains("OpenClaw gateway is not connected."))
            #expect(context.workSession?.errorMessage?.contains("OpenClaw gateway is not connected.") == true)
        }
    }
}
