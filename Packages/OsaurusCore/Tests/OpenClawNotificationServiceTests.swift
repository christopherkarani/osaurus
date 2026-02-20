//
//  OpenClawNotificationServiceTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct OpenClawNotificationServiceTests {
    @Test
    func ingestStatus_postsNotificationForFirstFreshInboundEvent() {
        let service = OpenClawNotificationService.shared
        var notifications: [(String, String, String)] = []
        var badge: String?

        OpenClawNotificationService._testSetHooks(
            .init(
                fetchStatus: { Self.makeStatus(lastInboundAt: Date()) },
                postNotification: { channelId, title, body in
                    notifications.append((channelId, title, body))
                },
                setDockBadge: { value in
                    badge = value
                },
                sleep: { _ in }
            )
        )
        defer {
            OpenClawNotificationService._testSetHooks(nil)
            service._testReset()
        }

        service.ingestStatus(Self.makeStatus(lastInboundAt: Date()))
        #expect(notifications.count == 1)
        #expect(notifications.first?.0 == "whatsapp")
        #expect(notifications.first?.1.contains("WhatsApp") == true)
        #expect(badge == "1")
    }

    @Test
    func ingestStatus_doesNotNotifyForStaleInboundOnStartup() {
        let service = OpenClawNotificationService.shared
        var notifications: [(String, String, String)] = []
        var badge: String?

        OpenClawNotificationService._testSetHooks(
            .init(
                fetchStatus: { Self.makeStatus(lastInboundAt: Date(timeIntervalSince1970: 1_708_345_600)) },
                postNotification: { channelId, title, body in
                    notifications.append((channelId, title, body))
                },
                setDockBadge: { value in
                    badge = value
                },
                sleep: { _ in }
            )
        )
        defer {
            OpenClawNotificationService._testSetHooks(nil)
            service._testReset()
        }

        service._testSetListeningStartedAt(Date())
        service.ingestStatus(Self.makeStatus(lastInboundAt: Date(timeIntervalSince1970: 1_708_345_600)))

        #expect(notifications.isEmpty)
        #expect(badge == nil)
    }

    @Test
    func markAllAsRead_clearsDockBadge() {
        let service = OpenClawNotificationService.shared
        var notifications: [(String, String, String)] = []
        var badge: String?

        OpenClawNotificationService._testSetHooks(
            .init(
                fetchStatus: { Self.makeStatus(lastInboundAt: Date()) },
                postNotification: { channelId, title, body in
                    notifications.append((channelId, title, body))
                },
                setDockBadge: { value in
                    badge = value
                },
                sleep: { _ in }
            )
        )
        defer {
            OpenClawNotificationService._testSetHooks(nil)
            service._testReset()
        }

        service.ingestStatus(Self.makeStatus(lastInboundAt: Date()))
        #expect(notifications.count == 1)
        #expect(badge == "1")

        service.markAllAsRead()
        #expect(badge == nil)
    }

    @Test
    func unreadCount_persistsUntilExplicitClearAction() {
        let service = OpenClawNotificationService.shared
        var badge: String?

        OpenClawNotificationService._testSetHooks(
            .init(
                fetchStatus: { Self.makeStatus(lastInboundAt: Date()) },
                postNotification: { _, _, _ in },
                setDockBadge: { value in
                    badge = value
                },
                sleep: { _ in }
            )
        )
        defer {
            OpenClawNotificationService._testSetHooks(nil)
            service._testReset()
        }

        let first = Date()
        service.ingestStatus(Self.makeStatus(lastInboundAt: first))
        service.ingestStatus(Self.makeStatus(lastInboundAt: first.addingTimeInterval(3)))

        #expect(badge == "2")
    }

    nonisolated private static func makeStatus(lastInboundAt: Date) -> ChannelsStatusResult {
        let account = ChannelAccountSnapshot(
            accountId: "acct-1",
            name: "John",
            enabled: true,
            configured: true,
            linked: true,
            running: true,
            connected: true,
            reconnectAttempts: nil,
            lastConnectedAt: Date(timeIntervalSince1970: 1_708_345_500),
            lastError: nil,
            lastInboundAt: lastInboundAt,
            lastOutboundAt: nil,
            mode: "operator",
            dmPolicy: "allow"
        )

        return ChannelsStatusResult(
            ts: Int(lastInboundAt.timeIntervalSince1970 * 1000),
            channelOrder: ["whatsapp"],
            channelLabels: ["whatsapp": "WhatsApp"],
            channelDetailLabels: [:],
            channelSystemImages: [:],
            channelMeta: [],
            channelAccounts: ["whatsapp": [account]],
            channelDefaultAccountId: [:]
        )
    }
}
