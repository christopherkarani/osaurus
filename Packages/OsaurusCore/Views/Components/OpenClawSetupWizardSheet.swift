//
//  OpenClawSetupWizardSheet.swift
//  osaurus
//

import AppKit
import SwiftUI

struct OpenClawSetupWizardSheet: View {
    enum Step: Int, CaseIterable {
        case environment
        case configuration
        case completion

        var title: String {
            switch self {
            case .environment: "Environment"
            case .configuration: "Gateway"
            case .completion: "Complete"
            }
        }
    }

    @ObservedObject var manager: OpenClawManager
    @ObservedObject private var themeManager = ThemeManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .environment
    @State private var draftConfig = OpenClawConfiguration()
    @State private var authToken: String = ""
    @State private var portText = "18789"
    @State private var statusText: String?
    @State private var isWorking = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
            stepIndicator
            content
            footer
        }
        .frame(width: 540, height: 620)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear(perform: setupInitialState)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.14))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("OpenClaw Setup")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Configure and connect your local OpenClaw gateway")
                    .font(.system(size: 12))
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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.secondaryBackground)
    }

    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.rawValue <= step.rawValue ? theme.accentColor : theme.tertiaryBackground)
                        .frame(width: 8, height: 8)
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(item == step ? theme.primaryText : theme.tertiaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.primaryBackground)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .environment:
                    environmentStep
                case .configuration:
                    configurationStep
                case .completion:
                    completionStep
                }

                if let statusText, !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .environment {
                HeaderSecondaryButton("Back", icon: "chevron.left") {
                    moveBackward()
                }
            }

            Spacer()

            switch step {
            case .environment:
                HeaderSecondaryButton("Recheck", icon: "arrow.clockwise") {
                    Task { await runEnvironmentCheck() }
                }
                HeaderPrimaryButton(environmentPrimaryActionTitle, icon: environmentPrimaryActionIcon) {
                    if environmentReady {
                        moveForward()
                    } else if canInstallCLIFromWizard {
                        Task { await installCLI() }
                    } else {
                        statusText = environmentBlockerMessage
                    }
                }
                .disabled(isWorking || (!environmentReady && !canInstallCLIFromWizard))

            case .configuration:
                HeaderPrimaryButton("Test Connection", icon: "bolt.horizontal.fill") {
                    Task { await testConnection() }
                }
                .disabled(isWorking)
                HeaderPrimaryButton("Next", icon: "chevron.right") {
                    saveDraft()
                    moveForward()
                }
                .disabled(isWorking)

            case .completion:
                HeaderPrimaryButton("Done", icon: "checkmark") {
                    saveDraft()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
    }

    private var environmentStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 1: Verify Environment")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            statusRow(
                title: "Node.js",
                isReady: nodeReady,
                detail: nodeDetail
            )
            statusRow(
                title: "OpenClaw CLI",
                isReady: cliReady,
                detail: cliDetail
            )

            if !environmentReady {
                Text("If the CLI is missing, install it directly from this wizard.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var configurationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 2: Configure Gateway")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                Text("Gateway Port")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField("18789", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bind Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Picker("Bind Mode", selection: $draftConfig.bindMode) {
                    Text("Loopback").tag(OpenClawConfiguration.BindMode.loopback)
                    Text("LAN").tag(OpenClawConfiguration.BindMode.lan)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Auto-start gateway on launch", isOn: $draftConfig.autoStartGateway)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))

            VStack(alignment: .leading, spacing: 8) {
                Text("Gateway Auth Token")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    TextField("Generated token", text: $authToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HeaderSecondaryButton("Generate", icon: "dice.fill") {
                        authToken = manager.generateAuthToken()
                    }
                    HeaderSecondaryButton("Copy", icon: "doc.on.doc") {
                        copyToken()
                    }
                }
            }
        }
    }

    private var completionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 3: Complete")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            statusRow(
                title: "Gateway",
                isReady: manager.gatewayStatus == .running,
                detail: manager.gatewayStatus == .running ? "Running" : "Not running"
            )
            statusRow(
                title: "Connection",
                isReady: manager.isConnected,
                detail: manager.isConnected ? "Connected" : "Disconnected"
            )
            statusRow(
                title: "Channels",
                isReady: !manager.channels.isEmpty,
                detail: "\(manager.channels.count) discovered"
            )

            if manager.gatewayStatus != .running || !manager.isConnected {
                HeaderPrimaryButton("Start & Connect", icon: "play.fill") {
                    Task { await testConnection() }
                }
                .disabled(isWorking)
            }
        }
    }

    private var environmentReady: Bool {
        Self.isNodeReady(manager.environmentStatus) && Self.isCLIReady(manager.environmentStatus)
    }

    private var canInstallCLIFromWizard: Bool {
        Self.canInstallCLIFromWizard(manager.environmentStatus)
    }

    private var environmentPrimaryActionTitle: String {
        environmentReady ? "Next" : "Install CLI"
    }

    private var environmentPrimaryActionIcon: String {
        environmentReady ? "chevron.right" : "arrow.down.circle.fill"
    }

    private var environmentBlockerMessage: String {
        Self.environmentBlockerMessage(for: manager.environmentStatus)
    }

    private var nodeReady: Bool {
        Self.isNodeReady(manager.environmentStatus)
    }

    private var cliReady: Bool {
        Self.isCLIReady(manager.environmentStatus)
    }

    static func isNodeReady(_ status: OpenClawEnvironmentStatus) -> Bool {
        if case .missingNode = status { return false }
        if case .error = status { return false }
        return true
    }

    static func isCLIReady(_ status: OpenClawEnvironmentStatus) -> Bool {
        if case .missingCLI = status { return false }
        if case .incompatibleVersion = status { return false }
        if case .error = status { return false }
        return true
    }

    static func canInstallCLIFromWizard(_ status: OpenClawEnvironmentStatus) -> Bool {
        if case .missingCLI = status { return true }
        return false
    }

    static func environmentBlockerMessage(for status: OpenClawEnvironmentStatus) -> String {
        switch status {
        case .missingNode:
            return "Node.js is required before installing OpenClaw CLI."
        case .incompatibleVersion(let found, let required):
            return "OpenClaw CLI \(found) is incompatible. Update to \(required) or newer."
        case .error(let message):
            return message
        default:
            return "Environment check failed."
        }
    }

    private var nodeDetail: String {
        switch manager.environmentStatus {
        case .ready(let nodeVersion, _):
            return "Detected \(nodeVersion)"
        case .missingNode:
            return "Not found in PATH"
        default:
            return "Unknown"
        }
    }

    private var cliDetail: String {
        switch manager.environmentStatus {
        case .ready(_, let cliVersion):
            return "Detected \(cliVersion)"
        case .missingCLI:
            return "Not installed"
        case .incompatibleVersion(let found, let required):
            return "Found \(found), requires \(required)"
        default:
            return "Unknown"
        }
    }

    private func statusRow(title: String, isReady: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isReady ? theme.successColor : theme.errorColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
    }

    private func setupInitialState() {
        draftConfig = manager.configuration
        draftConfig.isEnabled = true
        portText = "\(manager.configuration.gatewayPort)"
        authToken = OpenClawKeychain.getToken() ?? manager.generateAuthToken()
        Task { await runEnvironmentCheck() }
    }

    private func runEnvironmentCheck() async {
        isWorking = true
        defer { isWorking = false }
        await manager.checkEnvironment()
        if environmentReady {
            statusText = "Environment looks good."
        } else {
            statusText = "Some requirements are missing."
        }
    }

    private func installCLI() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await manager.installCLI { message in
                Task { @MainActor in
                    statusText = message
                }
            }
            statusText = "CLI installed successfully."
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func testConnection() async {
        isWorking = true
        defer { isWorking = false }
        saveDraft()

        do {
            try await manager.startGateway()
            try await manager.connect()
            statusText = "Connected to gateway."
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func saveDraft() {
        if let parsedPort = Int(portText), parsedPort > 0 {
            draftConfig.gatewayPort = parsedPort
        }
        draftConfig.isEnabled = true
        manager.updateConfiguration(draftConfig)
        if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = OpenClawKeychain.saveToken(authToken)
        }
    }

    private func copyToken() {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        statusText = "Token copied."
    }

    private func moveForward() {
        guard let next = Step(rawValue: min(step.rawValue + 1, Step.allCases.count - 1)) else { return }
        step = next
    }

    private func moveBackward() {
        guard let previous = Step(rawValue: max(step.rawValue - 1, 0)) else { return }
        step = previous
    }
}
