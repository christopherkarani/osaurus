//
//  OpenClawDashboardView.swift
//  osaurus
//

import SwiftUI

struct OpenClawDashboardView: View {
    @ObservedObject private var manager = OpenClawManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var showSetupWizard = false
    @State private var showProviderSheet = false
    @State private var hasAppeared = false
    @State private var selectedChannelID: String?
    @State private var linkingChannel: OpenClawManager.ChannelInfo?
    @State private var showScheduledTasks = false
    @State private var showSkills = false
    @State private var showConnectedClients = false
    @State private var removingProviderID: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -8)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if manager.configuration.isEnabled {
                        configuredContent
                    } else {
                        emptyState
                    }
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            Task {
                await manager.checkEnvironment()
                await manager.refreshStatus()
                if manager.isConnected {
                    try? await manager.fetchConfiguredProviders()
                }
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            OpenClawSetupWizardSheet(manager: manager)
        }
        .sheet(isPresented: $showProviderSheet) {
            OpenClawProviderSheet(manager: manager)
        }
        .sheet(item: $linkingChannel) { channel in
            OpenClawChannelLinkSheet(manager: manager, channel: channel)
        }
    }

    private var header: some View {
        ManagerHeaderWithActions(
            title: "OpenClaw",
            subtitle: subtitleText
        ) {
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                Task {
                    await manager.checkEnvironment()
                    await manager.refreshStatus()
                    if showScheduledTasks {
                        await manager.refreshCron()
                    }
                    if showSkills {
                        await manager.refreshSkills()
                    }
                    if showConnectedClients {
                        await manager.refreshConnectedClients()
                    }
                }
            }
            HeaderSecondaryButton("Clear Unread", icon: "checkmark.circle") {
                manager.markAllChannelNotificationsRead()
            }
            HeaderPrimaryButton(
                manager.configuration.isEnabled ? "Setup" : "Get Started",
                icon: manager.configuration.isEnabled ? "slider.horizontal.3" : "wand.and.stars"
            ) {
                showSetupWizard = true
            }
        }
    }

    private var subtitleText: String {
        switch manager.phase {
        case .notConfigured:
            return "Set up a local OpenClaw gateway for channel-aware chat."
        case .checkingEnvironment:
            return "Checking local OpenClaw requirements…"
        case .environmentBlocked:
            return "Environment setup required before connecting."
        case .installingCLI:
            return "Installing OpenClaw CLI…"
        case .configured:
            return "Gateway configured but not started."
        case .startingGateway:
            return "Starting OpenClaw gateway…"
        case .gatewayRunning:
            return manager.isConnected ? "Gateway running and connected." : "Gateway running."
        case .connecting:
            return "Connecting to gateway websocket…"
        case .connected:
            return "\(manager.channels.count) channels \u{2022} \(manager.availableModels.count) models"
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))…"
        case .gatewayFailed(let message), .connectionFailed(let message):
            return message
        }
    }

    private var configuredContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            OpenClawGatewayStatusCard(manager: manager)
            OpenClawGatewayEndpointSettingsCard(manager: manager)

            if manager.phase == .checkingEnvironment || manager.phase == .installingCLI {
                loadingStrip
            }

            if !manager.activeSessions.isEmpty {
                sectionTitle("Active Sessions")
                VStack(spacing: 10) {
                    ForEach(manager.activeSessions) { session in
                        OpenClawActiveSessionView(manager: manager, session: session)
                    }
                }
            }

            if !manager.channels.isEmpty {
                sectionTitle("Channels")
                VStack(spacing: 10) {
                    ForEach(manager.channels) { channel in
                        Button {
                            selectedChannelID = selectedChannelID == channel.id ? nil : channel.id
                        } label: {
                            OpenClawChannelCard(
                                channel: channel,
                                isSelected: selectedChannelID == channel.id
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if
                        let selectedChannelID,
                        let selectedChannel = manager.channels.first(where: { $0.id == selectedChannelID })
                    {
                        OpenClawChannelDetailView(
                            channelId: selectedChannel.id,
                            channelName: selectedChannel.name,
                            channelDetailLabel: manager.channelDetailLabel(for: selectedChannel.id),
                            channelSystemImage: selectedChannel.systemImage,
                            accounts: manager.channelAccounts(for: selectedChannel.id),
                            defaultAccountId: manager.channelDefaultAccountId(for: selectedChannel.id),
                            onLinkAccount: {
                                linkingChannel = selectedChannel
                            },
                            onDisconnect: { accountId in
                                Task {
                                    try? await manager.disconnectChannel(
                                        channelId: selectedChannel.id,
                                        accountId: accountId
                                    )
                                }
                            },
                            onConfigure: {
                                showSetupWizard = true
                            }
                        )
                    }
                }
            }

            providersSection

            if !manager.availableModels.isEmpty {
                sectionTitle("Gateway Models")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(manager.availableModels, id: \.id) { model in
                        OpenClawDashboardModelChip(model: model.id, provider: model.provider)
                    }
                }
            }

            sectionTitle("MCP")
            OpenClawMCPModeCard(manager: manager)

            DisclosureGroup(isExpanded: $showScheduledTasks) {
                OpenClawCronView(manager: manager)
                    .padding(.top, 6)
            } label: {
                sectionTitle("Scheduled Tasks")
            }
            .onChange(of: showScheduledTasks) { expanded in
                guard expanded else { return }
                Task { await manager.refreshCron() }
            }

            DisclosureGroup(isExpanded: $showSkills) {
                OpenClawSkillsView(manager: manager)
                    .padding(.top, 6)
            } label: {
                sectionTitle("Skills")
            }
            .onChange(of: showSkills) { expanded in
                guard expanded else { return }
                Task { await manager.refreshSkills() }
            }

            DisclosureGroup(isExpanded: $showConnectedClients) {
                OpenClawConnectedClientsView(manager: manager)
                    .padding(.top, 6)
            } label: {
                sectionTitle("Connected Clients")
            }
            .onChange(of: showConnectedClients) { expanded in
                guard expanded else { return }
                Task { await manager.refreshConnectedClients() }
            }

            sectionTitle("Gateway Logs")
            OpenClawLogViewer()

            if let health = manager.lastHealth {
                sectionTitle("Health")
                GlassListRow {
                    VStack(alignment: .leading, spacing: 8) {
                        metricRow("Version", value: health.version)
                        metricRow("Uptime", value: "\(Int(health.uptime))s")
                        metricRow("Memory", value: String(format: "%.1f MB", health.memoryMB))
                        metricRow("Active Runs", value: "\(health.activeRuns)")
                    }
                }
            }
        }
    }

    private var loadingStrip: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.warningColor.opacity(0.16))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.warningColor)
                        )
                    Text("Loading OpenClaw runtime state…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
                IndeterminateShimmerProgress(color: theme.accentColor, height: 4)
            }
        }
    }

    @ViewBuilder
    private var providersSection: some View {
        if manager.isConnected {
            HStack {
                sectionTitle("Providers")
                Spacer()
                Button {
                    showProviderSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Add")
                            .font(.system(size: 11, weight: .medium))
                    }
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

            if manager.configuredProviders.isEmpty {
                GlassListRow {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(theme.secondaryText)
                        Text("No providers configured")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                        Text("Add a provider like OpenRouter or Ollama to enable Work Mode.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(manager.configuredProviders) { provider in
                        OpenClawProviderCard(
                            provider: provider,
                            isRemoving: removingProviderID == provider.id
                        ) {
                            Task {
                                removingProviderID = provider.id
                                try? await manager.removeProvider(id: provider.id)
                                removingProviderID = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("OpenClaw Is Not Configured")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Install the OpenClaw CLI, configure the gateway, and connect channels from one place.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HeaderPrimaryButton("Get Started", icon: "wand.and.stars") {
                showSetupWizard = true
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.secondaryText)
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
    }
}

private struct OpenClawDashboardModelChip: View {
    @Environment(\.theme) private var theme

    let model: String
    var provider: String = ""
    @State private var isHovered = false
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            if !provider.isEmpty {
                Text(provider)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
    }
}

// MARK: - Provider Card

private struct OpenClawMCPModeCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager
    @ObservedObject private var mcpProviderManager = MCPProviderManager.shared
    @ObservedObject private var remoteProviderManager = RemoteProviderManager.shared
    @State private var enableMcporterSkill = true

    private var autoSyncBinding: Binding<Bool> {
        Binding(
            get: { manager.configuration.autoSyncMCPBridge },
            set: { manager.setAutoSyncMCPBridge($0) }
        )
    }

    private struct ProviderFixIt: Identifiable {
        let id: String
        let providerName: String
        let source: String
        let fixIt: String
    }

    private var mismatchFixIts: [ProviderFixIt] {
        var items: [ProviderFixIt] = []

        for provider in mcpProviderManager.configuration.enabledProviders {
            guard let state = mcpProviderManager.providerStates[provider.id],
                state.healthState == .misconfiguredEndpoint
            else { continue }

            items.append(
                ProviderFixIt(
                    id: "mcp-\(provider.id.uuidString)",
                    providerName: provider.name,
                    source: "MCP",
                    fixIt: state.healthFixIt
                        ?? "Configure an MCP transport URL (for example /mcp or /sse) instead of a gateway control route."
                )
            )
        }

        for provider in remoteProviderManager.configuration.enabledProviders {
            guard let state = remoteProviderManager.providerStates[provider.id],
                state.healthState == .misconfiguredEndpoint
            else { continue }

            items.append(
                ProviderFixIt(
                    id: "remote-\(provider.id.uuidString)",
                    providerName: provider.name,
                    source: "Remote",
                    fixIt: state.healthFixIt
                        ?? "Use a model API endpoint that returns JSON (for example /v1/models)."
                )
            )
        }

        return items
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenClaw MCP Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("OpenClaw MCP access uses mcporter. Osaurus remote MCP providers remain in Tools > Remote Providers.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                Text("Sync enabled Osaurus MCP providers into a generated mcporter config and wire it to the OpenClaw mcporter skill.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                Toggle("Automatically sync MCP bridge on provider/connection changes", isOn: autoSyncBinding)
                    .font(.system(size: 12))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .disabled(manager.mcpBridgeIsSyncing)

                Toggle("Enable mcporter skill during sync", isOn: $enableMcporterSkill)
                    .font(.system(size: 12))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .disabled(manager.mcpBridgeIsSyncing)

                HStack(spacing: 10) {
                    Text("\(mcpProviderManager.configuration.enabledProviders.count) enabled Osaurus MCP provider(s)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    if manager.mcpBridgeIsSyncing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        HeaderPrimaryButton("Sync to OpenClaw", icon: "arrow.triangle.2.circlepath") {
                            syncProviders()
                        }
                        .disabled(!manager.isConnected)
                    }
                }

                if !manager.isConnected {
                    Text("Connect OpenClaw before syncing MCP providers.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                }

                if !mismatchFixIts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provider endpoint mismatch guidance")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                        ForEach(mismatchFixIts) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.source): \(item.providerName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text(item.fixIt)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.warningColor.opacity(0.08))
                    )
                }

                if let syncResult = manager.mcpBridgeLastSyncResult {
                    Text("Synced \(syncResult.syncedProviderCount) provider(s) to \(syncResult.configPath).")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)

                    if !syncResult.skippedProviderNames.isEmpty {
                        Text("Skipped invalid provider URLs: \(syncResult.skippedProviderNames.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                    }

                    if syncResult.driftDetected {
                        Text("Warning: existing bridge config drift was detected before this sync.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                    }

                    if syncResult.ownershipConflictDetected {
                        Text("Ownership conflict detected; manual sync adopted bridge ownership.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                    }

                    if let backupPath = syncResult.backupPath, !backupPath.isEmpty {
                        Text("Backup: \(backupPath)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .textSelection(.enabled)
                    }

                    if let mode = manager.mcpBridgeLastSyncMode {
                        Text("Last sync: \(mode.rawValue.capitalized) at \(syncResult.syncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                if let syncErrorState = manager.mcpBridgeLastSyncErrorState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(syncErrorState.message)
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor)

                        HStack(spacing: 8) {
                            Text("Code: \(syncErrorState.code.rawValue)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .textSelection(.enabled)
                            Spacer()
                            if syncErrorState.retryable {
                                HeaderPrimaryButton("Retry Sync", icon: "arrow.clockwise") {
                                    retryLastSync()
                                }
                                .disabled(manager.mcpBridgeIsSyncing || !manager.isConnected)
                            }
                        }
                    }
                } else if let syncError = manager.mcpBridgeLastSyncError {
                    Text(syncError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
    }

    private func syncProviders() {
        Task {
            do {
                _ = try await manager.syncMCPProvidersToOpenClaw(
                    enableMcporterSkill: enableMcporterSkill
                )
            } catch {
                // Manager publishes sync errors for UI.
            }
        }
    }

    private func retryLastSync() {
        Task {
            do {
                _ = try await manager.retryLastMCPBridgeSync()
            } catch {
                // Manager publishes sync errors for UI.
            }
        }
    }
}

// MARK: - Provider Card

private struct OpenClawGatewayEndpointSettingsCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var gatewayURL: String = ""
    @State private var healthURL: String = ""
    @State private var token: String = ""
    @State private var clearToken = false
    @State private var autoStartLocalGateway = true
    @State private var saveMessage: String?

    private var hasCustomEndpoint: Bool {
        !gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gateway Endpoint Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                TextField("WebSocket URL (e.g. wss://host/ws)", text: $gatewayURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                TextField("Health URL (optional, e.g. https://host/health)", text: $healthURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                SecureField("Gateway token (optional)", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(clearToken)

                Toggle("Clear saved gateway token", isOn: $clearToken)
                    .font(.system(size: 12))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))

                Toggle("Auto-start local gateway on launch", isOn: $autoStartLocalGateway)
                    .font(.system(size: 12))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .disabled(hasCustomEndpoint)

                if hasCustomEndpoint {
                    Text("Custom endpoint enabled. Local auto-start will be disabled.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                }

                if let saveMessage, !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }

                HStack {
                    Spacer()
                    HeaderPrimaryButton("Save Endpoint", icon: "checkmark") {
                        saveSettings()
                    }
                }
            }
        }
        .onAppear {
            syncFromConfiguration()
        }
        .onChange(of: manager.configuration) { _ in
            syncFromConfiguration()
        }
    }

    private func syncFromConfiguration() {
        gatewayURL = manager.configuration.gatewayURL ?? ""
        healthURL = manager.configuration.gatewayHealthURL ?? ""
        autoStartLocalGateway = manager.configuration.autoStartGateway
        token = ""
        clearToken = false
    }

    private func saveSettings() {
        let trimmedGatewayURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHealthURL = healthURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        var updated = manager.configuration
        updated.gatewayURL = trimmedGatewayURL.isEmpty ? nil : trimmedGatewayURL
        updated.gatewayHealthURL = trimmedHealthURL.isEmpty ? nil : trimmedHealthURL
        updated.autoStartGateway = trimmedGatewayURL.isEmpty ? autoStartLocalGateway : false

        let endpointChanged = updated.gatewayURL != manager.configuration.gatewayURL
            || updated.gatewayHealthURL != manager.configuration.gatewayHealthURL

        manager.updateConfiguration(updated)

        if clearToken {
            _ = OpenClawKeychain.deleteToken()
        } else if !trimmedToken.isEmpty {
            _ = OpenClawKeychain.saveToken(trimmedToken)
        }

        if endpointChanged {
            manager.disconnect()
        }

        saveMessage = "Saved."
    }
}

// MARK: - Provider Card

private struct OpenClawProviderCard: View {
    @Environment(\.theme) private var theme

    let provider: OpenClawManager.ProviderInfo
    let isRemoving: Bool
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var showRemoveConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if isHovered && !isRemoving {
                    Button {
                        showRemoveConfirm = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(theme.tertiaryBackground))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                if isRemoving {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            Text("\(provider.modelCount) model\(provider.modelCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            HStack(spacing: 6) {
                Circle()
                    .fill(readinessColor)
                    .frame(width: 6, height: 6)
                Text(provider.readinessReason.shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(readinessColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .alert("Remove Provider", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(provider.name)? Models from this provider will no longer be available.")
        }
    }

    private var iconName: String {
        switch provider.id.lowercased() {
        case "openrouter": return "arrow.triangle.branch"
        case "moonshot": return "moon.stars.fill"
        case "kimi-coding": return "terminal.fill"
        case "ollama": return "desktopcomputer"
        case "vllm": return "cpu"
        case "anthropic": return "brain"
        case "openai": return "sparkles"
            default: return "cube.transparent"
        }
    }

    private var readinessColor: Color {
        switch provider.readinessReason {
        case .ready:
            return theme.successColor
        case .noKey, .noModels:
            return theme.warningColor
        case .unreachable, .invalidConfig:
            return theme.errorColor
        }
    }
}

// MARK: - Provider Sheet

private struct OpenClawProviderSheet: View {
    @ObservedObject var manager: OpenClawManager
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.14))
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Provider")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Configure an LLM provider for Work Mode.")
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

            ScrollView {
                OpenClawProviderSetupView(manager: manager)
                    .padding(24)
            }

            HStack {
                Spacer()
                HeaderPrimaryButton("Done", icon: "checkmark") {
                    dismiss()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground)
        }
        .frame(width: 480, height: 480)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }
}
