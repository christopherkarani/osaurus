//
//  OpenClawNotificationService.swift
//  osaurus
//

import AppKit
import Foundation
import OpenClawKit
import OpenClawProtocol
import UserNotifications

@MainActor
public final class OpenClawNotificationService {
    public static let shared = OpenClawNotificationService()

    struct Hooks {
        var fetchStatus: @Sendable () async throws -> ChannelsStatusResult
        var postNotification: @MainActor (_ channelId: String, _ title: String, _ body: String) -> Void
        var setDockBadge: @MainActor (_ value: String?) -> Void
        var sleep: @Sendable (_ nanoseconds: UInt64) async -> Void
    }

    nonisolated(unsafe) static var testHooks: Hooks?

    private let categoryId = "OPENCLAW_MESSAGE"
    private var pollTask: Task<Void, Never>?
    private var lastInboundByAccount: [String: Date] = [:]
    private var unreadCount = 0
    private var listeningStartedAt: Date?
    public private(set) var isPaused = false

    private init() {}

    public func startListening() {
        guard NSApp != nil else { return }
        guard pollTask == nil else { return }

        listeningStartedAt = Date()
        isPaused = false
        registerCategory()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.isPaused {
                    await self.sleep(nanoseconds: 500_000_000)
                    continue
                }
                await self.pollAndProcessStatus()
                await self.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    public func stopListening() {
        pollTask?.cancel()
        pollTask = nil
        listeningStartedAt = nil
        isPaused = false
    }

    public func pauseListening() {
        isPaused = true
    }

    public func resumeListening() {
        isPaused = false
    }

    public func markAllAsRead() {
        // Product policy: unread changes only through explicit clear actions.
        unreadCount = 0
        setDockBadge(nil)
    }

    public func ingestStatus(_ status: ChannelsStatusResult) {
        process(status)
    }

    public func ingestEvent(_ frame: EventFrame) {
        guard listeningStartedAt != nil else { return }
        guard let inbound = decodeInboundEvent(frame) else { return }
        processInbound(
            channelId: inbound.channelId,
            accountId: inbound.accountId,
            channelLabel: inbound.channelLabel,
            sender: inbound.sender,
            inboundAt: inbound.inboundAt,
            body: inbound.body
        )
    }

    private func pollAndProcessStatus() async {
        do {
            let status = try await fetchStatus()
            process(status)
        } catch {
            // Ignore transient gateway polling failures.
        }
    }

    private func process(_ status: ChannelsStatusResult) {
        for (channelId, accounts) in status.channelAccounts {
            let channelLabel = status.channelLabels[channelId] ?? channelId.capitalized
            for account in accounts {
                guard account.linked || account.connected || account.running else { continue }
                guard let inbound = account.lastInboundAt else { continue }
                processInbound(
                    channelId: channelId,
                    accountId: account.accountId,
                    channelLabel: channelLabel,
                    sender: normalized(account.name) ?? account.accountId,
                    inboundAt: inbound,
                    body: "New inbound message received."
                )
            }
        }
    }

    private struct InboundEvent {
        let channelId: String
        let accountId: String
        let channelLabel: String
        let sender: String
        let body: String
        let inboundAt: Date
    }

    private func decodeInboundEvent(_ frame: EventFrame) -> InboundEvent? {
        let eventName = frame.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard eventName.contains("inbound") || eventName.contains("message.in") else {
            return nil
        }

        guard let payload = frame.payload?.value as? [String: OpenClawProtocol.AnyCodable] else {
            return nil
        }

        let data = dictionaryValue(payload["data"]?.value)
        let channelId = normalized(
            stringValue(payload["channel"]?.value)
                ?? stringValue(payload["channelId"]?.value)
                ?? stringValue(payload["provider"]?.value)
                ?? stringValue(data?["channel"]?.value)
                ?? stringValue(data?["channelId"]?.value)
                ?? stringValue(data?["provider"]?.value)
        ) ?? "unknown"
        let channelLabel = normalized(
            stringValue(payload["channelLabel"]?.value)
                ?? stringValue(data?["channelLabel"]?.value)
                ?? channelId.capitalized
        ) ?? channelId.capitalized
        let accountId = normalized(
            stringValue(payload["accountId"]?.value)
                ?? stringValue(data?["accountId"]?.value)
                ?? stringValue(data?["account"]?.value)
                ?? "default"
        ) ?? "default"
        let sender = normalized(
            stringValue(payload["sender"]?.value)
                ?? stringValue(payload["from"]?.value)
                ?? stringValue(payload["name"]?.value)
                ?? stringValue(data?["sender"]?.value)
                ?? stringValue(data?["from"]?.value)
                ?? stringValue(data?["name"]?.value)
                ?? accountId
        ) ?? accountId
        let body = normalized(
            stringValue(payload["text"]?.value)
                ?? stringValue(payload["preview"]?.value)
                ?? stringValue(payload["body"]?.value)
                ?? stringValue(data?["text"]?.value)
                ?? stringValue(data?["preview"]?.value)
                ?? stringValue(data?["body"]?.value)
                ?? "New inbound message received."
        ) ?? "New inbound message received."

        let inboundAt = dateValue(
            payload["ts"]?.value
                ?? payload["timestamp"]?.value
                ?? data?["ts"]?.value
                ?? data?["timestamp"]?.value
                ?? data?["receivedAt"]?.value
        ) ?? Date()

        return InboundEvent(
            channelId: channelId,
            accountId: accountId,
            channelLabel: channelLabel,
            sender: sender,
            body: body,
            inboundAt: inboundAt
        )
    }

    private func processInbound(
        channelId: String,
        accountId: String,
        channelLabel: String,
        sender: String,
        inboundAt: Date,
        body: String
    ) {
        let normalizedInbound = Date(
            timeIntervalSince1970: floor(inboundAt.timeIntervalSince1970 * 1000) / 1000
        )
        let key = "\(channelId)::\(accountId)"
        if let previous = lastInboundByAccount[key], previous >= normalizedInbound {
            return
        }

        if shouldNotifyForInboundEvent(previous: lastInboundByAccount[key], inbound: normalizedInbound) {
            unreadCount += 1
            let title = "\(channelLabel) - \(sender)"
            postNotification(
                channelId: channelId,
                title: title,
                body: String(body.prefix(100))
            )
            setDockBadge(unreadCount > 0 ? "\(unreadCount)" : nil)
        }

        lastInboundByAccount[key] = normalizedInbound
    }

    private func shouldNotifyForInboundEvent(previous: Date?, inbound: Date) -> Bool {
        if let previous {
            return inbound > previous
        }

        guard let listeningStartedAt else {
            return true
        }

        let startupGraceWindow: TimeInterval = 3
        return inbound >= listeningStartedAt.addingTimeInterval(-startupGraceWindow)
    }

    private func fetchStatus() async throws -> ChannelsStatusResult {
        if let hooks = Self.testHooks {
            return try await hooks.fetchStatus()
        }
        return try await OpenClawGatewayConnection.shared.channelsStatusDetailed()
    }

    private func postNotification(channelId: String, title: String, body: String) {
        if let hooks = Self.testHooks {
            hooks.postNotification(channelId, title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryId
        content.threadIdentifier = channelId

        let request = UNNotificationRequest(
            identifier: "openclaw-msg-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func setDockBadge(_ value: String?) {
        if let hooks = Self.testHooks {
            hooks.setDockBadge(value)
            return
        }
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = value
    }

    private func sleep(nanoseconds: UInt64) async {
        if let hooks = Self.testHooks {
            await hooks.sleep(nanoseconds)
            return
        }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func registerCategory() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { [categoryId] existing in
            var next = existing
            let category = UNNotificationCategory(
                identifier: categoryId,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
            next.insert(category)
            center.setNotificationCategories(next)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func stringValue(_ raw: Any?) -> String? {
        if let raw = raw as? String {
            return raw
        }
        return nil
    }

    private func dictionaryValue(_ raw: Any?) -> [String: OpenClawProtocol.AnyCodable]? {
        if let raw = raw as? [String: OpenClawProtocol.AnyCodable] {
            return raw
        }
        return nil
    }

    private func dateValue(_ raw: Any?) -> Date? {
        if let value = raw as? Date {
            return value
        }
        if let value = raw as? TimeInterval, value > 0 {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        if let value = raw as? Int, value > 0 {
            let asDouble = Double(value)
            return Date(timeIntervalSince1970: asDouble > 10_000_000_000 ? asDouble / 1000 : asDouble)
        }
        if let value = raw as? Double, value > 0 {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        if let value = raw as? String,
            let numeric = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
            numeric > 0
        {
            return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1000 : numeric)
        }
        return nil
    }

#if DEBUG
    func _testReset() {
        stopListening()
        lastInboundByAccount = [:]
        unreadCount = 0
        setDockBadge(nil)
        listeningStartedAt = nil
        isPaused = false
    }

    func _testSetListeningStartedAt(_ value: Date?) {
        listeningStartedAt = value
    }

    static func _testSetHooks(_ hooks: Hooks?) {
        testHooks = hooks
    }
#endif
}
