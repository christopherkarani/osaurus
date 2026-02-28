//
//  TraceTreeStabilityTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Trace Tree Stability")
struct TraceTreeStabilityTests {
    @Test
    func activityGroupId_remainsStableWhenCallsAppend() {
        let turn = ChatTurn(role: .assistant, content: "")
        let call1 = makeToolCall(id: "call-1", name: "read_file")
        let call2 = makeToolCall(id: "call-2", name: "write_file")

        turn.toolCalls = [call1]
        turn.toolResults = [call1.id: "ok"]

        let blocksBefore = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: turn.id,
            agentName: "Work"
        )
        let activityBlockBefore = blocksBefore.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        turn.toolCalls = [call1, call2]
        turn.toolResults = [call1.id: "ok", call2.id: "ok"]

        let blocksAfter = ContentBlock.generateBlocks(
            from: [turn],
            streamingTurnId: turn.id,
            agentName: "Work"
        )
        let activityBlockAfter = blocksAfter.first { block in
            if case .activityGroup = block.kind { return true }
            return false
        }

        // Block ID must remain stable as tool calls are appended
        #expect(activityBlockBefore?.id == activityBlockAfter?.id)
        #expect(activityBlockAfter?.id == "activity-\(turn.id.uuidString)")
    }

    @Test
    func blockMemoizer_keepsLongerStreamingTraceWindow() {
        let memoizer = BlockMemoizer()
        let turns = (0..<180).map { index in
            ChatTurn(role: .assistant, content: "streaming-turn-\(index)")
        }

        let blocks = memoizer.blocks(
            from: turns,
            streamingTurnId: turns.last?.id,
            agentName: "Work"
        )

        // Regression guard: trace-heavy streaming should not collapse to a tiny tail.
        #expect(blocks.count >= 180)
    }

    private func makeToolCall(id: String, name: String) -> ToolCall {
        ToolCall(
            id: id,
            type: "function",
            function: ToolCallFunction(
                name: name,
                arguments: "{}"
            )
        )
    }
}
