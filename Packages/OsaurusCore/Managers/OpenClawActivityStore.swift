//
//  OpenClawActivityStore.swift
//  osaurus
//
//  Observable store that transforms raw OpenClaw gateway EventFrame payloads
//  into typed, indexed ActivityItem arrays for UI consumption.
//

import Combine
import Foundation
import OpenClawKit
import OpenClawProtocol

// MARK: - OpenClawActivityStore

/// Subscribes to GatewayNodeSession events and maintains an ordered list of ActivityItems
@MainActor
public final class OpenClawActivityStore: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var items: [ActivityItem] = []
    @Published public private(set) var isRunActive: Bool = false
    @Published public private(set) var activeRunId: String?

    // MARK: - Indexes

    /// toolCallId → items array index for O(1) correlation
    private var toolCallIndex: [String: Int] = [:]
    /// Current thinking block index for O(1) delta accumulation
    private var activeThinkingIndex: Int?
    /// Current assistant block index for O(1) delta accumulation
    private var activeAssistantIndex: Int?

    // MARK: - Subscription

    private var subscriptionTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    deinit {
        let task = subscriptionTask
        task?.cancel()
    }
}

// MARK: - Subscription Lifecycle

extension OpenClawActivityStore {

    /// Begin consuming events from a gateway session
    public func subscribe(to session: GatewayNodeSession) {
        unsubscribe()
        subscriptionTask = Task { [weak self] in
            let stream = await session.subscribeServerEvents(bufferingNewest: 200)
            do {
                for await eventFrame in stream {
                    try Task.checkCancellation()
                    self?.processEventFrame(eventFrame)
                }
            } catch is CancellationError {
                // Expected on unsubscribe — clean exit
            } catch {}
        }
    }

    /// Stop consuming events
    public func unsubscribe() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    /// Clear all state — safe for session switching
    public func reset() {
        items.removeAll()
        toolCallIndex.removeAll()
        activeThinkingIndex = nil
        activeAssistantIndex = nil
        isRunActive = false
        activeRunId = nil
    }
}

// MARK: - Event Routing

extension OpenClawActivityStore {

    func processEventFrame(_ frame: EventFrame) {
        // IMPORTANT: AnyCodable decoder stores dicts as [String: AnyCodable], NOT [String: Any].
        // Casting to [String: Any] silently returns nil. Must cast to [String: AnyCodable]
        // and unwrap each field via .value.
        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable],
              let stream = payload["stream"]?.value as? String,
              let runId = payload["runId"]?.value as? String else { return }

        // ts can arrive as Double or Int depending on JSON decoder
        let ts: Double
        if let d = payload["ts"]?.value as? Double { ts = d }
        else if let i = payload["ts"]?.value as? Int { ts = Double(i) }
        else { return }

        let data = payload["data"]?.value as? [String: OpenClawProtocol.AnyCodable] ?? [:]
        let timestamp = Date(timeIntervalSince1970: ts / 1000.0)

        switch stream {
        case "lifecycle":  processLifecycle(runId: runId, data: data, at: timestamp)
        case "tool":       processTool(runId: runId, data: data, at: timestamp)
        case "thinking":   processThinking(data: data, at: timestamp)
        case "assistant":  processAssistant(data: data, at: timestamp)
        case "compaction": processCompaction(data: data, at: timestamp)
        default:           break  // Unknown streams silently ignored
        }
    }
}

// MARK: - Lifecycle Handler

extension OpenClawActivityStore {

    private func processLifecycle(runId: String, data: [String: OpenClawProtocol.AnyCodable], at timestamp: Date) {
        let phase = data["phase"]?.value as? String ?? ""

        switch phase {
        case "start":
            // Finalize any active streams from a previous run before starting a new one
            finalizeStreaming(at: timestamp)
            activeRunId = runId
            isRunActive = true
            items.append(ActivityItem(
                id: UUID(), timestamp: timestamp,
                kind: .lifecycle(LifecycleActivity(phase: .started, runId: runId))
            ))

        case "end":
            finalizeStreaming(at: timestamp)
            isRunActive = false
            items.append(ActivityItem(
                id: UUID(), timestamp: timestamp,
                kind: .lifecycle(LifecycleActivity(phase: .ended, runId: runId))
            ))

        case "error":
            finalizeStreaming(at: timestamp)
            isRunActive = false
            let msg = data["error"]?.value as? String ?? "Unknown error"
            items.append(ActivityItem(
                id: UUID(), timestamp: timestamp,
                kind: .lifecycle(LifecycleActivity(phase: .error(msg), runId: runId))
            ))

        default: break
        }
    }
}

// MARK: - Tool Handler

extension OpenClawActivityStore {

    private func processTool(runId: String, data: [String: OpenClawProtocol.AnyCodable], at timestamp: Date) {
        let phase = data["phase"]?.value as? String ?? ""
        guard let toolCallId = data["toolCallId"]?.value as? String else { return }

        switch phase {
        case "start":
            // A tool call interrupts any active thinking/assistant stream
            finalizeStreaming(at: timestamp)

            let name = data["name"]?.value as? String ?? "unknown"
            let args = data["args"]?.value as? [String: OpenClawProtocol.AnyCodable] ?? [:]
            let flatArgs = args.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.value }
            let activity = ToolCallActivity(
                toolCallId: toolCallId, name: name, args: flatArgs, startedAt: timestamp
            )
            let index = items.count
            toolCallIndex[toolCallId] = index
            items.append(ActivityItem(id: UUID(), timestamp: timestamp, kind: .toolCall(activity)))

        case "update":
            guard let index = toolCallIndex[toolCallId],
                  index < items.count,
                  case .toolCall(var activity) = items[index].kind else { return }
            if let partial = data["partialResult"]?.value {
                activity.result = stringifyResult(partial)
            }
            items[index].kind = .toolCall(activity)

        case "result":
            guard let index = toolCallIndex[toolCallId],
                  index < items.count,
                  case .toolCall(var activity) = items[index].kind else { return }

            let isError = data["isError"]?.value as? Bool ?? false
            activity.status = isError ? .failed : .completed
            activity.isError = isError
            activity.duration = timestamp.timeIntervalSince(activity.startedAt)
            if let result = data["result"]?.value { activity.result = stringifyResult(result) }
            if let meta = data["meta"]?.value as? String { activity.resultSize = meta }
            items[index].kind = .toolCall(activity)
            toolCallIndex.removeValue(forKey: toolCallId)

        default: break
        }
    }
}

// MARK: - Thinking Handler

extension OpenClawActivityStore {

    private func processThinking(data: [String: OpenClawProtocol.AnyCodable], at timestamp: Date) {
        let delta = data["delta"]?.value as? String ?? ""
        let fullText = data["text"]?.value as? String

        if let index = activeThinkingIndex,
           index < items.count,
           case .thinking(var activity) = items[index].kind {
            activity.text = fullText ?? (activity.text + delta)
            activity.isStreaming = true
            items[index].kind = .thinking(activity)
        } else {
            let activity = ThinkingActivity(
                text: fullText ?? delta, isStreaming: true, duration: nil, startedAt: timestamp
            )
            let item = ActivityItem(id: UUID(), timestamp: timestamp, kind: .thinking(activity))
            activeThinkingIndex = items.count
            items.append(item)
        }
    }
}

// MARK: - Assistant Handler

extension OpenClawActivityStore {

    private func processAssistant(data: [String: OpenClawProtocol.AnyCodable], at timestamp: Date) {
        let delta = data["delta"]?.value as? String ?? ""
        let fullText = data["text"]?.value as? String
        let mediaUrls = (data["mediaUrls"]?.value as? [OpenClawProtocol.AnyCodable])?.compactMap { $0.value as? String } ?? []

        if let index = activeAssistantIndex,
           index < items.count,
           case .assistant(var activity) = items[index].kind {
            activity.text = fullText ?? (activity.text + delta)
            activity.isStreaming = true
            if !mediaUrls.isEmpty { activity.mediaUrls.append(contentsOf: mediaUrls) }
            items[index].kind = .assistant(activity)
        } else {
            let activity = AssistantActivity(
                text: fullText ?? delta, isStreaming: true, mediaUrls: mediaUrls, startedAt: timestamp
            )
            let item = ActivityItem(id: UUID(), timestamp: timestamp, kind: .assistant(activity))
            activeAssistantIndex = items.count
            items.append(item)
        }
    }
}

// MARK: - Compaction Handler

extension OpenClawActivityStore {

    private func processCompaction(data: [String: OpenClawProtocol.AnyCodable], at timestamp: Date) {
        let phase = data["phase"]?.value as? String ?? ""
        let willRetry = data["willRetry"]?.value as? Bool ?? false

        let compactionPhase: CompactionActivity.Phase
        switch phase {
        case "start": compactionPhase = .started
        case "end":   compactionPhase = willRetry ? .willRetry : .ended
        default:      return
        }
        items.append(ActivityItem(
            id: UUID(), timestamp: timestamp,
            kind: .compaction(CompactionActivity(phase: compactionPhase))
        ))
    }
}

// MARK: - Stream Finalization

extension OpenClawActivityStore {

    /// Finalize active thinking and assistant streams (mark isStreaming = false, compute duration)
    private func finalizeStreaming(at timestamp: Date) {
        finalizeActiveThinking(at: timestamp)
        finalizeActiveAssistant(at: timestamp)
    }

    private func finalizeActiveThinking(at timestamp: Date) {
        guard let index = activeThinkingIndex,
              index < items.count,
              case .thinking(var activity) = items[index].kind else { return }
        activity.isStreaming = false
        activity.duration = timestamp.timeIntervalSince(activity.startedAt)
        items[index].kind = .thinking(activity)
        activeThinkingIndex = nil
    }

    private func finalizeActiveAssistant(at timestamp: Date) {
        guard let index = activeAssistantIndex,
              index < items.count,
              case .assistant(var activity) = items[index].kind else { return }
        activity.isStreaming = false
        items[index].kind = .assistant(activity)
        activeAssistantIndex = nil
    }
}

// MARK: - Result Stringification

extension OpenClawActivityStore {

    /// Convert heterogeneous tool result JSON into displayable text
    private func stringifyResult(_ value: Any) -> String {
        if let str = value as? String { return str }
        if let dict = value as? [String: OpenClawProtocol.AnyCodable] {
            if let contentArray = dict["content"]?.value as? [OpenClawProtocol.AnyCodable] {
                let texts = contentArray.compactMap { item -> String? in
                    guard let itemDict = item.value as? [String: OpenClawProtocol.AnyCodable] else { return nil }
                    return itemDict["text"]?.value as? String
                }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
            return dict.map { "\($0.key): \($0.value.value)" }.joined(separator: ", ")
        }
        if let arr = value as? [OpenClawProtocol.AnyCodable] {
            return arr.map { String(describing: $0.value) }.joined(separator: "\n")
        }
        return String(describing: value)
    }
}
