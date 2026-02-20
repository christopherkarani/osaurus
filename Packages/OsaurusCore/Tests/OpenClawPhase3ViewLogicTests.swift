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
        let oldest = makePresence(id: "old", timestampMs: 1_700_000_000_000)
        let newest = makePresence(id: "new", timestampMs: 1_800_000_000_000)
        let middle = makePresence(id: "middle", timestampMs: 1_750_000_000_000)

        let sorted = OpenClawConnectedClientsViewLogic.sortedClients([oldest, newest, middle])
        #expect(sorted.map(\.id) == ["new", "middle", "old"])
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

    private func makePresence(id: String, timestampMs: Double) -> OpenClawPresenceEntry {
        OpenClawPresenceEntry(
            instanceId: id,
            host: "node-\(id)",
            ip: "10.0.0.1",
            version: "1.0.0",
            platform: "macos",
            deviceFamily: "Mac",
            modelIdentifier: "Mac15,6",
            roles: ["chat-client"],
            scopes: [],
            mode: "chat",
            lastInputSeconds: 0,
            reason: "node-connected",
            text: "Node connected",
            timestampMs: timestampMs
        )
    }
}
