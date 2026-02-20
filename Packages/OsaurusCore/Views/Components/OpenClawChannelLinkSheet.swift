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

    @State private var textValue = ""
    @State private var confirmValue = false
    @State private var selectedIndex = 0
    @State private var selectedIndices: Set<Int> = []

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isComplete: Bool {
        status == .done
    }

    private var isQRCodeChannel: Bool {
        let id = channel.id.lowercased()
        return id.contains("whatsapp") || id.contains("signal") || id == "web"
    }

    private var isTokenChannel: Bool {
        let id = channel.id.lowercased()
        return id.contains("telegram") || id.contains("discord") || id.contains("slack")
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

                stepEditor(step)
            } else {
                ProgressView("Preparing channel linking flow…")
                    .progressViewStyle(CircularProgressViewStyle())
                    .tint(theme.accentColor)
                    .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder
    private func stepEditor(_ step: OpenClawWizardStep) -> some View {
        switch step.type {
        case .note:
            EmptyView()

        case .progress:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .tint(theme.accentColor)

        case .action:
            EmptyView()

        case .text:
            if step.sensitive == true {
                SecureField(step.placeholder ?? "", text: $textValue)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(step.placeholder ?? "", text: $textValue)
                    .textFieldStyle(.roundedBorder)
            }

        case .confirm:
            Toggle("Confirm", isOn: $confirmValue)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))

        case .select:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((step.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button {
                        selectedIndex = index
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: selectedIndex == index ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(theme.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                if let hint = option.hint, !hint.isEmpty {
                                    Text(hint)
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.secondaryText)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

        case .multiselect:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((step.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button {
                        if selectedIndices.contains(index) {
                            selectedIndices.remove(index)
                        } else {
                            selectedIndices.insert(index)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: selectedIndices.contains(index) ? "checkmark.square.fill" : "square")
                                .foregroundColor(theme.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                if let hint = option.hint, !hint.isEmpty {
                                    Text(hint)
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.secondaryText)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HeaderSecondaryButton("Cancel", icon: "xmark") {
                dismiss()
            }

            Spacer()

            HeaderPrimaryButton(isComplete ? "Done" : "Continue", icon: isComplete ? "checkmark" : "arrow.right") {
                if isComplete {
                    dismiss()
                } else {
                    Task { await submitCurrentStep() }
                }
            }
            .disabled(isWorking || step == nil)
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
            let value = answerValue(for: step)
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
        switch step.type {
        case .text:
            textValue = stringValue(step.initialValue?.value) ?? ""

        case .confirm:
            confirmValue = boolValue(step.initialValue?.value)

        case .select:
            selectedIndex = indexForInitialValue(step)

        case .multiselect:
            selectedIndices = indicesForInitialValues(step)

        default:
            break
        }
    }

    private func indexForInitialValue(_ step: OpenClawWizardStep) -> Int {
        guard let initial = step.initialValue else { return 0 }
        guard let options = step.options else { return 0 }
        return options.firstIndex(where: { option in
            areEqual(option.value, initial)
        }) ?? 0
    }

    private func indicesForInitialValues(_ step: OpenClawWizardStep) -> Set<Int> {
        guard let options = step.options else { return [] }
        guard let initial = step.initialValue?.value as? [OpenClawProtocol.AnyCodable] else {
            return []
        }
        return Set(options.enumerated().compactMap { index, option in
            initial.contains(where: { areEqual($0, option.value) }) ? index : nil
        })
    }

    private func answerValue(for step: OpenClawWizardStep) -> OpenClawProtocol.AnyCodable? {
        switch step.type {
        case .text:
            return OpenClawProtocol.AnyCodable(textValue)
        case .confirm:
            return OpenClawProtocol.AnyCodable(confirmValue)
        case .select:
            let options = step.options ?? []
            guard selectedIndex >= 0, selectedIndex < options.count else {
                return nil
            }
            return options[selectedIndex].value
        case .multiselect:
            let options = step.options ?? []
            let values = selectedIndices
                .sorted()
                .compactMap { index -> OpenClawProtocol.AnyCodable? in
                    guard index >= 0, index < options.count else { return nil }
                    return options[index].value
                }
            return OpenClawProtocol.AnyCodable(values)
        default:
            return nil
        }
    }

    private func boolValue(_ raw: Any?) -> Bool {
        if let raw = raw as? Bool {
            return raw
        }
        if let raw = raw as? String {
            return ["true", "1", "yes", "y"].contains(raw.lowercased())
        }
        if let raw = raw as? Int {
            return raw != 0
        }
        return false
    }

    private func stringValue(_ raw: Any?) -> String? {
        if let raw = raw as? String {
            return raw
        }
        return nil
    }

    private func areEqual(_ lhs: OpenClawProtocol.AnyCodable, _ rhs: OpenClawProtocol.AnyCodable) -> Bool {
        let encoder = JSONEncoder()
        guard
            let lhsData = try? encoder.encode(lhs),
            let rhsData = try? encoder.encode(rhs)
        else {
            return false
        }
        return lhsData == rhsData
    }

    private func qrImage(from step: OpenClawWizardStep) -> NSImage? {
        let candidates = [
            stringValue(step.initialValue?.value),
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
