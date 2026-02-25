//
//  WorkModelSelectorSheet.swift
//  osaurus
//
//  Unified provider + model selector sheet for Work mode.
//  Combines provider setup and model selection into a single,
//  intuitive 3-step experience.
//

import OpenClawProtocol
import SwiftUI

struct WorkModelSelectorSheet: View {
    @Binding var selectedModel: String?
    let currentModels: [ModelOption]

    @ObservedObject private var openClawManager = OpenClawManager.shared
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    // MARK: - Navigation State

    enum Step: Equatable {
        case providerList
        case providerModels(providerId: String, providerName: String)
        case addProvider(preset: OpenClawProviderPreset)

        static func == (lhs: Step, rhs: Step) -> Bool {
            switch (lhs, rhs) {
            case (.providerList, .providerList):
                return true
            case let (.providerModels(lId, _), .providerModels(rId, _)):
                return lId == rId
            case let (.addProvider(lPreset), .addProvider(rPreset)):
                return lPreset == rPreset
            default:
                return false
            }
        }
    }

    @State private var currentStep: Step = .providerList
    @State private var searchText = ""
    @State private var apiKey = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var ollamaDetected = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
                .background(theme.primaryBorder)

            ZStack {
                switch currentStep {
                case .providerList:
                    providerListView
                        .transition(stepTransition)
                case .providerModels(let providerId, let providerName):
                    providerModelsView(providerId: providerId, providerName: providerName)
                        .transition(stepTransition)
                case .addProvider(let preset):
                    addProviderView(preset: preset)
                        .transition(stepTransition)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: currentStep)
        }
        .frame(width: 560, height: 580)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Transitions

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 30)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -30)).combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            if currentStep != .providerList {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep = .providerList
                        searchText = ""
                        apiKey = ""
                        addError = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Providers")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.secondaryBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch currentStep {
        case .providerList:
            return "Providers"
        case .providerModels(_, let name):
            return name
        case .addProvider(let preset):
            return "Add \(preset.displayName)"
        }
    }

    // MARK: - Step 1: Provider List

    private var providerListView: some View {
        VStack(spacing: 0) {
            searchBar

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    if !connectedProviders.isEmpty {
                        connectedSection
                    }

                    if !unconfiguredPresets.isEmpty {
                        addSection
                    }

                    if connectedProviders.isEmpty && unconfiguredPresets.isEmpty {
                        emptyState
                    }

                    // Inline model search results when searching
                    if !searchText.isEmpty {
                        inlineModelResults
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Search providers or models...")
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                }
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.inputBackground)
        .overlay(
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Connected Section

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONNECTED")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            ForEach(connectedProviders) { provider in
                connectedProviderCard(provider)
            }
        }
    }

    private func connectedProviderCard(_ provider: OpenClawManager.ProviderInfo) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStep = .providerModels(providerId: provider.id, providerName: provider.name)
                searchText = ""
            }
        } label: {
            HStack(spacing: 14) {
                providerGradientIcon(for: provider.id, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    HStack(spacing: 6) {
                        Text("\(provider.modelCount) model\(provider.modelCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)

                        Circle()
                            .fill(readinessColor(provider.readinessReason))
                            .frame(width: 5, height: 5)

                        if !provider.isReady {
                            Text(provider.readinessReason.shortLabel)
                                .font(.system(size: 10))
                                .foregroundColor(readinessColor(provider.readinessReason))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Section

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD A PROVIDER")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            ForEach(unconfiguredPresets) { preset in
                unconfiguredPresetCard(preset)
            }
        }
    }

    private func unconfiguredPresetCard(_ preset: OpenClawProviderPreset) -> some View {
        HStack(spacing: 14) {
            presetGradientIcon(preset, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Text(preset.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentStep = .addProvider(preset: preset)
                    apiKey = ""
                    addError = nil
                }
            } label: {
                Text("Add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(theme.accentColor.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Inline Model Search Results

    private var inlineModelResults: some View {
        let matchingModels = filteredModels
        return Group {
            if !matchingModels.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MODELS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)

                    ForEach(matchingModels.prefix(8), id: \.id) { model in
                        modelResultRow(model)
                    }

                    if matchingModels.count > 8 {
                        Text("\(matchingModels.count - 8) more \u{2014} open provider to see all")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func modelResultRow(_ model: OpenClawProtocol.ModelChoice) -> some View {
        Button {
            selectModel(model)
        } label: {
            HStack(spacing: 12) {
                providerGradientIcon(for: model.provider, size: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(model.provider)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                if let ctx = model.contextwindow, ctx > 0 {
                    Text(formatContextWindow(ctx))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.secondaryBackground)
                        )
                }

                if model.reasoning == true {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundColor(.purple.opacity(0.8))
                }

                let modelId = selectionIdentifier(for: model)
                if selectedModel == modelId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.secondaryBackground)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText)
            Text("No providers found")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text("Try a different search or add a provider.")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Step 2: Provider Models

    private func providerModelsView(providerId: String, providerName: String) -> some View {
        let models = modelsForProvider(providerId)
        return VStack(spacing: 0) {
            // Provider header
            HStack(spacing: 12) {
                providerGradientIcon(for: providerId, size: 32)
                Text("\(models.count) model\(models.count == 1 ? "" : "s") available")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            searchBar

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(filteredModelsForProvider(providerId), id: \.id) { model in
                        providerModelRow(model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func providerModelRow(_ model: OpenClawProtocol.ModelChoice) -> some View {
        let modelId = selectionIdentifier(for: model)
        let isSelected = selectedModel == modelId

        return Button {
            selectModel(model)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let ctx = model.contextwindow, ctx > 0 {
                            Text(formatContextWindow(ctx))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(theme.secondaryBackground)
                                )
                        }

                        if model.reasoning == true {
                            HStack(spacing: 3) {
                                Image(systemName: "brain")
                                    .font(.system(size: 9))
                                Text("Reasoning")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.purple.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.purple.opacity(0.08))
                            )
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                } else {
                    Circle()
                        .stroke(theme.primaryBorder, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? theme.accentColor.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: Add Provider

    private func addProviderView(preset: OpenClawProviderPreset) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Provider header
                HStack(spacing: 14) {
                    presetGradientIcon(preset, size: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(preset.description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                .padding(.bottom, 4)

                // API key field
                if preset.showsKeyField {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API KEY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .tracking(0.5)

                        ProviderSecureField(
                            placeholder: preset.needsKey ? "sk-..." : "Optional",
                            text: $apiKey
                        )

                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                            Text("Stored in Keychain")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }

                // Ollama detection
                if preset.isLocal {
                    ollamaStatusSection
                }

                // Help section
                if preset.needsKey || !preset.consoleURL.isEmpty {
                    helpSection(for: preset)
                }

                // Error
                if openClawManager.isGatewayConnectionPending {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(openClawManager.gatewayConnectionReadinessMessage ?? "Gateway is connecting…")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Provider setup unlocks once OpenClaw is connected.")
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundColor(theme.warningColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.warningColor.opacity(0.08))
                    )
                }

                if let error = addError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.errorColor)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                            .lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.errorColor.opacity(0.08))
                    )
                }

                // Add button
                Button {
                    Task { await addProviderAction(preset) }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else if openClawManager.isGatewayConnectionPending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(
                            isAdding
                                ? "Connecting..."
                                : (openClawManager.isGatewayConnectionPending ? "Waiting for Gateway..." : "Add & Connect")
                        )
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(canAddProvider(preset) ? theme.accentColor : theme.accentColor.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAdding || openClawManager.isGatewayConnectionPending || !canAddProvider(preset))
            }
            .padding(20)
        }
        .onAppear {
            if preset.isLocal {
                Task { await probeOllama() }
            }
        }
    }

    // MARK: - Ollama Status

    private var ollamaStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ollamaDetected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                Text(ollamaDetected ? "Ollama is running" : "Ollama not detected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ollamaDetected ? theme.successColor : theme.secondaryText)
            }

            if !ollamaDetected {
                Text("Make sure Ollama is running on port 11434, or download it below.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                Button {
                    if let url = URL(string: "https://ollama.com/download") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Download Ollama")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Help Section

    private func helpSection(for preset: OpenClawProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Don't have a key?")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                helpStep(number: 1, text: "Go to \(preset.displayName) console")
                helpStep(number: 2, text: "Sign in or create an account")
                helpStep(number: 3, text: "Click \"API Keys\" \u{2192} \"Create Key\"")
                helpStep(number: 4, text: "Copy and paste it here")
            }

            if !preset.consoleURL.isEmpty {
                Button {
                    if let url = URL(string: preset.consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open \(preset.displayName) Console")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Gradient Icons

    private func providerGradientIcon(for providerId: String, size: CGFloat) -> some View {
        let preset = presetForProviderId(providerId)
        let colors = preset?.gradient ?? [Color.gray, Color.gray.opacity(0.7)]
        let icon = preset?.systemImage ?? "server.rack"

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    private func presetGradientIcon(_ preset: OpenClawProviderPreset, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: preset.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: preset.systemImage)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Data

    private var connectedProviders: [OpenClawManager.ProviderInfo] {
        let providers = openClawManager.configuredProviders
        guard !searchText.isEmpty else { return providers }
        return providers.filter { SearchService.matches(query: searchText, in: $0.name) }
    }

    private var unconfiguredPresets: [OpenClawProviderPreset] {
        let configuredIds = Set(openClawManager.configuredProviders.map(\.id))
        let presets = OpenClawProviderPreset.allCases.filter {
            $0 != .custom && !configuredIds.contains($0.providerId)
        }
        guard !searchText.isEmpty else { return presets }
        return presets.filter { SearchService.matches(query: searchText, in: $0.displayName) }
    }

    private var filteredModels: [OpenClawProtocol.ModelChoice] {
        guard !searchText.isEmpty else { return [] }
        return openClawManager.availableModels.filter {
            SearchService.matches(query: searchText, in: $0.name) ||
            SearchService.matches(query: searchText, in: $0.id)
        }
    }

    private func modelsForProvider(_ providerId: String) -> [OpenClawProtocol.ModelChoice] {
        openClawManager.availableModels.filter { $0.provider == providerId }
    }

    private func filteredModelsForProvider(_ providerId: String) -> [OpenClawProtocol.ModelChoice] {
        let models = modelsForProvider(providerId)
        guard !searchText.isEmpty else { return models }
        return models.filter {
            SearchService.matches(query: searchText, in: $0.name) ||
            SearchService.matches(query: searchText, in: $0.id)
        }
    }

    private func presetForProviderId(_ id: String) -> OpenClawProviderPreset? {
        OpenClawProviderPreset.allCases.first { $0.providerId == id }
    }

    // MARK: - Actions

    private func selectModel(_ model: OpenClawProtocol.ModelChoice) {
        selectedModel = selectionIdentifier(for: model)
        dismiss()
    }

    private func selectionIdentifier(for model: OpenClawProtocol.ModelChoice) -> String {
        "\(OpenClawModelService.modelPrefix)\(gatewayModelReference(for: model))"
    }

    private func gatewayModelReference(for model: OpenClawProtocol.ModelChoice) -> String {
        let provider = model.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !modelID.isEmpty else {
            return modelID
        }
        if modelID.hasPrefix("\(provider)/") {
            return modelID
        }
        return "\(provider)/\(modelID)"
    }

    private func canAddProvider(_ preset: OpenClawProviderPreset) -> Bool {
        if preset.needsKey {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func addProviderAction(_ preset: OpenClawProviderPreset) async {
        isAdding = true
        addError = nil
        defer { isAdding = false }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String? = trimmedKey.isEmpty ? nil : trimmedKey

        do {
            if !openClawManager.isConnected && openClawManager.gatewayStatus == .running {
                try await openClawManager.connect()
            }

            _ = try await openClawManager.addProvider(
                id: preset.providerId,
                baseUrl: preset.baseUrl,
                apiCompatibility: preset.apiCompatibility,
                apiKey: key,
                seedModelsFromEndpoint: preset.isLocal,
                requireSeededModels: preset == .osaurus
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStep = .providerList
                apiKey = ""
            }
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("gateway connection is not established") {
                addError = "Gateway is still connecting. Wait for the OpenClaw connected notification, then retry."
            } else {
                addError = message
            }
        }
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

    // MARK: - Helpers

    private func readinessColor(_ reason: ProviderReadinessReason) -> Color {
        switch reason {
        case .ready:
            return theme.successColor
        case .noKey, .noModels:
            return theme.warningColor
        case .unreachable, .invalidConfig:
            return theme.errorColor
        }
    }

    private func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M ctx"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K ctx"
        }
        return "\(tokens) ctx"
    }
}
