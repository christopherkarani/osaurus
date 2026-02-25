//
//  OpenClawChannelLinkSheet.swift
//  osaurus
//

import AppKit
import OpenClawProtocol
import SwiftUI

struct OpenClawChannelLinkSheet: View {
    @ObservedObject var manager: OpenClawManager
    let channel: OpenClawManager.ChannelInfo

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var didStart = false
    @State private var sessionId: String?
    @State private var step: OpenClawWizardStep?
    @State private var status: OpenClawWizardRunStatus = .running
    @State private var isWorking = false
    @State private var errorMessage: String?

    @StateObject private var formState = OpenClawWizardStepFormState()

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isComplete: Bool {
        status == .done
    }

    private var isQRCodeChannel: Bool {
        OpenClawChannelLinkSheetLogic.mode(for: channel.id) == .qr
    }

    private var isTokenChannel: Bool {
        OpenClawChannelLinkSheetLogic.mode(for: channel.id) == .token
    }

    private var primaryActionTitle: String {
        OpenClawWizardFlowLogic.primaryActionTitle(
            isComplete: isComplete,
            stepType: step?.type
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.primaryBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(20)
            }
            Divider().overlay(theme.primaryBorder)
            footer
        }
        .frame(width: 560, height: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            Task { await startWizard() }
        }
        .onDisappear {
            Task { await cancelWizardIfNeeded() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.accentColor.opacity(0.14))
                Image(systemName: channel.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Link \(channel.name) Account")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(channel.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if isComplete {
            VStack(alignment: .leading, spacing: 10) {
                Label("Channel linked successfully", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.successColor)
                Text("\(channel.name) is now available in OpenClaw.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
        } else {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            }

            if let step {
                if let title = step.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }

                if let message = step.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                if isQRCodeChannel {
                    Text("QR linking is recommended for this channel.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                } else if isTokenChannel {
                    Text("Token linking is recommended for this channel.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                if let qrImage = qrImage(from: step) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan QR Code")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.secondaryBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(theme.primaryBorder, lineWidth: 1)
                                    )
                            )
                    }
                }

                OpenClawWizardStepEditor(step: step, formState: formState)
            } else {
                ProgressView("Preparing channel linking flow…")
                    .progressViewStyle(CircularProgressViewStyle())
                    .tint(theme.accentColor)
                    .font(.system(size: 12))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HeaderSecondaryButton("Cancel", icon: "xmark") {
                dismiss()
            }

            Spacer()

            HeaderPrimaryButton(primaryActionTitle, icon: isComplete ? "checkmark" : "arrow.right") {
                if isComplete {
                    dismiss()
                } else {
                    Task { await submitCurrentStep() }
                }
            }
            .disabled(isWorking || (!isComplete && OpenClawWizardFlowLogic.isPrimaryActionBlocked(step: step)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func startWizard() async {
        isWorking = true
        defer { isWorking = false }

        do {
            let start = try await OpenClawGatewayConnection.shared.wizardStart(mode: "local", workspace: nil)
            sessionId = start.sessionId
            status = start.status ?? (start.done ? .done : .running)
            errorMessage = start.error
            apply(step: start.step)
            if start.done {
                await manager.refreshStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
            status = .error
        }
    }

    private func submitCurrentStep() async {
        guard let step, let sessionId else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let value = formState.answerValue(for: step)
            let next = try await OpenClawGatewayConnection.shared.wizardNext(
                sessionId: sessionId,
                stepId: step.id,
                value: value
            )
            status = next.status ?? (next.done ? .done : .running)
            errorMessage = next.error
            apply(step: next.step)
            if next.done {
                await manager.refreshStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
            status = .error
        }
    }

    private func cancelWizardIfNeeded() async {
        guard let sessionId else { return }
        guard !isComplete else { return }
        _ = try? await OpenClawGatewayConnection.shared.wizardCancel(sessionId: sessionId)
    }

    private func apply(step: OpenClawWizardStep?) {
        self.step = step

        guard let step else { return }
        let preferredIndex: Int? = if
            let options = step.options,
            let preferred = OpenClawChannelLinkSheetLogic.preferredOptionIndex(
                stepID: step.id,
                stepTitle: step.title,
                options: options,
                channelID: channel.id,
                channelName: channel.name
            )
        {
            preferred
        } else {
            nil
        }
        formState.apply(step: step, preferredSelectIndex: preferredIndex)
    }

    private func qrImage(from step: OpenClawWizardStep) -> NSImage? {
        let candidates = [
            OpenClawWizardStepFormState.stringValue(step.initialValue?.value),
            step.message,
            step.placeholder,
        ].compactMap { $0 }

        for candidate in candidates {
            if let image = decodeDataURLImage(candidate) {
                return image
            }
        }

        return nil
    }

    private func decodeDataURLImage(_ value: String) -> NSImage? {
        let marker = "base64,"
        guard let markerRange = value.range(of: marker) else { return nil }
        let payload = String(value[markerRange.upperBound...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: data)
    }
}

enum OpenClawChannelLinkMode: Equatable {
    case qr
    case token
    case generic
}

enum OpenClawChannelLinkSheetLogic {
    static func primaryActionTitle(isComplete: Bool, stepType: OpenClawWizardStepType?) -> String {
        OpenClawWizardFlowLogic.primaryActionTitle(isComplete: isComplete, stepType: stepType)
    }

    static func isPrimaryActionBlocked(step: OpenClawWizardStep?) -> Bool {
        OpenClawWizardFlowLogic.isPrimaryActionBlocked(step: step)
    }

    static func emptyOptionsMessage(for step: OpenClawWizardStep) -> String? {
        OpenClawWizardFlowLogic.emptyOptionsMessage(for: step)
    }

    static func fallbackMessage(for step: OpenClawWizardStep) -> String? {
        OpenClawWizardFlowLogic.fallbackMessage(for: step)
    }

    static func implicitAnswerValue(for stepType: OpenClawWizardStepType) -> OpenClawProtocol.AnyCodable? {
        OpenClawWizardFlowLogic.implicitAnswerValue(for: stepType)
    }

    static func mode(for channelId: String) -> OpenClawChannelLinkMode {
        let id = channelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.contains("whatsapp") || id.contains("signal") || id == "web" || id.contains("webchat") {
            return .qr
        }
        if id.contains("telegram") || id.contains("discord") || id.contains("slack") {
            return .token
        }
        return .generic
    }

    static func preferredOptionIndex(
        stepID: String,
        stepTitle: String?,
        options: [OpenClawWizardStepOption],
        channelID: String,
        channelName: String
    ) -> Int? {
        guard isChannelSelectionStep(stepID: stepID, stepTitle: stepTitle) else { return nil }
        let targets = normalizedTargets(channelID: channelID, channelName: channelName)
        guard !targets.isEmpty else { return nil }

        for (index, option) in options.enumerated() {
            if optionMatchesChannel(option, targets: targets) {
                return index
            }
        }
        return nil
    }

    private static func isChannelSelectionStep(stepID: String, stepTitle: String?) -> Bool {
        let id = normalizeToken(stepID)
        if id.contains("channel") || id.contains("provider") {
            return true
        }
        if let stepTitle {
            let title = normalizeToken(stepTitle)
            if title.contains("channel") || title.contains("provider") {
                return true
            }
        }
        return false
    }

    private static func normalizedTargets(channelID: String, channelName: String) -> Set<String> {
        let values = [channelID, channelName]
        return Set(values.map(normalizeToken).filter { !$0.isEmpty })
    }

    private static func optionMatchesChannel(
        _ option: OpenClawWizardStepOption,
        targets: Set<String>
    ) -> Bool {
        if containsTarget(normalizeToken(option.label), targets: targets) {
            return true
        }
        if let hint = option.hint, containsTarget(normalizeToken(hint), targets: targets) {
            return true
        }
        return anyValueContainsTarget(option.value.value, targets: targets)
    }

    private static func anyValueContainsTarget(_ value: Any, targets: Set<String>) -> Bool {
        switch value {
        case let string as String:
            return containsTarget(normalizeToken(string), targets: targets)
        case let dictionary as [String: OpenClawProtocol.AnyCodable]:
            for (_, value) in dictionary {
                if anyValueContainsTarget(value.value, targets: targets) {
                    return true
                }
            }
            return false
        case let array as [OpenClawProtocol.AnyCodable]:
            return array.contains { anyValueContainsTarget($0.value, targets: targets) }
        case let dictionary as [String: Any]:
            for (_, value) in dictionary {
                if anyValueContainsTarget(value, targets: targets) {
                    return true
                }
            }
            return false
        case let array as [Any]:
            return array.contains { anyValueContainsTarget($0, targets: targets) }
        default:
            return false
        }
    }

    private static func containsTarget(_ candidate: String, targets: Set<String>) -> Bool {
        guard !candidate.isEmpty else { return false }
        for target in targets {
            if candidate == target {
                return true
            }
            // Avoid broad fuzzy matches for very short ids (e.g. "web").
            if target.count >= 4, candidate.contains(target) {
                return true
            }
        }
        return false
    }

    private static func normalizeToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        let condensed = trimmed.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "",
            options: .regularExpression
        )
        return condensed
    }
}
