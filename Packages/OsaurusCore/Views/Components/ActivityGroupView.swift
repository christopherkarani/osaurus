//
//  ActivityGroupView.swift
//  osaurus
//
//  Unified view for .activityGroup ContentBlockKind.
//  Renders thinking + tool calls as a flat chronological stream.
//  No outer card — each row is independently expandable.
//

import SwiftUI

struct ActivityGroupView: View {
    let thinkingText: String
    let thinkingIsStreaming: Bool
    let thinkingDuration: TimeInterval?
    let calls: [ToolCallItem]
    let blockId: String

    var onRedirect: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @EnvironmentObject private var expandedStore: ExpandedBlocksStore

    private var hasActive: Bool {
        thinkingIsStreaming || calls.contains { $0.result == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thinking row (if present)
            if !thinkingText.isEmpty {
                ThinkingTraceView(
                    thinking: thinkingText,
                    baseWidth: 0,
                    isStreaming: thinkingIsStreaming,
                    duration: thinkingDuration,
                    blockId: "\(blockId)-thinking"
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
            }

            // Tool action rows
            ForEach(Array(calls.enumerated()), id: \.element.call.id) { index, item in
                ToolActionRow(
                    call: item.call,
                    result: item.result,
                    blockId: blockId,
                    isGroupActive: hasActive,
                    onRedirect: onRedirect
                )
                // 2pt gap after thinking (causal clustering), 2pt between tools
                .padding(.top, index == 0 && !thinkingText.isEmpty ? 2 : (index > 0 ? 2 : 0))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: calls.count)
    }
}

// MARK: - Preview

#if DEBUG
struct ActivityGroupView_Previews: PreviewProvider {
    static var previews: some View {
        let calls: [ToolCallItem] = [
            ToolCallItem(
                call: ToolCall(
                    id: "1",
                    type: "function",
                    function: ToolCallFunction(
                        name: "read_file",
                        arguments: "{\"path\": \"/src/main.swift\"}"
                    )
                ),
                result: "import Foundation\nfunc main() { print(\"hello\") }"
            ),
            ToolCallItem(
                call: ToolCall(
                    id: "2",
                    type: "function",
                    function: ToolCallFunction(
                        name: "bash",
                        arguments: "{\"command\": \"swift build\"}"
                    )
                ),
                result: nil
            ),
        ]
        ScrollView {
            ActivityGroupView(
                thinkingText: "Let me read the file and then build the project.",
                thinkingIsStreaming: false,
                thinkingDuration: 2.3,
                calls: calls,
                blockId: "preview-activity"
            )
            .padding()
        }
        .frame(width: 600, height: 400)
        .background(Color(hex: "0c0c0b"))
        .environmentObject(ExpandedBlocksStore())
    }
}
#endif
