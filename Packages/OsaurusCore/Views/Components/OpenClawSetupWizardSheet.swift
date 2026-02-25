//
//  OpenClawSetupWizardSheet.swift
//  osaurus
//

import AppKit
import SwiftUI

struct OpenClawSetupWizardSheet: View {
    @ObservedObject var manager: OpenClawManager
    @ObservedObject private var themeManager = ThemeManager.shared

    @Environment(\.dismiss) private var dismiss

    private enum StepStatus: Equatable {
        case pending, running, done, failed(String)

        var isComplete: Bool {
            if case .done = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @State private var nodeStatus: StepStatus = .pending
    @State private var cliStatus: StepStatus = .pending
    @State private var gatewayStatus: StepStatus = .pending
    @State private var connectionStatus: StepStatus = .pending
    @State private var providerStatus: StepStatus = .pending
    @State private var showProviderSetup = false
    @State private var progressText = ""
    @State private var isRunning = false
    @State private var hasRun = false
    @State private var ollamaDetected = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var infrastructureDone: Bool {
        nodeStatus.isComplete && cliStatus.isComplete &&
        gatewayStatus.isComplete && connectionStatus.isComplete
    }

    private var allDone: Bool {
        infrastructureDone && providerStatus.isComplete
    }

    private var anyFailed: Bool {
        nodeStatus.isFailed || cliStatus.isFailed ||
        gatewayStatus.isFailed || connectionStatus.isFailed ||
        providerStatus.isFailed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 500, height: showProviderSetup ? 640 : 540)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { Task { await syncCurrentState() } }
    }

    // MARK: - Header

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
                Text("One click to install, start, and connect.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button { dismiss() } label: {
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

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stepRow("Node.js", description: nodeDescription, status: nodeStatus)
                stepRow("OpenClaw CLI", description: cliDescription, status: cliStatus)
                stepRow("Gateway", description: gatewayDescription, status: gatewayStatus)
                stepRow("Connection", description: "WebSocket to gateway", status: connectionStatus)
                providerStepRow

                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .padding(.top, 4)
                        .animation(.easeInOut, value: progressText)
                }

                if !infrastructureDone {
                    HeaderPrimaryButton(
                        hasRun && anyFailed ? "Retry Setup" : "Set Up OpenClaw",
                        icon: hasRun && anyFailed ? "arrow.clockwise" : "wand.and.stars"
                    ) {
                        Task { await runSetup() }
                    }
                    .disabled(isRunning)
                    .padding(.top, 8)
                }

                if showProviderSetup {
                    OpenClawProviderSetupView(manager: manager)
                        .environment(\.theme, themeManager.currentTheme)
                        .padding(.top, 4)
                        .onChange(of: manager.availableModels.count) { newCount in
                            if newCount > 0 {
                                providerStatus = .done
                            }
                        }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var providerStepRow: some View {
        HStack(spacing: 12) {
            stepIcon(providerStatus)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Providers")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(providerSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(providerSubtitleColor)
                    .animation(.easeInOut, value: providerStatus)
            }

            Spacer()

            if infrastructureDone && !providerStatus.isComplete {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showProviderSetup.toggle()
                    }
                } label: {
                    Text(showProviderSetup ? "Hide" : "Configure")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.1))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(stepBorderColor(providerStatus), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.2), value: providerStatus)
    }

    private var providerSubtitle: String {
        switch providerStatus {
        case .pending:
            if infrastructureDone {
                return ollamaDetected
                    ? "Ollama detected \u{2014} add it to get started"
                    : "Add a provider to use Work mode"
            }
            return "LLM provider (e.g. OpenRouter, Ollama)"
        case .running: return "Configuring…"
        case .done: return "\(manager.availableModels.count) models available"
        case .failed(let msg): return msg
        }
    }

    private var providerSubtitleColor: Color {
        switch providerStatus {
        case .failed: return theme.errorColor
        case .done: return theme.successColor
        case .pending where infrastructureDone && ollamaDetected:
            return theme.successColor
        default: return theme.secondaryText
        }
    }

    private var gatewayDescription: String {
        if manager.usesCustomGatewayEndpoint {
            return "Custom gateway endpoint"
        }
        return "Local gateway process on port \(manager.configuration.gatewayPort)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if infrastructureDone && !providerStatus.isComplete {
                Text("A provider is needed for Work mode")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()
            HeaderPrimaryButton(
                infrastructureDone ? "Done" : "Skip",
                icon: infrastructureDone ? "checkmark" : nil
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Step Row

    private func stepRow(_ title: String, description: String, status: StepStatus) -> some View {
        HStack(spacing: 12) {
            stepIcon(status)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(stepSubtitle(description: description, status: status))
                    .font(.system(size: 12))
                    .foregroundColor(stepSubtitleColor(status))
                    .animation(.easeInOut, value: status)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(stepBorderColor(status), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    @ViewBuilder
    private func stepIcon(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .stroke(theme.tertiaryBackground, lineWidth: 2)
                .frame(width: 20, height: 20)
        case .running:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.75)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(theme.successColor)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(theme.errorColor)
        }
    }

    private func stepSubtitle(description: String, status: StepStatus) -> String {
        switch status {
        case .pending: return description
        case .running: return "Working…"
        case .done: return "Ready"
        case .failed(let msg): return msg
        }
    }

    private func stepSubtitleColor(_ status: StepStatus) -> Color {
        switch status {
        case .failed: return theme.errorColor
        case .done: return theme.successColor
        default: return theme.secondaryText
        }
    }

    private func stepBorderColor(_ status: StepStatus) -> Color {
        switch status {
        case .done: return theme.successColor.opacity(0.3)
        case .failed: return theme.errorColor.opacity(0.3)
        case .running: return theme.accentColor.opacity(0.4)
        default: return theme.primaryBorder
        }
    }

    // MARK: - Descriptions

    private var nodeDescription: String {
        switch manager.environmentStatus {
        case .ready(let version, _): return version
        case .missingNode: return "Not found — will install via Homebrew"
        default: return "JavaScript runtime"
        }
    }

    private var cliDescription: String {
        switch manager.environmentStatus {
        case .ready(_, let version): return "v\(version)"
        case .missingCLI: return "Not installed — will install now"
        case .incompatibleVersion(let found, let required): return "v\(found) found, requires v\(required)"
        default: return "OpenClaw CLI"
        }
    }

    // MARK: - State Sync

    private func syncCurrentState() async {
        await manager.checkEnvironment()
        switch manager.environmentStatus {
        case .ready:
            nodeStatus = .done
            cliStatus = .done
        case .missingCLI:
            nodeStatus = .done
        default:
            break
        }
        if manager.gatewayStatus == .running {
            gatewayStatus = .done
        }
        if manager.isConnected {
            connectionStatus = .done
            if !manager.availableModels.isEmpty {
                providerStatus = .done
            }
        }
    }

    // MARK: - One-Click Setup

    private func runSetup() async {
        isRunning = true
        hasRun = true
        defer { isRunning = false }

        // Reset any prior failures so steps re-run cleanly
        if case .failed = nodeStatus { nodeStatus = .pending }
        if case .failed = cliStatus { cliStatus = .pending }
        if case .failed = gatewayStatus { gatewayStatus = .pending }
        if case .failed = connectionStatus { connectionStatus = .pending }
        if case .failed = providerStatus { providerStatus = .pending }

        // Step 1: Node.js
        if !nodeStatus.isComplete {
            nodeStatus = .running
            progressText = "Checking Node.js…"
            await manager.checkEnvironment()

            if case .missingNode = manager.environmentStatus {
                progressText = "Installing Node.js via Homebrew…"
                do {
                    try await installNodeViaHomebrew()
                    await manager.checkEnvironment()
                    if case .missingNode = manager.environmentStatus {
                        nodeStatus = .failed("Install failed. Install Node.js from nodejs.org.")
                        progressText = ""
                        return
                    }
                    nodeStatus = .done
                } catch {
                    nodeStatus = .failed(error.localizedDescription)
                    progressText = ""
                    return
                }
            } else {
                nodeStatus = .done
            }
        }

        // Step 2: CLI
        if !cliStatus.isComplete {
            cliStatus = .running
            progressText = "Checking OpenClaw CLI…"

            let needsCLI: Bool
            switch manager.environmentStatus {
            case .missingCLI, .incompatibleVersion: needsCLI = true
            default: needsCLI = false
            }

            if needsCLI {
                progressText = "Installing OpenClaw CLI…"
                do {
                    try await manager.installCLI { message in
                        Task { @MainActor in progressText = message }
                    }
                    cliStatus = .done
                } catch {
                    cliStatus = .failed(error.localizedDescription)
                    progressText = ""
                    return
                }
            } else {
                cliStatus = .done
            }
        }

        // Ensure config and auth token are saved before starting the gateway
        ensureDefaults()

        // Step 3: Gateway
        if !gatewayStatus.isComplete {
            gatewayStatus = .running
            if manager.usesCustomGatewayEndpoint {
                progressText = "Using custom gateway endpoint…"
                gatewayStatus = .done
            } else {
                progressText = "Starting gateway…"
                do {
                    try await manager.startGateway()
                    gatewayStatus = .done
                } catch {
                    gatewayStatus = .failed(error.localizedDescription)
                    progressText = ""
                    return
                }
            }
        }

        // Step 4: Connection — sync the right token from gateway config files first,
        // then connect. This handles stale keychain tokens, device-auth.json rotation,
        // and fresh installs where only the plist token exists.
        if !connectionStatus.isComplete {
            connectionStatus = .running
            progressText = "Connecting…"
            do {
                if manager.usesCustomGatewayEndpoint {
                    try await manager.connect()
                } else {
                    try await manager.syncTokenFromGatewayConfig()
                }
                connectionStatus = .done
                progressText = "OpenClaw is ready."
            } catch {
                connectionStatus = .failed(error.localizedDescription)
                progressText = ""
                return
            }
        }

        // Auto-expand provider section when no providers are configured
        if !providerStatus.isComplete {
            withAnimation(.easeInOut(duration: 0.2)) {
                showProviderSetup = true
            }
        }

        // Probe for local Ollama after infrastructure is ready
        await probeOllama()

        progressText = ""
    }

    private func probeOllama() async {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                await MainActor.run { ollamaDetected = true }
            }
        } catch {
            // Ollama not running
        }
    }

    private func ensureDefaults() {
        var config = manager.configuration
        config.isEnabled = true
        manager.updateConfiguration(config)
        if !manager.usesCustomGatewayEndpoint, OpenClawKeychain.getToken() == nil {
            _ = OpenClawKeychain.saveToken(manager.generateAuthToken())
        }
    }

    private func installNodeViaHomebrew() async throws {
        try await Task.detached(priority: .utility) {
            let brew: String
            if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
                brew = "/opt/homebrew/bin/brew"
            } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew") {
                brew = "/usr/local/bin/brew"
            } else {
                throw NSError(
                    domain: "NodeInstaller", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Homebrew not found. Install Node.js from nodejs.org."]
                )
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "node"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "NodeInstaller", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "brew install node failed (exit \(process.terminationStatus))"]
                )
            }
        }.value
    }

    // MARK: - Static helpers (used by tests)

    static func isNodeReady(_ status: OpenClawEnvironmentStatus) -> Bool {
        if case .ready = status { return true }
        return false
    }

    static func isCLIReady(_ status: OpenClawEnvironmentStatus) -> Bool {
        if case .ready = status { return true }
        return false
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
}
