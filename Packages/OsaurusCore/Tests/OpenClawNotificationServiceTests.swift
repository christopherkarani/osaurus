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
    func ingestStatus_postsNotificationOnlyForNewInboundEvents() {
        let service = OpenClawNotificationService.shared
        var notifications: [(String, String, String)] = []
        var badge: String?
        let initialStatus = makeStatus(lastInboundMs: 0)

        OpenClawNotificationService._testSetHooks(
            .init(
                fetchStatus: { initialStatus },
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

        service.ingestStatus(makeStatus(lastInboundMs: 1_708_345_600_000))
        #expect(notifications.isEmpty)
        #expect(badge == nil)

        service.ingestStatus(makeStatus(lastInboundMs: 1_708_345_660_000))
        #expect(notifications.count == 1)
        #expect(notifications.first?.0 == "whatsapp")
        #expect(notifications.first?.1.contains("WhatsApp") == true)
        #expect(badge == "1")
    }

    private func makeStatus(lastInboundMs: Double) -> ChannelsStatusResult {
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
            lastInboundAt: Date(timeIntervalSince1970: lastInboundMs / 1000),
            lastOutboundAt: nil,
            mode: "operator",
            dmPolicy: "allow"
        )

        return ChannelsStatusResult(
            ts: Int(lastInboundMs),
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
