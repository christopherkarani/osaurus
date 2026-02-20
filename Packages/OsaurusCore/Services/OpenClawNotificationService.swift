//
//  OpenClawNotificationService.swift
//  osaurus
//

import AppKit
import Foundation
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

    private init() {}

    public func startListening() {
        guard NSApp != nil else { return }
        guard pollTask == nil else { return }

        listeningStartedAt = Date()
        registerCategory()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollAndProcessStatus()
                await self.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    public func stopListening() {
        pollTask?.cancel()
        pollTask = nil
        listeningStartedAt = nil
        unreadCount = 0
        setDockBadge(nil)
    }

    public func markAllAsRead() {
        // Product policy: unread changes only through explicit clear actions.
        unreadCount = 0
        setDockBadge(nil)
    }

    public func ingestStatus(_ status: ChannelsStatusResult) {
        process(status)
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

                let key = "\(channelId)::\(account.accountId)"
                if let previous = lastInboundByAccount[key], previous >= inbound {
                    continue
                }

                if shouldNotifyForInboundEvent(previous: lastInboundByAccount[key], inbound: inbound) {
                    unreadCount += 1
                    let sender = normalized(account.name) ?? account.accountId
                    let title = "\(channelLabel) - \(sender)"
                    let body = String("New inbound message received.".prefix(100))
                    postNotification(channelId: channelId, title: title, body: body)
                    setDockBadge(unreadCount > 0 ? "\(unreadCount)" : nil)
                }

                lastInboundByAccount[key] = inbound
            }
        }
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

#if DEBUG
    func _testReset() {
        stopListening()
        lastInboundByAccount = [:]
        listeningStartedAt = nil
    }

    func _testSetListeningStartedAt(_ value: Date?) {
        listeningStartedAt = value
    }

    static func _testSetHooks(_ hooks: Hooks?) {
        testHooks = hooks
    }
#endif
}
