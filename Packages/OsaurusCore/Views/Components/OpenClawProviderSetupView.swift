//
//  OpenClawProviderSetupView.swift
//  osaurus
//

import SwiftUI

struct OpenClawProviderSetupView: View {
    @ObservedObject var manager: OpenClawManager
    @Environment(\.theme) private var theme

    @State private var selectedPreset: OpenClawProviderPreset?
    @State private var apiKey = ""
    @State private var customBaseUrl = ""
    @State private var customApi = "openai-completions"
    @State private var customId = ""
    @State private var isAdding = false
    @State private var addResult: AddResult?

    enum AddResult: Equatable {
        case success(modelCount: Int)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetGrid
            if let preset = selectedPreset {
                presetForm(preset)
            }
            if let result = addResult {
                resultBanner(result)
            }
        }
    }

    // MARK: - Preset Grid

    private var presetGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
            spacing: 10
        ) {
            ForEach(OpenClawProviderPreset.allCases) { preset in
                presetCard(preset)
            }
        }
    }

    private func presetCard(_ preset: OpenClawProviderPreset) -> some View {
        let isSelected = selectedPreset == preset
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedPreset = preset
                addResult = nil
                apiKey = ""
                customBaseUrl = ""
                customId = ""
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                Text(preset.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : theme.secondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? theme.accentColor.opacity(0.5) : theme.primaryBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Preset Form

    private func presetForm(_ preset: OpenClawProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if preset == .custom {
                customFields
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Text(preset.baseUrl)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
            }

            if preset.showsKeyField {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
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

            if manager.isGatewayConnectionPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(manager.gatewayConnectionReadinessMessage ?? "Gateway is connecting…")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.warningColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.08))
                )
            }

            HeaderPrimaryButton("Add Provider", icon: "plus") {
                Task { await addProvider(preset) }
            }
            .disabled(isAdding || manager.isGatewayConnectionPending || !canAdd(preset))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Provider ID (e.g. my-provider)", text: $customId)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.primaryBorder, lineWidth: 1)
                        )
                )

            TextField("Base URL (e.g. https://api.example.com/v1)", text: $customBaseUrl)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.primaryBorder, lineWidth: 1)
                        )
                )

            Picker("API Compatibility", selection: $customApi) {
                Text("OpenAI Completions").tag("openai-completions")
                Text("Anthropic Messages").tag("anthropic-messages")
                Text("Ollama").tag("ollama")
            }
            .pickerStyle(.segmented)
            .font(.system(size: 12))
        }
    }

    // MARK: - Result Banner

    private func resultBanner(_ result: AddResult) -> some View {
        HStack(spacing: 8) {
            switch result {
            case .success(let modelCount):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.successColor)
                Text("Provider added — \(modelCount) models available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.successColor)
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.errorColor)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(resultColor(result).opacity(0.08))
        )
    }

    private func resultColor(_ result: AddResult) -> Color {
        switch result {
        case .success: return theme.successColor
        case .failure: return theme.errorColor
        }
    }

    // MARK: - Logic

    private func canAdd(_ preset: OpenClawProviderPreset) -> Bool {
        if preset.needsKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if preset == .custom {
            let trimmedId = customId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUrl = customBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedId.isEmpty || trimmedUrl.isEmpty { return false }
        }
        return true
    }

    private func addProvider(_ preset: OpenClawProviderPreset) async {
        isAdding = true
        addResult = nil
        defer { isAdding = false }

        let id: String
        let baseUrl: String
        let api: String
        let key: String?

        if preset == .custom {
            id = customId.trimmingCharacters(in: .whitespacesAndNewlines)
            baseUrl = customBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            api = customApi
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            key = trimmed.isEmpty ? nil : trimmed
        } else {
            id = preset.providerId
            baseUrl = preset.baseUrl
            api = preset.apiCompatibility
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            key = trimmed.isEmpty ? nil : trimmed
        }

        do {
            if !manager.isConnected {
                if manager.gatewayStatus == .running || manager.usesCustomGatewayEndpoint {
                    try await manager.connect()
                } else if manager.isGatewayConnectionPending {
                    throw NSError(
                        domain: "OpenClawProviderSetup",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Gateway is still connecting. Try again in a moment."]
                    )
                } else {
                    throw NSError(
                        domain: "OpenClawProviderSetup",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Start and connect the OpenClaw gateway before adding a provider."]
                    )
                }
            }

            let seededModelCount = try await manager.addProvider(
                id: id,
                baseUrl: baseUrl,
                apiCompatibility: api,
                apiKey: key,
                seedModelsFromEndpoint: preset.isLocal,
                requireSeededModels: preset == .osaurus
            )
            let modelCount = max(seededModelCount, manager.availableModels.filter { $0.provider == id }.count)
            addResult = .success(modelCount: modelCount)
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("gateway connection is not established") {
                addResult = .failure("Gateway is still connecting. Wait for OpenClaw connected, then retry.")
            } else {
                addResult = .failure(message)
            }
        }
    }
}

// MARK: - Provider Presets

enum OpenClawProviderPreset: String, CaseIterable, Identifiable {
    case osaurus
    case openrouter
    case moonshot
    case kimiCoding = "kimi-coding"
    case ollama
    case vllm
    case anthropic
    case openai
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .osaurus: return "Osaurus Local"
        case .openrouter: return "OpenRouter"
        case .moonshot: return "Moonshot (Kimi K2.5)"
        case .kimiCoding: return "Kimi Coding (K2.5)"
        case .ollama: return "Ollama"
        case .vllm: return "vLLM"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .custom: return "Custom"
        }
    }

    var providerId: String {
        rawValue
    }

    var baseUrl: String {
        switch self {
        case .osaurus: return "http://127.0.0.1:1337/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .moonshot: return "https://api.moonshot.ai/v1"
        case .kimiCoding: return "https://api.kimi.com/coding"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .vllm: return "http://127.0.0.1:8000/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var apiCompatibility: String {
        switch self {
        case .osaurus: return "openai-completions"
        case .openrouter, .moonshot, .openai, .vllm: return "openai-completions"
        case .kimiCoding, .anthropic: return "anthropic-messages"
        case .ollama: return "ollama"
        case .custom: return "openai-completions"
        }
    }

    var needsKey: Bool {
        switch self {
        case .osaurus, .ollama, .vllm, .custom: return false
        default: return true
        }
    }

    var showsKeyField: Bool {
        needsKey || self == .custom || self == .vllm
    }

    var systemImage: String {
        switch self {
        case .osaurus: return "server.rack"
        case .openrouter: return "arrow.triangle.branch"
        case .moonshot: return "moon.stars.fill"
        case .kimiCoding: return "terminal.fill"
        case .ollama: return "desktopcomputer"
        case .vllm: return "cpu"
        case .anthropic: return "brain"
        case .openai: return "sparkles"
        case .custom: return "wrench.and.screwdriver"
        }
    }

    var description: String {
        switch self {
        case .osaurus: return "Use Osaurus local models via localhost API"
        case .openrouter: return "Access 200+ models from top providers"
        case .moonshot: return "Use Kimi K2.5 models via Moonshot AI"
        case .kimiCoding: return "Use Kimi Code keys via the Kimi Coding endpoint"
        case .ollama: return "Local models \u{2014} no API key needed"
        case .vllm: return "Local OpenAI-compatible server"
        case .anthropic: return "Claude models from Anthropic"
        case .openai: return "GPT and o-series models"
        case .custom: return "Any OpenAI-compatible endpoint"
        }
    }

    var consoleURL: String {
        switch self {
        case .osaurus: return ""
        case .openrouter: return "https://openrouter.ai/keys"
        case .moonshot: return "https://platform.moonshot.ai/console/api-keys"
        case .kimiCoding: return "https://www.kimi.com/code/en"
        case .ollama: return "https://ollama.com/download"
        case .vllm: return "https://docs.vllm.ai/"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .custom: return ""
        }
    }

    var gradient: [Color] {
        switch self {
        case .osaurus: return [Color(red: 0.12, green: 0.62, blue: 0.56), Color(red: 0.08, green: 0.44, blue: 0.4)]
        case .openrouter: return [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.4, blue: 0.2)]
        case .moonshot: return [Color(red: 0.2, green: 0.45, blue: 0.95), Color(red: 0.14, green: 0.28, blue: 0.75)]
        case .kimiCoding: return [Color(red: 0.1, green: 0.6, blue: 0.7), Color(red: 0.06, green: 0.4, blue: 0.5)]
        case .ollama: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        case .vllm: return [Color(red: 0.3, green: 0.6, blue: 0.8), Color(red: 0.2, green: 0.45, blue: 0.65)]
        case .anthropic: return [Color(red: 0.85, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.4, blue: 0.25)]
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .custom: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        }
    }

    var isLocal: Bool {
        self == .osaurus || self == .ollama || self == .vllm
    }
}
