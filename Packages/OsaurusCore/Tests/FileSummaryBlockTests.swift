//
//  FileSummaryBlockTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("FileSummary Block")
struct FileSummaryBlockTests {

    private func makeFileMutationTurn(toolNames: [String], turnId: UUID = UUID()) -> ChatTurn {
        let turn = ChatTurn(role: .assistant, content: "Done.", id: turnId)
        turn.toolCalls = toolNames.enumerated().map { idx, name in
            ToolCall(
                id: "c\(idx)",
                type: "function",
                function: ToolCallFunction(name: name, arguments: "{\"path\": \"/src/file\(idx).swift\"}")
            )
        }
        for idx in toolNames.indices {
            turn.toolResults["c\(idx)"] = "ok"
        }
        return turn
    }

    @Test func fileSummaryEmittedAfterTwoFileMutations() {
        let turn = makeFileMutationTurn(toolNames: ["write_file", "edit_file"])
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let hasSummary = blocks.contains { if case .fileSummary = $0.kind { return true }; return false }
        #expect(hasSummary == true)
    }

    @Test func fileSummaryNotEmittedForSingleFileMutation() {
        let turn = makeFileMutationTurn(toolNames: ["write_file"])
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let hasSummary = blocks.contains { if case .fileSummary = $0.kind { return true }; return false }
        #expect(hasSummary == false)
    }

    @Test func fileSummaryNotEmittedForNonFileTool() {
        let turn = makeFileMutationTurn(toolNames: ["bash", "search_web"])
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let hasSummary = blocks.contains { if case .fileSummary = $0.kind { return true }; return false }
        #expect(hasSummary == false)
    }

    @Test func fileSummaryContainsCorrectFileCount() {
        let turn = makeFileMutationTurn(toolNames: ["write_file", "edit_file", "create_file"])
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let summaryBlock = blocks.first { if case .fileSummary = $0.kind { return true }; return false }
        if case .fileSummary(let files) = summaryBlock?.kind {
            #expect(files.count == 3)
        } else {
            Issue.record("No fileSummary block found")
        }
    }

    @Test func fileSummaryExtractsCorrectPaths() {
        let turn = ChatTurn(role: .assistant, content: "Done.")
        turn.toolCalls = [
            ToolCall(id: "c0", type: "function", function: ToolCallFunction(name: "write_file", arguments: "{\"path\": \"/src/main.swift\"}")),
            ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "edit_file", arguments: "{\"file_path\": \"/src/utils.swift\"}")),
        ]
        turn.toolResults = ["c0": "ok", "c1": "ok"]

        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let summaryBlock = blocks.first { if case .fileSummary = $0.kind { return true }; return false }
        if case .fileSummary(let files) = summaryBlock?.kind {
            #expect(files.count == 2)
            #expect(files[0].path == "/src/main.swift")
            #expect(files[0].operation == .created)
            #expect(files[1].path == "/src/utils.swift")
            #expect(files[1].operation == .modified)
        } else {
            Issue.record("No fileSummary block found")
        }
    }

    @Test func fileSummaryDetectsDeleteOperation() {
        let turn = ChatTurn(role: .assistant, content: "Done.")
        turn.toolCalls = [
            ToolCall(id: "c0", type: "function", function: ToolCallFunction(name: "delete_file", arguments: "{\"path\": \"/src/old.swift\"}")),
            ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "rm_file", arguments: "{\"path\": \"/src/obsolete.swift\"}")),
        ]
        turn.toolResults = ["c0": "ok", "c1": "ok"]

        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let summaryBlock = blocks.first { if case .fileSummary = $0.kind { return true }; return false }
        if case .fileSummary(let files) = summaryBlock?.kind {
            #expect(files.count == 2)
            #expect(files[0].operation == .deleted)
            #expect(files[1].operation == .deleted)
        } else {
            Issue.record("No fileSummary block found")
        }
    }

    @Test func fileSummaryRoleIsAssistant() {
        let turn = makeFileMutationTurn(toolNames: ["write_file", "edit_file"])
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let summaryBlock = blocks.first { if case .fileSummary = $0.kind { return true }; return false }
        #expect(summaryBlock?.role == .assistant)
    }

    @Test func fileSummaryIdIsDeterministic() {
        let turnId = UUID()
        let turn = makeFileMutationTurn(toolNames: ["write_file", "edit_file"], turnId: turnId)
        let blocks = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: nil,
            agentName: "Agent"
        )
        let summaryBlock = blocks.first { if case .fileSummary = $0.kind { return true }; return false }
        #expect(summaryBlock?.id == "filesummary-\(turnId.uuidString)")
    }

    @Test func fileSummaryEquatable() {
        let items1 = [FileSummaryItem(path: "/a.swift", operation: .created)]
        let items2 = [FileSummaryItem(path: "/a.swift", operation: .created)]
        let items3 = [FileSummaryItem(path: "/b.swift", operation: .modified)]

        let kind1 = ContentBlockKind.fileSummary(files: items1)
        let kind2 = ContentBlockKind.fileSummary(files: items2)
        let kind3 = ContentBlockKind.fileSummary(files: items3)

        #expect(kind1 == kind2)
        #expect(kind1 != kind3)
    }
}
