//
//  ContentBlock.swift
//  osaurus
//
//  Unified content block model for flattened chat rendering.
//  Uses stored `id` for efficient diffing in NSDiffableDataSource.
//

import Foundation

// MARK: - Supporting Types

/// Position of a block within its turn (for styling)
enum BlockPosition: Equatable {
    case only, first, middle, last
}

// MARK: - FileSummaryItem

enum FileOperation: String, Equatable {
    case created, modified, deleted
}

struct FileSummaryItem: Equatable {
    let path: String
    let operation: FileOperation
}

/// A tool call with its result for grouped rendering
struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?

    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result
    }
}

/// The kind/type of a content block
enum ContentBlockKind: Equatable {
    case header(role: MessageRole, agentName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool, duration: TimeInterval?)
    case clarification(request: ClarificationRequest)
    case userMessage(text: String, images: [Data])
    case typingIndicator
    case groupSpacer
    case activityGroup(thinkingText: String, thinkingIsStreaming: Bool, thinkingDuration: TimeInterval?, calls: [ToolCallItem])
    case fileSummary(files: [FileSummaryItem])

    /// Custom Equatable optimized for performance during streaming.
    /// Uses text length comparison as a cheap proxy for content change detection.
    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lRole, lName, lFirst), .header(rRole, rName, rFirst)):
            return lRole == rRole && lName == rName && lFirst == rFirst

        case let (.paragraph(lIdx, lText, lStream, lRole), .paragraph(rIdx, rText, rStream, rRole)):
            // Compare text length first (O(1)) - if lengths differ, content changed
            // Only do full comparison if lengths are equal (rare during streaming)
            guard lIdx == rIdx && lStream == rStream && lRole == rRole else { return false }
            guard lText.count == rText.count else { return false }
            return lText == rText

        case let (.toolCallGroup(lCalls), .toolCallGroup(rCalls)):
            return lCalls == rCalls

        case let (.thinking(lIdx, lText, lStream, lDur), .thinking(rIdx, rText, rStream, rDur)):
            // Same optimization as paragraph
            guard lIdx == rIdx && lStream == rStream && lDur == rDur else { return false }
            guard lText.count == rText.count else { return false }
            return lText == rText

        case let (.clarification(lRequest), .clarification(rRequest)):
            return lRequest == rRequest

        case let (.userMessage(lText, lImages), .userMessage(rText, rImages)):
            guard lText.count == rText.count else { return false }
            guard lImages.count == rImages.count else { return false }
            return lText == rText && lImages == rImages

        case (.typingIndicator, .typingIndicator):
            return true

        case (.groupSpacer, .groupSpacer):
            return true

        case let (.activityGroup(lThink, lStream, lDur, lCalls),
                  .activityGroup(rThink, rStream, rDur, rCalls)):
            guard lStream == rStream && lDur == rDur && lCalls == rCalls else { return false }
            guard lThink.count == rThink.count else { return false }
            return lThink == rThink

        case let (.fileSummary(lFiles), .fileSummary(rFiles)):
            return lFiles == rFiles

        default:
            return false
        }
    }
}

// MARK: - ContentBlock

/// A single content block in the flattened chat view.
struct ContentBlock: Identifiable, Equatable, Hashable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind
    var position: BlockPosition

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCallGroup, .thinking, .clarification, .typingIndicator, .groupSpacer, .activityGroup, .fileSummary:
            return .assistant
        case .userMessage: return .user
        }
    }

    static func == (lhs: ContentBlock, rhs: ContentBlock) -> Bool {
        // Check id first (cheapest), then position, then kind (most expensive)
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.kind == rhs.kind
    }

    /// Hash on `id` only — used by NSDiffableDataSource for item identity.
    /// Content equality is handled separately by the Equatable conformance.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func withPosition(_ newPosition: BlockPosition) -> ContentBlock {
        ContentBlock(id: id, turnId: turnId, kind: kind, position: newPosition)
    }

    // MARK: - Factory Methods

    static func header(
        turnId: UUID,
        role: MessageRole,
        agentName: String,
        isFirstInGroup: Bool,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "header-\(turnId.uuidString)",
            turnId: turnId,
            kind: .header(role: role, agentName: agentName, isFirstInGroup: isFirstInGroup),
            position: position
        )
    }

    static func paragraph(
        turnId: UUID,
        index: Int,
        text: String,
        isStreaming: Bool,
        role: MessageRole,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "para-\(turnId.uuidString)-\(index)",
            turnId: turnId,
            kind: .paragraph(index: index, text: text, isStreaming: isStreaming, role: role),
            position: position
        )
    }

    static func toolCallGroup(turnId: UUID, calls: [ToolCallItem], position: BlockPosition) -> ContentBlock {
        ContentBlock(
            // Keep ID stable per turn so expansion state and row identity survive
            // incremental tool-call updates while a turn is streaming.
            id: "toolgroup-\(turnId.uuidString)",
            turnId: turnId,
            kind: .toolCallGroup(calls: calls),
            position: position
        )
    }

    static func thinking(turnId: UUID, index: Int, text: String, isStreaming: Bool, duration: TimeInterval? = nil, position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "think-\(turnId.uuidString)-\(index)",
            turnId: turnId,
            kind: .thinking(index: index, text: text, isStreaming: isStreaming, duration: duration),
            position: position
        )
    }

    static func clarification(turnId: UUID, request: ClarificationRequest, position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "clarification-\(turnId.uuidString)",
            turnId: turnId,
            kind: .clarification(request: request),
            position: position
        )
    }

    static func userMessage(turnId: UUID, text: String, images: [Data], position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "usermsg-\(turnId.uuidString)",
            turnId: turnId,
            kind: .userMessage(text: text, images: images),
            position: position
        )
    }

    static func typingIndicator(turnId: UUID, position: BlockPosition) -> ContentBlock {
        ContentBlock(id: "typing-\(turnId.uuidString)", turnId: turnId, kind: .typingIndicator, position: position)
    }

    static func groupSpacer(afterTurnId: UUID, associatedWithTurnId: UUID? = nil) -> ContentBlock {
        let turnId = associatedWithTurnId ?? afterTurnId
        return ContentBlock(id: "spacer-\(afterTurnId.uuidString)", turnId: turnId, kind: .groupSpacer, position: .only)
    }

    static func activityGroup(
        turnId: UUID,
        thinkingText: String,
        thinkingIsStreaming: Bool,
        thinkingDuration: TimeInterval?,
        calls: [ToolCallItem],
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "activity-\(turnId.uuidString)",
            turnId: turnId,
            kind: .activityGroup(
                thinkingText: thinkingText,
                thinkingIsStreaming: thinkingIsStreaming,
                thinkingDuration: thinkingDuration,
                calls: calls
            ),
            position: position
        )
    }

    static func fileSummary(turnId: UUID, files: [FileSummaryItem], position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "filesummary-\(turnId.uuidString)",
            turnId: turnId,
            kind: .fileSummary(files: files),
            position: position
        )
    }
}

// MARK: - Block Generation

extension ContentBlock {
    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        previousTurn: ChatTurn? = nil,
        suppressAssistantText: Bool = false
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole? = previousTurn?.role
        var previousTurnId: UUID? = previousTurn?.id

        let filteredTurns = turns.filter { $0.role != .tool }

        for turn in filteredTurns {
            let isStreaming = turn.id == streamingTurnId
            // User messages always start a new group (each is distinct input).
            // Assistant messages group consecutive turns (continuing responses).
            let isFirstInGroup = turn.role != previousRole || turn.role == .user

            if isFirstInGroup, let prevId = previousTurnId {
                // Use the previous turn ID for the stable block ID (referencing the gap)
                // BUT associate it with the current turn ID so it gets regenerated/included with the current turn during incremental updates
                blocks.append(.groupSpacer(afterTurnId: prevId, associatedWithTurnId: turn.id))
            }

            // User messages are emitted as a single unified block
            if turn.role == .user {
                blocks.append(
                    .userMessage(
                        turnId: turn.id,
                        text: turn.content,
                        images: turn.attachedImages,
                        position: .only
                    )
                )
                previousRole = turn.role
                previousTurnId = turn.id
                continue
            }

            var turnBlocks: [ContentBlock] = []

            if isFirstInGroup {
                turnBlocks.append(
                    .header(
                        turnId: turn.id,
                        role: turn.role,
                        agentName: agentName,
                        isFirstInGroup: true,
                        position: .first
                    )
                )
            }

            // Add clarification block if pending (work mode)
            if let clarification = turn.pendingClarification {
                turnBlocks.append(
                    .clarification(
                        turnId: turn.id,
                        request: clarification,
                        position: .middle
                    )
                )
            }

            // Unified activity group: when a turn has BOTH thinking AND tool calls,
            // emit a single .activityGroup that renders them as a cohesive stream.
            // Otherwise, emit .thinking and .toolCallGroup separately.
            let hasToolCalls = !(turn.toolCalls ?? []).isEmpty

            if turn.hasThinking && hasToolCalls {
                // Combined thinking + tools → unified .activityGroup
                let items = turn.toolCalls!.map { ToolCallItem(call: $0, result: turn.toolResults[$0.id]) }
                turnBlocks.append(
                    .activityGroup(
                        turnId: turn.id,
                        thinkingText: turn.thinking,
                        thinkingIsStreaming: isStreaming && turn.contentIsEmpty,
                        thinkingDuration: nil,
                        calls: items,
                        position: .middle
                    )
                )
            } else {
                // Thinking only (no tool calls yet)
                if turn.hasThinking {
                    turnBlocks.append(
                        .thinking(
                            turnId: turn.id,
                            index: 0,
                            text: turn.thinking,
                            isStreaming: isStreaming && turn.contentIsEmpty,
                            duration: nil,
                            position: .middle
                        )
                    )
                }
            }

            let shouldSuppressParagraph = suppressAssistantText && turn.role == .assistant
            if !turn.contentIsEmpty && !shouldSuppressParagraph {
                turnBlocks.append(
                    .paragraph(
                        turnId: turn.id,
                        index: 0,
                        text: turn.content,
                        isStreaming: isStreaming,
                        role: turn.role,
                        position: .middle
                    )
                )
            } else if isStreaming && !turn.hasThinking && !hasToolCalls && !shouldSuppressParagraph {
                turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
            }

            // Tool calls without thinking → standalone .toolCallGroup
            // (preserves ParallelGroupRow for multiple parallel calls)
            if hasToolCalls && !turn.hasThinking {
                let items = turn.toolCalls!.map { ToolCallItem(call: $0, result: turn.toolResults[$0.id]) }
                turnBlocks.append(.toolCallGroup(turnId: turn.id, calls: items, position: .middle))
            }

            // Emit file summary when a turn contains >=2 file-mutation tool calls
            let fileSummaryItems = Self.extractFileSummaryItems(from: turn)
            if fileSummaryItems.count >= 2 {
                turnBlocks.append(.fileSummary(turnId: turn.id, files: fileSummaryItems, position: .middle))
            }

            blocks.append(contentsOf: assignPositions(to: turnBlocks))
            previousRole = turn.role
            previousTurnId = turn.id
        }

        return blocks
    }

    // MARK: - File Summary Extraction

    private static let fileMutationPatterns = [
        "write", "create", "edit", "patch", "str_replace",
        "delete", "rm", "move", "rename", "copy",
    ]

    private static func extractFileSummaryItems(from turn: ChatTurn) -> [FileSummaryItem] {
        guard let toolCalls = turn.toolCalls else { return [] }
        return toolCalls.compactMap { call in
            let name = call.function.name.lowercased()
            guard fileMutationPatterns.contains(where: { name.contains($0) }) else { return nil }
            guard let data = call.function.arguments.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let path = json["path"] as? String ?? json["file"] as? String ?? json["file_path"] as? String
            else { return nil }
            let op: FileOperation =
                name.contains("delete") || name.contains("rm") ? .deleted
                : name.contains("create") || name.contains("write") ? .created
                : .modified
            return FileSummaryItem(path: path, operation: op)
        }
    }

    private static func assignPositions(to blocks: [ContentBlock]) -> [ContentBlock] {
        guard !blocks.isEmpty else { return blocks }
        return blocks.enumerated().map { index, block in
            let position: BlockPosition =
                blocks.count == 1 ? .only : (index == 0 ? .first : (index == blocks.count - 1 ? .last : .middle))
            return block.withPosition(position)
        }
    }

}
