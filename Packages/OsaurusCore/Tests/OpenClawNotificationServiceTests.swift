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

    @Test
    func ingestEvent_postsNotification_andPollFallbackDedupesSameTimestamp() {
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

        let inbound = Date()
        service._testSetListeningStartedAt(inbound.addingTimeInterval(-1))

        service.ingestEvent(
            makeEventFrame(
                event: "message.inbound",
                payload: [
                    "channel": "whatsapp",
                    "accountId": "acct-1",
                    "sender": "Jane",
                    "text": "hello",
                    "ts": inbound.timeIntervalSince1970 * 1000
                ],
                seq: 1
            )
        )
        #expect(notifications.count == 1)
        #expect(badge == "1")

        // Same timestamp arriving via polling fallback must be deduped.
        service.ingestStatus(Self.makeStatus(lastInboundAt: inbound))
        #expect(notifications.count == 1)
        #expect(badge == "1")
    }

    @Test
    func ingestEvent_ignoresHistoricalInboundBeforeListeningBaseline() {
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

        let baseline = Date()
        service._testSetListeningStartedAt(baseline)
        let stale = baseline.addingTimeInterval(-60)

        service.ingestEvent(
            makeEventFrame(
                event: "message.inbound",
                payload: [
                    "channel": "whatsapp",
                    "accountId": "acct-1",
                    "sender": "Jane",
                    "text": "old",
                    "ts": stale.timeIntervalSince1970 * 1000
                ],
                seq: 1
            )
        )

        #expect(notifications.isEmpty)
        #expect(badge == nil)
    }

    @Test
    func reconnectBaselineReset_suppressesStaleNotificationsAfterReconnect() {
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

        let firstBaseline = Date()
        let firstInbound = firstBaseline.addingTimeInterval(1)
        service._testSetListeningStartedAt(firstBaseline)
        service.ingestStatus(Self.makeStatus(lastInboundAt: firstInbound))
        #expect(notifications.count == 1)
        #expect(badge == "1")

        // Simulate reconnect baseline reset with no carried state.
        service._testReset()
        notifications.removeAll()
        badge = nil

        let reconnectBaseline = firstBaseline.addingTimeInterval(30)
        service._testSetListeningStartedAt(reconnectBaseline)
        service.ingestStatus(Self.makeStatus(lastInboundAt: firstInbound))
        #expect(notifications.isEmpty)
        #expect(badge == nil)
    }

    @Test
    func multiAccountBurst_dedupesPerAccountAndTimestamp() {
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

        let baseline = Date()
        service._testSetListeningStartedAt(baseline.addingTimeInterval(-1))
        let ts = baseline.addingTimeInterval(2)
        let account1 = Self.makeAccount(accountId: "acct-1", name: "Alpha", lastInboundAt: ts)
        let account2 = Self.makeAccount(accountId: "acct-2", name: "Beta", lastInboundAt: ts)

        let burst = Self.makeStatus(accounts: [account1, account2])
        service.ingestStatus(burst)
        #expect(notifications.count == 2)
        #expect(badge == "2")

        service.ingestStatus(burst)
        #expect(notifications.count == 2)
        #expect(badge == "2")

        let account2Advanced = Self.makeAccount(
            accountId: "acct-2",
            name: "Beta",
            lastInboundAt: ts.addingTimeInterval(2)
        )
        service.ingestStatus(Self.makeStatus(accounts: [account1, account2Advanced]))
        #expect(notifications.count == 3)
        #expect(badge == "3")
    }

    @Test
    func pauseListening_skipsPolling() async throws {
        let service = OpenClawNotificationService.shared
        service.startListening()

        #expect(service.isPaused == false)
        service.pauseListening()
        #expect(service.isPaused == true)
        service.resumeListening()
        #expect(service.isPaused == false)

        service.stopListening()
    }

    @Test
    func rapidUnchangedPollCycles_doNotIncrementUnread() {
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

        let inbound = Date()
        service._testSetListeningStartedAt(inbound.addingTimeInterval(-1))
        let snapshot = Self.makeStatus(lastInboundAt: inbound)

        for _ in 0..<5 {
            service.ingestStatus(snapshot)
        }

        #expect(notifications.count == 1)
        #expect(badge == "1")
    }

    nonisolated private static func makeAccount(
        accountId: String,
        name: String,
        lastInboundAt: Date
    ) -> ChannelAccountSnapshot {
        ChannelAccountSnapshot(
            accountId: accountId,
            name: name,
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
    }

    nonisolated private static func makeStatus(lastInboundAt: Date) -> ChannelsStatusResult {
        makeStatus(
            accounts: [
                makeAccount(
                    accountId: "acct-1",
                    name: "John",
                    lastInboundAt: lastInboundAt
                )
            ]
        )
    }

    nonisolated private static func makeStatus(
        channelId: String = "whatsapp",
        channelLabel: String = "WhatsApp",
        accounts: [ChannelAccountSnapshot]
    ) -> ChannelsStatusResult {
        let maxInbound = accounts.compactMap(\.lastInboundAt).max() ?? Date()
        return ChannelsStatusResult(
            ts: Int(maxInbound.timeIntervalSince1970 * 1000),
            channelOrder: [channelId],
            channelLabels: [channelId: channelLabel],
            channelDetailLabels: [:],
            channelSystemImages: [:],
            channelMeta: [],
            channelAccounts: [channelId: accounts],
            channelDefaultAccountId: [:]
        )
    }

}
