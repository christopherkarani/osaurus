//
//  OpenClawSkillsView.swift
//  osaurus
//

import SwiftUI

struct OpenClawSkillsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var hasLoaded = false
    @State private var busySkillKey: String?
    @State private var actionError: String?
    @State private var toggleOverrides: [String: Bool] = [:]

    private var skills: [OpenClawSkillStatus] {
        (manager.skillsReport?.skills ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                if skills.isEmpty {
                    Text("No skills reported by gateway.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    ForEach(skills) { skill in
                        skillRow(skill)
                    }
                }

                if !manager.skillsBins.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skill Binaries")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(manager.skillsBins, id: \.self) { bin in
                                Text(bin)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(theme.secondaryBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(theme.primaryBorder, lineWidth: 1)
                                            )
                                    )
                            }
                        }
                    }
                }

                if let actionError, !actionError.isEmpty {
                    Text(actionError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            Task { await manager.refreshSkills() }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Skills")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                Task { await manager.refreshSkills() }
            }
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: OpenClawSkillStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        statusChip(for: skill)
                    }

                    Text(skill.source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)

                    if let description = normalized(skill.description) {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            OpenClawSkillsViewLogic.displayedEnabled(
                                serverEnabled: !skill.disabled,
                                overrideEnabled: toggleOverrides[skill.skillKey]
                            )
                        },
                        set: { enabled in
                            let previous = OpenClawSkillsViewLogic.displayedEnabled(
                                serverEnabled: !skill.disabled,
                                overrideEnabled: toggleOverrides[skill.skillKey]
                            )
                            toggleOverrides[skill.skillKey] = enabled
                            busySkillKey = skill.skillKey
                            Task {
                                do {
                                    try await manager.updateSkillEnabled(skillKey: skill.skillKey, enabled: enabled)
                                    await MainActor.run {
                                        actionError = nil
                                        toggleOverrides.removeValue(forKey: skill.skillKey)
                                    }
                                } catch {
                                    await manager.refreshSkills()
                                    await MainActor.run {
                                        actionError = error.localizedDescription
                                        toggleOverrides[skill.skillKey] = OpenClawSkillsViewLogic.finalEnabled(
                                            previous: previous,
                                            desired: enabled,
                                            succeeded: false
                                        )
                                        toggleOverrides.removeValue(forKey: skill.skillKey)
                                    }
                                }
                                await MainActor.run { busySkillKey = nil }
                            }
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel("\(skill.name) enabled")
                .accessibilityHint("Disabled while skill state is updating.")
                .accessibilityValue(
                    OpenClawSkillsViewLogic.toggleAccessibilityValue(
                        isBusy: busySkillKey == skill.skillKey,
                        isEnabled: OpenClawSkillsViewLogic.displayedEnabled(
                            serverEnabled: !skill.disabled,
                            overrideEnabled: toggleOverrides[skill.skillKey]
                        )
                    )
                )
                .disabled(skill.always || busySkillKey == skill.skillKey)
            }

            HStack(spacing: 8) {
                if let installOption = skill.install.first {
                    HeaderSecondaryButton("Install", icon: "square.and.arrow.down") {
                        busySkillKey = skill.skillKey
                        Task {
                            do {
                                try await manager.installSkill(name: skill.name, installId: installOption.id)
                                await MainActor.run { actionError = nil }
                            } catch {
                                await MainActor.run { actionError = error.localizedDescription }
                            }
                            await MainActor.run { busySkillKey = nil }
                        }
                    }
                    .accessibilityLabel("Install \(skill.name)")
                    .accessibilityHint("Disabled while an install action is running.")
                    .accessibilityValue(busySkillKey == skill.skillKey ? "Busy" : "Ready")
                    .disabled(busySkillKey == skill.skillKey)
                }

                if skill.hasMissingRequirements && !skill.install.isEmpty {
                    Text("Update available")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                }

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func statusChip(for skill: OpenClawSkillStatus) -> some View {
        let status = OpenClawSkillsViewLogic.status(for: skill)
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color(for: status.tone))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color(for: status.tone).opacity(0.12)))
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func color(for tone: OpenClawSkillsViewLogic.StatusTone) -> Color {
        switch tone {
        case .success:
            return theme.successColor
        case .warning:
            return theme.warningColor
        case .error:
            return theme.errorColor
        }
    }
}

enum OpenClawSkillsViewLogic {
    enum StatusTone {
        case success
        case warning
        case error
    }

    struct Status {
        let label: String
        let tone: StatusTone
    }

    static func status(for skill: OpenClawSkillStatus) -> Status {
        if skill.disabled {
            return Status(label: "Disabled", tone: .warning)
        }
        if !skill.eligible || skill.blockedByAllowlist {
            return Status(label: "Blocked", tone: .error)
        }
        if skill.hasMissingRequirements {
            return Status(label: "Needs Setup", tone: .warning)
        }
        return Status(label: "Active", tone: .success)
    }

    static func displayedEnabled(serverEnabled: Bool, overrideEnabled: Bool?) -> Bool {
        overrideEnabled ?? serverEnabled
    }

    static func finalEnabled(previous: Bool, desired: Bool, succeeded: Bool) -> Bool {
        succeeded ? desired : previous
    }

    static func toggleAccessibilityValue(isBusy: Bool, isEnabled: Bool) -> String {
        if isBusy {
            return "Updating"
        }
        return isEnabled ? "Enabled" : "Disabled"
    }
}
