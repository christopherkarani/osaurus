//
//  OpenClawPhase3ViewLogicTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OpenClawPhase3ViewLogicTests {
    @Test
    func channelLinkMode_detectsQRAndTokenChannels() {
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "whatsapp") == .qr)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "signal") == .qr)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "web") == .qr)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "webchat") == .qr)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "telegram") == .token)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "discord") == .token)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "slack") == .token)
        #expect(OpenClawChannelLinkSheetLogic.mode(for: "matrix") == .generic)
    }

    @Test
    func channelLinkPreferredOption_selectsMatchingChannel() {
        let options = [
            OpenClawWizardStepOption(value: AnyCodable("telegram"), label: "Telegram", hint: nil),
            OpenClawWizardStepOption(value: AnyCodable("discord"), label: "Discord", hint: nil),
            OpenClawWizardStepOption(value: AnyCodable("slack"), label: "Slack", hint: nil),
        ]

        let preferred = OpenClawChannelLinkSheetLogic.preferredOptionIndex(
            stepID: "channel",
            stepTitle: "Choose channel",
            options: options,
            channelID: "discord",
            channelName: "Discord"
        )

        #expect(preferred == 1)
    }

    @Test
    func cronToggleLogic_rollsBackOnFailure() {
        #expect(OpenClawCronViewLogic.finalToggleValue(previous: false, desired: true, succeeded: true) == true)
        #expect(OpenClawCronViewLogic.finalToggleValue(previous: false, desired: true, succeeded: false) == false)
        #expect(OpenClawCronViewLogic.finalToggleValue(previous: true, desired: false, succeeded: false) == true)
    }

    @Test
    func skillsStatusLogic_matchesPriorityRules() {
        var skill = makeSkill(disabled: false, eligible: true, blockedByAllowlist: false, hasMissingRequirements: false)
        #expect(OpenClawSkillsViewLogic.status(for: skill).label == "Active")

        skill = makeSkill(disabled: true, eligible: true, blockedByAllowlist: false, hasMissingRequirements: false)
        #expect(OpenClawSkillsViewLogic.status(for: skill).label == "Disabled")

        skill = makeSkill(disabled: false, eligible: false, blockedByAllowlist: false, hasMissingRequirements: false)
        #expect(OpenClawSkillsViewLogic.status(for: skill).label == "Blocked")

        skill = makeSkill(disabled: false, eligible: true, blockedByAllowlist: true, hasMissingRequirements: false)
        #expect(OpenClawSkillsViewLogic.status(for: skill).label == "Blocked")

        skill = makeSkill(disabled: false, eligible: true, blockedByAllowlist: false, hasMissingRequirements: true)
        #expect(OpenClawSkillsViewLogic.status(for: skill).label == "Needs Setup")
    }

    @Test
    func connectedClientsLogic_sortsNewestFirst() {
        let oldest = makePresence(instanceId: "old", timestampMs: 1_700_000_000_000)
        let newest = makePresence(instanceId: "new", timestampMs: 1_800_000_000_000)
        let middle = makePresence(instanceId: "middle", timestampMs: 1_750_000_000_000)

        let sorted = OpenClawConnectedClientsViewLogic.sortedClients([oldest, newest, middle])
        #expect(sorted.map(\.id) == ["new", "middle", "old"])
    }

    @Test
    func connectedClientsLogic_sortsByIdentityWhenTimestampsMatch() {
        let beta = makePresence(deviceId: "device-beta", host: "beta-host", timestampMs: 1_800_000_000_000)
        let alpha = makePresence(deviceId: "device-alpha", host: "alpha-host", timestampMs: 1_800_000_000_000)

        let sorted = OpenClawConnectedClientsViewLogic.sortedClients([beta, alpha])
        #expect(sorted.map(\.primaryIdentity) == ["device-alpha", "device-beta"])
    }

    @Test
    func connectedClientsAccessibility_includesIdentityStatusAndMetadata() {
        let client = makePresence(
            deviceId: "device-123",
            instanceId: "instance-1",
            host: "Chris-MacBook-Pro",
            roles: ["chat-client"],
            scopes: ["operator.read"],
            tags: ["desktop"],
            mode: "chat",
            timestampMs: 1_800_000_000_000
        )

        let label = OpenClawConnectedClientsViewLogic.accessibilityLabel(for: client, connectedText: "1m ago")
        let value = OpenClawConnectedClientsViewLogic.accessibilityValue(for: client)

        #expect(label.contains("identity device-123"))
        #expect(label.contains("status chat"))
        #expect(value.contains("Roles: chat-client"))
        #expect(value.contains("Scopes: operator.read"))
        #expect(value.contains("Tags: desktop"))
    }

    @Test
    func presenceIdentity_fallbackUsesExpectedOrder() {
        let deviceFirst = makePresence(
            deviceId: "device-id",
            instanceId: "instance-id",
            host: "host-id",
            ip: "10.0.0.10",
            timestampMs: 1_800_000_000_000
        )
        #expect(deviceFirst.primaryIdentity == "device-id")

        let instanceFallback = makePresence(
            instanceId: "instance-id",
            host: "host-id",
            ip: "10.0.0.11",
            timestampMs: 1_800_000_001_000
        )
        #expect(instanceFallback.primaryIdentity == "instance-id")

        let hostFallback = makePresence(
            host: "host-id",
            ip: "10.0.0.12",
            timestampMs: 1_800_000_002_000
        )
        #expect(hostFallback.primaryIdentity == "host-id")

        let ipFallback = makePresence(
            ip: "10.0.0.13",
            timestampMs: 1_800_000_003_000
        )
        #expect(ipFallback.primaryIdentity == "10.0.0.13")
        #expect(ipFallback.displayName == "10.0.0.13")
    }

    private func makeSkill(
        disabled: Bool,
        eligible: Bool,
        blockedByAllowlist: Bool,
        hasMissingRequirements: Bool
    ) -> OpenClawSkillStatus {
        OpenClawSkillStatus(
            name: "skill",
            description: "desc",
            source: "local",
            filePath: "/tmp/SKILL.md",
            baseDir: "/tmp",
            skillKey: "skill",
            bundled: false,
            primaryEnv: nil,
            emoji: nil,
            homepage: nil,
            always: false,
            disabled: disabled,
            blockedByAllowlist: blockedByAllowlist,
            eligible: eligible,
            requirements: OpenClawSkillRequirementSet(),
            missing: hasMissingRequirements ? OpenClawSkillRequirementSet(bins: ["node"]) : OpenClawSkillRequirementSet(),
            configChecks: [],
            install: []
        )
    }

    private func makePresence(
        deviceId: String? = nil,
        instanceId: String? = nil,
        host: String? = nil,
        ip: String = "10.0.0.1",
        roles: [String] = ["chat-client"],
        scopes: [String] = [],
        tags: [String] = [],
        mode: String? = "chat",
        timestampMs: Double
    ) -> OpenClawPresenceEntry {
        OpenClawPresenceEntry(
            deviceId: deviceId,
            instanceId: instanceId,
            host: host,
            ip: ip,
            version: "1.0.0",
            platform: "macos",
            deviceFamily: "Mac",
            modelIdentifier: "Mac15,6",
            roles: roles,
            scopes: scopes,
            mode: mode,
            lastInputSeconds: 0,
            reason: "node-connected",
            text: "Node connected",
            tags: tags,
            timestampMs: timestampMs
        )
    }
}
