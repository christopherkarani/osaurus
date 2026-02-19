//
//  OpenClawActivityModels.swift
//  osaurus
//
//  Data models for the OpenClaw agent event pipeline.
//  Represents typed activity items parsed from gateway EventFrame payloads.
//

import Foundation

// MARK: - Core Types

/// A single activity item in the OpenClaw agent event timeline
public struct ActivityItem: Identifiable {
    public let id: UUID
    public let timestamp: Date
    public var kind: ActivityKind
}

/// The type of activity represented by an ActivityItem
public enum ActivityKind {
    case toolCall(ToolCallActivity)
    case thinking(ThinkingActivity)
    case assistant(AssistantActivity)
    case compaction(CompactionActivity)
    case lifecycle(LifecycleActivity)
    // Note: No dedicated "error" case. Agent errors surface via
    // lifecycle(.error(msg)) — see processLifecycle handler.
}

/// Status of an activity (used primarily for tool calls)
public enum ActivityStatus: Equatable {
    case pending
    case running
    case completed
    case failed
}

// MARK: - Tool Call Activity

/// Represents a tool invocation with start → update → result lifecycle
public struct ToolCallActivity {
    public let toolCallId: String
    public let name: String
    public var status: ActivityStatus
    public var args: [String: String]
    public var argsSummary: String
    public var result: String?
    public var resultSize: String?
    public var isError: Bool
    public var duration: TimeInterval?
    public let startedAt: Date

    public init(toolCallId: String, name: String, args: [String: Any], startedAt: Date) {
        self.toolCallId = toolCallId
        self.name = name
        self.status = .running
        self.args = Self.flattenArgs(args)
        self.argsSummary = Self.summarizeArgs(name: name, args: args)
        self.result = nil
        self.resultSize = nil
        self.isError = false
        self.duration = nil
        self.startedAt = startedAt
    }

    static func flattenArgs(_ args: [String: Any]) -> [String: String] {
        args.reduce(into: [:]) { result, pair in
            if let str = pair.value as? String {
                result[pair.key] = str
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
    }

    static func summarizeArgs(name: String, args: [String: Any]) -> String {
        let lowered = name.lowercased()
        if lowered.contains("read") || lowered.contains("write") || lowered.contains("edit") {
            return (args["path"] as? String) ?? (args["file_path"] as? String) ?? ""
        } else if lowered.contains("bash") || lowered.contains("exec") {
            return String(((args["command"] as? String) ?? "").prefix(80))
        } else if lowered.contains("glob") {
            return (args["pattern"] as? String) ?? ""
        } else if lowered.contains("grep") || lowered.contains("search") {
            return (args["pattern"] as? String) ?? (args["query"] as? String) ?? ""
        }
        if let first = args.first(where: { $0.value is String }) {
            return "\(first.key): \(first.value)"
        }
        return ""
    }
}

// MARK: - Thinking Activity

/// Represents an extended thinking block with delta accumulation
public struct ThinkingActivity {
    public var text: String
    public var isStreaming: Bool
    public var duration: TimeInterval?
    public let startedAt: Date
}

// MARK: - Assistant Activity

/// Represents assistant text output with delta accumulation
public struct AssistantActivity {
    public var text: String
    public var isStreaming: Bool
    public var mediaUrls: [String]
    public let startedAt: Date
}

// MARK: - Compaction Activity

/// Represents a context compaction event
public struct CompactionActivity {
    public enum Phase: Equatable {
        case started
        case ended
        case willRetry
    }

    public var phase: Phase
}

// MARK: - Lifecycle Activity

/// Represents agent run lifecycle events (start, end, error)
public struct LifecycleActivity {
    public enum Phase: Equatable {
        case started
        case ended
        case error(String)
    }

    public var phase: Phase
    public let runId: String
}
