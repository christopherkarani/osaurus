//
//  ModelCatalogService.swift
//  osaurus
//
//  Single source of truth for model discovery across Foundation/local/remote/OpenClaw.
//

import Combine
import OpenClawProtocol
import SwiftUI

@MainActor
final class ModelCatalogService: ObservableObject {
    static let shared = ModelCatalogService()

    @Published private(set) var options: [ModelOption] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdatedAt: Date?

    private var cacheValid = false
    private var refreshTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private static let openClawProviderId = UUID(uuidString: "00000000-0000-0000-0000-00000000c1a0")!
    private static let refreshDebounceNanoseconds: UInt64 = 200_000_000

    private init() {
        installObservers()
    }

    func currentOptions(excludingOpenClawSelections: Bool = false) -> [ModelOption] {
        guard excludingOpenClawSelections else { return options }
        return options.filter { !Self.isOpenClawSelectionOption($0.id) }
    }

    func invalidateCache() {
        cacheValid = false
    }

    func refreshIfNeeded() async {
        guard !cacheValid else { return }
        await refresh()
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let built = await Self.buildModelOptions()
            self.options = built
            self.cacheValid = true
            self.lastUpdatedAt = Date()
            self.isRefreshing = false
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func prewarmLocalModelsOnly() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let localOnly = await Self.buildLocalAndFoundationOptions()
            self.options = localOnly
            // Local-only prewarm is intentionally partial.
            self.cacheValid = false
            self.lastUpdatedAt = Date()
        }
    }

    func prewarmModelCache() async {
        await refresh()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .remoteProviderModelsChanged,
            .localModelsChanged,
            .openClawModelsChanged,
            .openClawConnectionChanged,
        ]

        observers = names.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cacheValid = false
                    self?.scheduleRefresh()
                }
            }
        }
    }

    private func scheduleRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refreshIfNeeded()
        }
    }

    private static func isOpenClawSelectionOption(_ id: String) -> Bool {
        id.hasPrefix(OpenClawModelService.modelPrefix)
            || id.hasPrefix(OpenClawModelService.sessionPrefix)
    }

    private static func buildLocalAndFoundationOptions() async -> [ModelOption] {
        var built: [ModelOption] = []

        if AppConfiguration.shared.foundationModelAvailable {
            built.append(.foundation())
        }

        let localModels = await Task.detached(priority: .userInitiated) {
            ModelManager.discoverLocalModels()
        }.value
        for model in localModels {
            built.append(.fromMLXModel(model))
        }

        return built
    }

    private static func buildModelOptions() async -> [ModelOption] {
        var built = await buildLocalAndFoundationOptions()

        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerInfo in remoteModels {
            for modelId in providerInfo.models {
                built.append(
                    .fromRemoteModel(
                        modelId: modelId,
                        providerName: providerInfo.providerName,
                        providerId: providerInfo.providerId
                    )
                )
            }
        }

        if OpenClawManager.shared.isConnected {
            for model in OpenClawManager.shared.availableModels {
                let providerLabel = model.provider.isEmpty ? "OpenClaw Gateway" : model.provider
                let provider = model.provider.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelRef: String = {
                    guard !provider.isEmpty, !modelID.isEmpty else { return modelID }
                    if modelID.hasPrefix("\(provider)/") { return modelID }
                    return "\(provider)/\(modelID)"
                }()
                built.append(
                    .fromRemoteModel(
                        modelId: "\(OpenClawModelService.modelPrefix)\(modelRef)",
                        providerName: providerLabel,
                        providerId: openClawProviderId
                    )
                )
            }
        }

        return built
    }
}
