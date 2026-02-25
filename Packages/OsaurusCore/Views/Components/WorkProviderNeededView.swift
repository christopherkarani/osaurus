//
//  WorkProviderNeededView.swift
//  osaurus
//
//  Shown in Work mode when OpenClaw is connected but no providers/models are configured.
//

import SwiftUI

struct WorkProviderNeededView: View {
    @ObservedObject private var openClawManager = OpenClawManager.shared
    @Environment(\.theme) private var theme

    @State private var hasAppeared = false
    @State private var showingProviderSheet = false
    @State private var ollamaDetected = false
    @State private var osaurusDetected = false
    @State private var isConfiguringOsaurus = false
    @State private var setupSuccessMessage: String?
    @State private var setupErrorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    providerNeededContent
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) { hasAppeared = true }
            }
            Task {
                await probeOllama()
                await probeOsaurus()
            }
        }
        .onDisappear { hasAppeared = false }
        .sheet(isPresented: $showingProviderSheet) {
            WorkModelSelectorSheet(selectedModel: .constant(nil), currentModels: [])
        }
    }

    // MARK: - Content

    private var providerNeededContent: some View {
        VStack(spacing: 28) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "work-provider")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation(), value: hasAppeared)

            VStack(spacing: 12) {
                Text("Almost there")
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text("OpenClaw is running, but no LLM provider is configured yet. Add one to start using Work mode.")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)

                if ollamaDetected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                            .font(.system(size: 13))
                        Text("Ollama detected \u{2014} no API key needed")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(theme.springAnimation().delay(0.22), value: hasAppeared)
                }

                if osaurusDetected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                            .font(.system(size: 13))
                        Text("Osaurus API detected at 127.0.0.1:1337")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(theme.springAnimation().delay(0.24), value: hasAppeared)
                }
            }

            VStack(spacing: 10) {
                Button {
                    Task { await configureOsaurusProvider() }
                } label: {
                    HStack(spacing: 8) {
                        if isConfiguringOsaurus || openClawManager.isGatewayConnectionPending {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "server.rack")
                        }
                        Text(
                            isConfiguringOsaurus
                                ? "Configuring Osaurus..."
                                : (openClawManager.isGatewayConnectionPending ? "Waiting for Gateway..." : "Use Osaurus Local Inference")
                        )
                    }
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.62, blue: 0.56), Color(red: 0.08, green: 0.44, blue: 0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isConfiguringOsaurus || openClawManager.isGatewayConnectionPending)

                Button {
                    showingProviderSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Provider")
                    }
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if openClawManager.isGatewayConnectionPending {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 12))
                        Text(openClawManager.gatewayConnectionReadinessMessage ?? "Gateway is connecting…")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    }
                    .foregroundColor(theme.warningColor)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)

            if let setupSuccessMessage {
                Text(setupSuccessMessage)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.successColor)
            }

            if let setupErrorMessage {
                Text(setupErrorMessage)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Ollama Detection

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
            // Ollama not running — no hint shown
        }
    }

    private func probeOsaurus() async {
        guard let url = URL(string: "http://127.0.0.1:1337/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                await MainActor.run { osaurusDetected = true }
            }
        } catch {
            // Osaurus server not running yet.
        }
    }

    private func configureOsaurusProvider() async {
        isConfiguringOsaurus = true
        setupSuccessMessage = nil
        setupErrorMessage = nil
        defer { isConfiguringOsaurus = false }

        let preset = OpenClawProviderPreset.osaurus

        do {
            if !openClawManager.isConnected && openClawManager.gatewayStatus == .running {
                try await openClawManager.connect()
            }

            let discoveredModelCount = try await openClawManager.addProvider(
                id: preset.providerId,
                baseUrl: preset.baseUrl,
                apiCompatibility: preset.apiCompatibility,
                apiKey: nil,
                seedModelsFromEndpoint: true,
                requireSeededModels: true
            )

            await probeOsaurus()
            setupSuccessMessage =
                "Osaurus Local provider added with \(discoveredModelCount) model\(discoveredModelCount == 1 ? "" : "s")."
        } catch {
            let message = error.localizedDescription
            let lowered = message.lowercased()
            if lowered.contains("exist") || lowered.contains("already") {
                await openClawManager.refreshStatus()
                try? await openClawManager.fetchConfiguredProviders()
                await probeOsaurus()
                setupSuccessMessage = "Osaurus Local provider is already configured."
                return
            }
            if lowered.contains("gateway connection is not established") {
                setupErrorMessage = "Gateway is still connecting. Wait for the OpenClaw connected notification, then retry."
            } else {
                setupErrorMessage = message
            }
        }
    }
}
