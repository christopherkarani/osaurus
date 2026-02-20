//
//  OpenClawChannelStatusTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct OpenClawChannelStatusTests {
    @Test
    func channelsStatus_decodesRichPayloadAndNormalizesDates() throws {
        let payload: [String: Any] = [
            "ts": 1_708_345_600_000,
            "channelOrder": ["whatsapp"],
            "channelLabels": ["whatsapp": "WhatsApp"],
            "channelDetailLabels": ["whatsapp": "Personal account"],
            "channelSystemImages": ["whatsapp": "message.fill"],
            "channelMeta": [
                [
                    "id": "whatsapp",
                    "label": "WhatsApp",
                    "detailLabel": "Personal account",
                    "systemImage": "message.fill"
                ]
            ],
            "channelDefaultAccountId": ["whatsapp": "acct-1"],
            "channelAccounts": [
                "whatsapp": [
                    [
                        "accountId": "acct-1",
                        "name": "Primary",
                        "enabled": true,
                        "configured": true,
                        "linked": true,
                        "running": true,
                        "connected": true,
                        "reconnectAttempts": 2,
                        "lastConnectedAt": 1_708_345_600_000,
                        "lastError": "",
                        "lastInboundAt": 1_708_345_660_000,
                        "lastOutboundAt": 1_708_345_670_000,
                        "mode": "operator",
                        "dmPolicy": "allow"
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(ChannelsStatusResult.self, from: data)

        #expect(decoded.channelOrder == ["whatsapp"])
        #expect(decoded.channelLabels["whatsapp"] == "WhatsApp")
        #expect(decoded.channelDetailLabels["whatsapp"] == "Personal account")
        #expect(decoded.channelSystemImages["whatsapp"] == "message.fill")
        #expect(decoded.channelMeta.count == 1)
        #expect(decoded.channelDefaultAccountId["whatsapp"] == "acct-1")

        let account = try #require(decoded.channelAccounts["whatsapp"]?.first)
        #expect(account.id == "acct-1")
        #expect(account.connected == true)
        #expect(account.linked == true)
        #expect(account.mode == "operator")
        #expect(account.dmPolicy == "allow")
        #expect(account.lastConnectedAt != nil)
        #expect(account.lastInboundAt != nil)
        #expect(account.lastOutboundAt != nil)
    }

    @Test
    func channelsStatus_missingOptionalMapsDefaultsToEmptyCollections() throws {
        let payload: [String: Any] = [
            "channelOrder": ["telegram"],
            "channelLabels": ["telegram": "Telegram"],
            "channelAccounts": ["telegram": []]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(ChannelsStatusResult.self, from: data)

        #expect(decoded.channelOrder == ["telegram"])
        #expect(decoded.channelLabels["telegram"] == "Telegram")
        #expect(decoded.channelDetailLabels.isEmpty)
        #expect(decoded.channelSystemImages.isEmpty)
        #expect(decoded.channelMeta.isEmpty)
        #expect(decoded.channelDefaultAccountId.isEmpty)
    }
}
