//
//  WorkView.swift
//  osaurus
//
//  Main view for work mode - displays task execution with issue tracking.
//

import CoreText
import SwiftUI
import UniformTypeIdentifiers

enum WorkEmptyStateRoute: Equatable {
    case openClawSetup
    case openClawOnboardingRequired
    case providerLoading
    case providerNeeded
    case workEmpty
}

enum WorkEmptyStateLogic {
    static func route(
        phase: OpenClawPhase,
        requiresLocalOnboardingGate: Bool,
        hasOpenClawModels: Bool,
        hasCompletedInitialModelHydration: Bool,
        isGatewayConnectionPending: Bool
    ) -> WorkEmptyStateRoute {
        switch phase {
        case .connected, .connecting, .reconnecting:
            break
        case .notConfigured,
             .checkingEnvironment,
             .environmentBlocked,
             .installingCLI,
             .configured,
             .startingGateway,
             .gatewayRunning,
             .gatewayFailed,
             .connectionFailed:
            return .openClawSetup
        }

        if requiresLocalOnboardingGate {
            return .openClawOnboardingRequired
        }

        if hasOpenClawModels {
            return .workEmpty
        }

        if !hasCompletedInitialModelHydration || isGatewayConnectionPending {
            return .providerLoading
        }

        return .providerNeeded
    }
}

enum WorkToolActivityPresentation {
    static func displayName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "invalid_tool_name"
        }
        let pattern = "^[A-Za-z0-9._:-]{1,80}$"
        if trimmed.range(of: pattern, options: .regularExpression) != nil {
            return trimmed
        }
        return "invalid_tool_name"
    }

    static func detail(for tool: ToolCallActivity) -> String? {
        if let result = tool.result, !result.isEmpty {
            if tool.status == .failed, let summarized = summarizeFailure(result) {
                return summarized
            }
            return clean(result, limit: 140)
        }
        if !tool.argsSummary.isEmpty {
            return clean(tool.argsSummary, limit: 140)
        }
        return nil
    }

    private static func summarizeFailure(_ value: String) -> String? {
        let cleaned = clean(value, limit: 320)
        if let missingPath = firstMatch(
            in: cleaned,
            pattern: #"ENOENT: no such file or directory, access '([^']+)'"#
        ) {
            return "Missing file: \(missingPath)"
        }
        if let status = firstMatch(
            in: cleaned,
            pattern: #"Web fetch failed \((\d{3})\)"#
        ) {
            return "Web fetch failed (HTTP \(status))"
        }
        if let status = firstMatch(
            in: cleaned,
            pattern: #""status"\s*:\s*"([A-Za-z0-9_-]+)""#
        ),
            status.lowercased() == "error"
        {
            if let errorMessage = firstMatch(
                in: cleaned,
                pattern: #""error"\s*:\s*"([^"]+)""#
            ) {
                return clean(errorMessage, limit: 160)
            }
        }
        return clean(cleaned, limit: 160)
    }

    private static func clean(_ value: String, limit: Int) -> String {
        let condensed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard condensed.count > limit else {
            return condensed
        }
        return String(condensed.prefix(limit))
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

struct WorkView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: WorkSession
    @ObservedObject private var openClawManager = OpenClawManager.shared

    @State private var isPinnedToBottom: Bool = true
    @State private var scrollToBottomTrigger: Int = 0

    @State private var progressSidebarWidth: CGFloat = 280
    @State private var isProgressSidebarCollapsed: Bool = false
    @State private var selectedArtifact: Artifact?
    @State private var fileOperations: [WorkFileOperation] = []
    @State private var memorySnapshot: IssueTrackerPanel.MemorySnapshot?
    @State private var memoryIsLoading = false
    @State private var lastMemoryRefreshAt: Date = .distantPast

    private let minProgressSidebarWidth: CGFloat = 200
    private let maxProgressSidebarWidth: CGFloat = 400

    private var theme: ThemeProtocol { windowState.theme }

    private var openClawModelOptions: [ModelOption] {
        session.modelOptions.filter { $0.id.hasPrefix(OpenClawModelService.modelPrefix) }
    }

    private var selectedModelReady: Bool {
        guard let selected = session.selectedModel else { return true }
        return openClawManager.isProviderReady(forModelId: selected)
    }

    private var focusedActivityItems: [ActivityItem] {
        openClawManager.activityStore.timelineItemsForFocusedRun(limit: 80)
    }

    private var latestStreamingActivity: (text: String, isStreaming: Bool) {
        ShimmerTextTickerLogic.latestStreamingActivity(from: focusedActivityItems)
    }

    private var shouldShowStreamingTicker: Bool {
        guard session.isExecuting else { return false }
        guard session.activeIssue?.id == session.selectedIssueId else { return false }
        return true
    }

    private var sidebarStepItems: [IssueTrackerPanel.StepItem] {
        focusedActivityItems.compactMap { item -> IssueTrackerPanel.StepItem? in
            switch item.kind {
            case .toolCall(let tool):
                let humanName = Self.humanReadableToolName(tool.name)
                let subtitle = tool.argsSummary.isEmpty ? nil : String(tool.argsSummary.prefix(80))
                let status: IssueTrackerPanel.StepStatus = switch tool.status {
                case .pending: .pending
                case .running: .running
                case .completed: .completed
                case .failed: .failed
                }
                return IssueTrackerPanel.StepItem(
                    id: item.id.uuidString,
                    title: humanName,
                    subtitle: subtitle,
                    status: status,
                    duration: tool.duration
                )
            case .thinking(let thinking):
                let status: IssueTrackerPanel.StepStatus = thinking.isStreaming ? .running : .completed
                return IssueTrackerPanel.StepItem(
                    id: item.id.uuidString,
                    title: "Reasoning...",
                    subtitle: nil,
                    status: status,
                    duration: thinking.duration
                )
            case .lifecycle(let lifecycle):
                switch lifecycle.phase {
                case .started:
                    return IssueTrackerPanel.StepItem(
                        id: item.id.uuidString,
                        title: "Run started",
                        subtitle: nil,
                        status: .completed,
                        duration: nil
                    )
                case .ended:
                    return IssueTrackerPanel.StepItem(
                        id: item.id.uuidString,
                        title: "Run completed",
                        subtitle: nil,
                        status: .completed,
                        duration: nil
                    )
                case .error(let message):
                    return IssueTrackerPanel.StepItem(
                        id: item.id.uuidString,
                        title: "Error",
                        subtitle: String(message.prefix(80)),
                        status: .failed,
                        duration: nil
                    )
                }
            case .assistant, .compaction:
                return nil
            }
        }
    }

    static func humanReadableToolName(_ rawName: String) -> String {
        let lowered = rawName.lowercased()
        if lowered.contains("read") { return "Read file" }
        if lowered.contains("write") { return "Write file" }
        if lowered.contains("edit") { return "Edit file" }
        if lowered.contains("bash") || lowered.contains("exec") { return "Run command" }
        if lowered.contains("glob") { return "Search files" }
        if lowered.contains("grep") || lowered.contains("search") { return "Search content" }
        if lowered.contains("task") { return "Run task" }
        return WorkToolActivityPresentation.displayName(rawName)
    }

    private var sidebarActionItems: [IssueTrackerPanel.ActionItem] {
        let mapped = focusedActivityItems.compactMap { item -> IssueTrackerPanel.ActionItem? in
            switch item.kind {
            case .toolCall(let tool):
                let level: IssueTrackerPanel.ActionLevel = switch tool.status {
                case .failed: .error
                case .completed: .success
                case .running, .pending: .info
                }
                let detail = WorkToolActivityPresentation.detail(for: tool)
                let displayName = WorkToolActivityPresentation.displayName(tool.name)
                return IssueTrackerPanel.ActionItem(
                    id: "tool-\(item.id.uuidString)",
                    timestamp: item.timestamp,
                    title: "Tool: \(displayName)",
                    detail: detail,
                    level: level
                )

            case .lifecycle(let lifecycle):
                switch lifecycle.phase {
                case .started:
                    return IssueTrackerPanel.ActionItem(
                        id: "lifecycle-\(item.id.uuidString)",
                        timestamp: item.timestamp,
                        title: "Run started",
                        detail: "Run ID: \(lifecycle.runId)",
                        level: .info
                    )
                case .ended:
                    return IssueTrackerPanel.ActionItem(
                        id: "lifecycle-\(item.id.uuidString)",
                        timestamp: item.timestamp,
                        title: "Run completed",
                        detail: nil,
                        level: .success
                    )
                case .error(let message):
                    return IssueTrackerPanel.ActionItem(
                        id: "lifecycle-\(item.id.uuidString)",
                        timestamp: item.timestamp,
                        title: "Run failed",
                        detail: message,
                        level: .error
                    )
                }

            case .compaction(let compaction):
                let title: String = switch compaction.phase {
                case .started: "Compaction started"
                case .ended: "Compaction completed"
                case .willRetry: "Compaction retry scheduled"
                }
                let level: IssueTrackerPanel.ActionLevel = switch compaction.phase {
                case .willRetry: .warning
                case .started: .info
                case .ended: .success
                }
                return IssueTrackerPanel.ActionItem(
                    id: "compaction-\(item.id.uuidString)",
                    timestamp: item.timestamp,
                    title: title,
                    detail: nil,
                    level: level
                )

            case .thinking(let thinking):
                guard let detail = summarizedTimelineText(thinking.text) else { return nil }
                return IssueTrackerPanel.ActionItem(
                    id: "thinking-\(item.id.uuidString)",
                    timestamp: item.timestamp,
                    title: thinking.isStreaming ? "Reasoning update" : "Reasoning complete",
                    detail: detail,
                    level: .info
                )

            case .assistant(let assistant):
                let textDetail = summarizedTimelineText(assistant.text)
                let mediaDetail: String?
                if assistant.mediaUrls.isEmpty {
                    mediaDetail = nil
                } else {
                    let label = assistant.mediaUrls.count == 1 ? "attachment" : "attachments"
                    mediaDetail = "\(assistant.mediaUrls.count) media \(label)"
                }
                let detail = [textDetail, mediaDetail].compactMap { $0 }.joined(separator: " · ")
                guard !detail.isEmpty else { return nil }
                return IssueTrackerPanel.ActionItem(
                    id: "assistant-\(item.id.uuidString)",
                    timestamp: item.timestamp,
                    title: assistant.isStreaming ? "Response drafting" : "Response update",
                    detail: detail,
                    level: .info
                )
            }
        }

        return Array(mapped.suffix(24).reversed())
    }

    private var sidebarWrittenFiles: [IssueTrackerPanel.WrittenFileItem] {
        var byPath: [String: IssueTrackerPanel.WrittenFileItem] = [:]
        for item in focusedActivityItems {
            guard case .toolCall(let tool) = item.kind else { continue }
            guard isFileMutationTool(tool.name) else { continue }
            for path in extractedPaths(from: tool) {
                let candidate = IssueTrackerPanel.WrittenFileItem(
                    id: path,
                    path: path,
                    toolName: tool.name,
                    timestamp: item.timestamp,
                    status: tool.status
                )
                if let current = byPath[path], current.timestamp > candidate.timestamp {
                    continue
                }
                byPath[path] = candidate
            }
        }
        return byPath.values.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = windowState.showSidebar ? 240 : 0
            let mainWidth = proxy.size.width - sidebarWidth

            HStack(alignment: .top, spacing: 0) {
                if windowState.showSidebar {
                    WorkTaskSidebar(
                        tasks: windowState.workTasks,
                        currentTaskId: session.currentTask?.id,
                        onSelect: { task in Task { await session.loadTask(task) } },
                        onDelete: { taskId in
                            Task {
                                try? await IssueManager.shared.deleteTask(taskId)
                                windowState.refreshWorkTasks()
                                if session.currentTask?.id == taskId {
                                    session.currentTask = nil
                                    session.issues = []
                                }
                            }
                        }
                    )
                    .padding(.top, 0)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    agentBackground

                    VStack(spacing: 0) {
                        agentHeader

                        if session.currentTask == nil {
                            agentEmptyState
                        } else {
                            taskExecutionView(width: mainWidth)
                        }
                        FloatingInputCard(
                            text: $session.input,
                            selectedModel: $session.selectedModel,
                            pendingImages: .constant([]),
                            isContinuousVoiceMode: .constant(false),
                            voiceInputState: .constant(.idle),
                            showVoiceOverlay: .constant(false),
                            modelOptions: openClawModelOptions,
                            isStreaming: session.isExecuting,
                            supportsImages: false,
                            estimatedContextTokens: session.estimatedContextTokens,
                            onSend: { Task { await session.handleUserInput() } },
                            onStop: { session.stopExecution() },
                            agentId: windowState.agentId,
                            windowId: windowState.windowId,
                            workInputState: session.inputState,
                            pendingQueuedMessage: session.pendingQueuedMessage,
                            onClearQueued: { session.clearQueuedMessage() },
                            onEndTask: { session.endTask() },
                            onResume: { Task { await session.resumeSelectedIssue() } },
                            canResume: session.canResumeSelectedIssue,
                            cumulativeTokens: session.cumulativeTokens,
                            hideContextIndicator: session.currentTask == nil,
                            modelReady: selectedModelReady
                        )
                    }
                }
                .frame(width: mainWidth)
            }
        }
        .frame(minWidth: 800, idealWidth: 950)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea()
        .animation(theme.springAnimation(responseMultiplier: 0.9), value: windowState.showSidebar)
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $selectedArtifact) { artifact in
            ArtifactViewerSheet(
                artifact: artifact,
                onDownload: { downloadArtifact(artifact) },
                onDismiss: { selectedArtifact = nil }
            )
            .environment(\.theme, windowState.theme)
        }
        .onChange(of: session.currentTask?.id) {
            refreshFileOperations()
        }
        .onAppear {
            refreshFileOperations()
            if openClawManager.isConnected {
                Task {
                    await openClawManager.refreshOnboardingState(force: true)
                    try? await openClawManager.fetchConfiguredProviders()
                    await refreshMemorySnapshot(force: true)
                }
            } else if openClawManager.gatewayStatus == .running {
                Task {
                    try? await openClawManager.connect()
                    await openClawManager.refreshOnboardingState(force: true)
                    try? await openClawManager.fetchConfiguredProviders()
                    await refreshMemorySnapshot(force: true)
                }
            }
        }
        .onChange(of: openClawManager.connectionState) {
            if openClawManager.isConnected {
                Task {
                    await openClawManager.refreshOnboardingState(force: true)
                    await refreshMemorySnapshot(force: true)
                }
            } else {
                memorySnapshot = nil
            }
        }
        .onReceive(openClawManager.activityStore.$items) { _ in
            session.applyOpenClawActivityItems(focusedActivityItems)
        }
        .onChange(of: openClawManager.activityStore.items.count) {
            maybeRefreshMemoryFromActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workFileOperationsDidChange)) { _ in
            refreshFileOperations()
        }
    }

    // MARK: - Artifact Actions

    private func viewArtifact(_ artifact: Artifact) {
        selectedArtifact = artifact
    }

    private func downloadArtifact(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.allowedContentTypes =
            artifact.contentType == .markdown
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[WorkView] Failed to save artifact: \(error)")
            }
        }
    }

    // MARK: - File Operations Undo

    private func refreshFileOperations() {
        guard session.currentTask != nil else {
            fileOperations = []
            return
        }

        Task { @MainActor in
            // Collect operations from all issues in the current task
            var allOperations: [WorkFileOperation] = []
            for issue in session.issues {
                let ops = await WorkFileOperationLog.shared.operations(for: issue.id)
                allOperations.append(contentsOf: ops)
            }
            // Sort by timestamp (most recent first for display)
            fileOperations = allOperations.sorted { $0.timestamp > $1.timestamp }
        }
    }

    private func undoFileOperation(_ operationId: UUID) {
        Task {
            // Find which issue this operation belongs to
            for issue in session.issues {
                do {
                    if let _ = try await WorkFileOperationLog.shared.undo(
                        issueId: issue.id,
                        operationId: operationId
                    ) {
                        return  // Notification will trigger refresh
                    }
                } catch {
                    // Operation not in this issue, continue searching
                    continue
                }
            }
        }
    }

    private func undoAllFileOperations() {
        Task {
            for issue in session.issues {
                _ = try? await WorkFileOperationLog.shared.undoAll(issueId: issue.id)
            }
        }
    }

    private func summarizedTimelineText(_ text: String, limit: Int = 160) -> String? {
        let condensed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condensed.isEmpty else { return nil }
        return String(condensed.prefix(limit))
    }

    private func isFileMutationTool(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("write")
            || lowered.contains("edit")
            || lowered.contains("create")
            || lowered.contains("delete")
            || lowered.contains("move")
            || lowered.contains("copy")
            || lowered.contains("rename")
            || lowered.contains("patch")
    }

    private func extractedPaths(from tool: ToolCallActivity) -> [String] {
        let keys = [
            "path", "filePath", "file_path", "filepath", "target", "targetPath",
            "target_path", "source", "sourcePath", "source_path", "destination",
            "destinationPath", "destination_path", "to", "from"
        ]

        var values: [String] = []
        for key in keys {
            if let direct = tool.args[key] {
                values.append(direct)
                continue
            }
            if let fallback = tool.args.first(where: { $0.key.lowercased() == key.lowercased() })?.value {
                values.append(fallback)
            }
        }
        if values.isEmpty, !tool.argsSummary.isEmpty {
            values.append(tool.argsSummary)
        }

        var normalized: [String] = []
        for value in values {
            guard let candidate = normalizedPathCandidate(value) else { continue }
            if !normalized.contains(candidate) {
                normalized.append(candidate)
            }
        }
        return normalized
    }

    private func normalizedPathCandidate(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let first = value.first, first == "\"" || first == "'" || first == "`" {
            value.removeFirst()
        }
        if let last = value.last, last == "\"" || last == "'" || last == "`" {
            value.removeLast()
        }

        guard !value.contains("://") else { return nil }
        if value.hasPrefix("./") {
            value.removeFirst(2)
        }
        guard value.count <= 280 else { return nil }
        guard value.contains("/") || value.contains(".") || value.hasPrefix("~") else { return nil }
        return value
    }

    private func maybeRefreshMemoryFromActivity() {
        guard openClawManager.isConnected else { return }
        guard Date().timeIntervalSince(lastMemoryRefreshAt) > 2 else { return }

        let recentItems = openClawManager.activityStore.items.suffix(5)
        let shouldRefresh = recentItems.contains { item in
            guard case .toolCall(let tool) = item.kind else { return false }
            let paths = extractedPaths(from: tool)
            return paths.contains { path in
                let lower = path.lowercased()
                return lower == "memory.md" || lower.hasSuffix("/memory.md") || lower.contains("/memory/")
            }
        }
        guard shouldRefresh else { return }

        Task { await refreshMemorySnapshot(force: false) }
    }

    private func refreshMemorySnapshot(force: Bool) async {
        guard openClawManager.isConnected else {
            memorySnapshot = nil
            memoryIsLoading = false
            return
        }
        if !force, Date().timeIntervalSince(lastMemoryRefreshAt) < 1.5 {
            return
        }

        memoryIsLoading = true
        defer { memoryIsLoading = false }

        do {
            if let file = try await openClawManager.readAgentMemoryFile() {
                let updatedAt = file.updatedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                memorySnapshot = IssueTrackerPanel.MemorySnapshot(
                    fileName: file.name,
                    content: file.content ?? "",
                    updatedAt: updatedAt,
                    isMissing: file.missing
                )
            } else {
                memorySnapshot = IssueTrackerPanel.MemorySnapshot(
                    fileName: "MEMORY.md",
                    content: "Memory file has not been created yet. It will appear after OpenClaw writes memory.",
                    updatedAt: nil,
                    isMissing: true
                )
            }
            lastMemoryRefreshAt = Date()
        } catch {
            // Keep the last snapshot visible if refresh fails.
            lastMemoryRefreshAt = Date()
        }
    }

    private func viewRuntimeFile(path: String) {
        guard let fileURL = resolvedRuntimeFileURL(path: path) else { return }
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            let filename = fileURL.lastPathComponent.isEmpty ? path : fileURL.lastPathComponent
            selectedArtifact = Artifact(
                taskId: session.currentTask?.id ?? "runtime",
                filename: filename,
                content: content,
                contentType: Artifact.contentType(from: filename),
                isFinalResult: false
            )
            return
        }
        NSWorkspace.shared.open(fileURL)
    }

    private func viewMemorySnapshot() {
        guard let snapshot = memorySnapshot else { return }
        selectedArtifact = Artifact(
            taskId: session.currentTask?.id ?? "runtime",
            filename: snapshot.fileName,
            content: snapshot.content,
            contentType: Artifact.contentType(from: snapshot.fileName),
            isFinalResult: false
        )
    }

    private func resolvedRuntimeFileURL(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        let relative = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        if let root = WorkFolderContextService.shared.currentContext?.rootPath {
            return root.appendingPathComponent(relative)
        }
        return nil
    }

    /// Close this window via ChatWindowManager
    private func closeWindow() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    // MARK: - Background

    private var agentBackground: some View {
        ZStack {
            // Layer 1: Base background (solid, gradient, or image)
            baseBackgroundLayer
                .clipShape(backgroundShape)

            // Layer 2: Glass effect (if enabled)
            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: windowState.showSidebar ? 0 : nil,
                    bottomLeadingRadius: windowState.showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                // Solid backing scaled by glass opacity so low values produce real transparency
                let baseBacking = theme.windowBackingOpacity
                let backingOpacity = baseBacking * (0.4 + theme.glassOpacityPrimary * 0.6)

                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacityPrimary * 0.3),
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacitySecondary * 0.2),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(backgroundShape)
                .allowsHitTesting(false)
            }
        }
    }

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: windowState.showSidebar ? 0 : 24,
            bottomLeadingRadius: windowState.showSidebar ? 0 : 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: 24,
            style: .continuous
        )
    }

    @ViewBuilder
    private var baseBackgroundLayer: some View {
        if let customTheme = theme.customThemeConfig {
            switch customTheme.background.type {
            case .solid:
                Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .image:
                if let image = windowState.cachedBackgroundImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(customTheme.background.imageOpacity ?? 1.0)

                        // Overlay tint for contrast
                        theme.primaryBackground.opacity(0.7)
                    }
                } else {
                    theme.primaryBackground
                }
            }
        } else {
            theme.primaryBackground
        }
    }

    // MARK: - Header

    private var agentHeader: some View {
        // Interactive titlebar controls are hosted in the window's `NSToolbar`.
        // Keep a spacer here so content starts below the titlebar.
        Color.clear
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var agentEmptyState: some View {
        let route = WorkEmptyStateLogic.route(
            phase: openClawManager.phase,
            requiresLocalOnboardingGate: openClawManager.isLocalOnboardingGateRequired,
            hasOpenClawModels: !openClawModelOptions.isEmpty,
            hasCompletedInitialModelHydration: session.hasCompletedInitialModelHydration,
            isGatewayConnectionPending: openClawManager.isGatewayConnectionPending
        )

        switch route {
        case .openClawSetup:
            WorkOpenClawSetupView()
        case .openClawOnboardingRequired:
            WorkOpenClawOnboardingView()
        case .providerLoading:
            WorkProviderLoadingView()
        case .providerNeeded:
            WorkProviderNeededView()
        case .workEmpty:
            WorkEmptyState(
                agents: windowState.agents,
                activeAgentId: windowState.agentId,
                onQuickAction: { prompt in session.input = prompt },
                onSelectAgent: { newAgentId in windowState.switchAgent(to: newAgentId) }
            )
        }
    }

    // MARK: - Task Execution View

    private func taskExecutionView(width: CGFloat) -> some View {
        let collapsedWidth: CGFloat = 48
        // Account for panel trailing padding (12px)
        let expandedWidth = progressSidebarWidth + 12
        let sidebarWidth = isProgressSidebarCollapsed ? collapsedWidth : expandedWidth
        let chatWidth = width - sidebarWidth
        let hasBlocks = !session.issueBlocks.isEmpty

        return HStack(spacing: 0) {
            // Main chat area
            VStack(spacing: 0) {
                // Issue detail view with MessageThreadView
                if session.selectedIssueId != nil && hasBlocks {
                    issueDetailView(width: chatWidth)
                } else if session.selectedIssueId != nil {
                    // Selected issue but no blocks yet (loading or empty)
                    issueEmptyDetailView
                } else {
                    noIssueSelectedView
                }

                if shouldShowStreamingTicker {
                    let activity = latestStreamingActivity
                    ShimmerTextTicker(
                        text: activity.text,
                        isStreaming: activity.isStreaming
                    )
                    .padding(.horizontal, Self.contentHorizontalPadding)
                    .padding(.top, 12)
                }

                if let error = session.errorMessage { errorView(error: error) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if !isProgressSidebarCollapsed {
                IssueTrackerPanel(
                    steps: sidebarStepItems,
                    loopProgress: session.loopState?.progress,
                    loopIteration: session.loopState?.iteration,
                    loopMaxIterations: session.loopState?.maxIterations,
                    finalArtifact: session.finalArtifact,
                    artifacts: session.artifacts,
                    fileOperations: fileOperations,
                    actionItems: sidebarActionItems,
                    writtenFiles: sidebarWrittenFiles,
                    memorySnapshot: memorySnapshot,
                    memoryIsLoading: memoryIsLoading,
                    isCollapsed: $isProgressSidebarCollapsed,
                    onArtifactView: { viewArtifact($0) },
                    onArtifactDownload: { downloadArtifact($0) },
                    onUndoOperation: { operationId in undoFileOperation(operationId) },
                    onUndoAllOperations: { undoAllFileOperations() },
                    onWrittenFileView: { path in viewRuntimeFile(path: path) },
                    onRefreshMemory: { Task { await refreshMemorySnapshot(force: true) } },
                    onViewMemory: { viewMemorySnapshot() }
                )
                .frame(width: progressSidebarWidth)
                .padding(.vertical, 12)
                .padding(.trailing, 12)
                .overlay(alignment: .leading) {
                    ProgressSidebarResizeHandle(
                        width: $progressSidebarWidth,
                        minWidth: minProgressSidebarWidth,
                        maxWidth: maxProgressSidebarWidth
                    )
                    .padding(.vertical, 12)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                collapsedProgressSidebar.transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .animation(theme.animationQuick(), value: isProgressSidebarCollapsed)
    }

    // MARK: - No Issue Selected View

    private var noIssueSelectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.point.right")
                .font(theme.font(size: 32, weight: .regular))
                .foregroundColor(theme.tertiaryText)

            Text("Select an issue to view details")
                .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Self.contentHorizontalPadding)
    }

    // MARK: - Collapsed Progress Sidebar

    private var collapsedProgressSidebar: some View {
        CollapsedSidebarButton(onExpand: {
            withAnimation(theme.animationQuick()) {
                isProgressSidebarCollapsed = false
            }
        })
        .padding(.top, 14)
        .padding(.trailing, 14)
        .frame(width: 48, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Collapsed Sidebar Button

private struct CollapsedSidebarButton: View {
    let onExpand: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        Button(action: onExpand) {
            ZStack {
                // Background with subtle glass effect
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.95 : 0.8))

                // Subtle accent gradient on hover
                if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.08),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "sidebar.right")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.tertiaryText)
            }
            .frame(width: 32, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : .clear,
                radius: 8,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("Show progress")
    }
}

// MARK: - WorkView Issue Detail Extension

extension WorkView {
    // MARK: - Constants

    private static let maxChatContentWidth: CGFloat = 700
    private static let contentHorizontalPadding: CGFloat = 20

    // MARK: - Issue Detail View

    private func issueDetailView(width: CGFloat) -> some View {
        let agentName = windowState.cachedAgentDisplayName
        // Calculate content width: available width minus padding, capped at max
        let availableWidth = width - (Self.contentHorizontalPadding * 2)
        let contentWidth = min(availableWidth, Self.maxChatContentWidth)

        let allBlocks = session.issueBlocks
        let groupHeaderMap = session.issueBlocksGroupHeaderMap

        let isStreamingThisIssue = session.isExecuting && session.activeIssue?.id == session.selectedIssueId
        let blocks = allBlocks

        return ZStack(alignment: .bottomTrailing) {
            MessageThreadView(
                blocks: blocks,
                groupHeaderMap: groupHeaderMap,
                width: contentWidth,
                agentName: agentName,
                isStreaming: isStreamingThisIssue,
                lastAssistantTurnId: blocks.last?.turnId,
                autoScrollEnabled: false,
                expandedBlocksStore: session.expandedBlocksStore,
                scrollToBottomTrigger: scrollToBottomTrigger,
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false },
                onCopy: copyTurnContent,
                onClarificationSubmit: { response in
                    Task {
                        await session.submitClarification(response)
                    }
                }
            )
            .frame(maxWidth: contentWidth)

            // Scroll to bottom button
            ScrollToBottomButton(
                isPinnedToBottom: isPinnedToBottom,
                hasTurns: !blocks.isEmpty,
                onTap: {
                    isPinnedToBottom = true
                    scrollToBottomTrigger += 1
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Self.contentHorizontalPadding)
        .padding(.top, 16)
    }

    /// Copy a turn's content to the clipboard
    private func copyTurnContent(turnId: UUID) {
        guard let turn = session.turn(withId: turnId) else { return }
        var textToCopy = ""
        if turn.hasThinking {
            textToCopy += turn.thinking
        }
        if !turn.contentIsEmpty {
            if !textToCopy.isEmpty { textToCopy += "\n\n" }
            textToCopy += turn.content
        }
        guard !textToCopy.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    private var issueEmptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(theme.font(size: 32, weight: .regular))
                .foregroundColor(theme.tertiaryText)

            Text("No execution history")
                .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text("Select an issue to view its details, or run it to see live execution.")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .regular))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Self.contentHorizontalPadding)
    }

    // MARK: - Processing Indicator (moved to ShimmerTextTicker.swift)

    // MARK: - Error View

    private func errorView(error: String) -> some View {
        let friendlyError = humanFriendlyError(error)

        return HStack(spacing: 16) {
            // Error icon
            ZStack {
                Circle()
                    .fill(theme.errorColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(theme.font(size: 20, weight: .regular))
                    .foregroundColor(theme.errorColor)
            }

            // Error content
            VStack(alignment: .leading, spacing: 4) {
                Text(friendlyError.title)
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(friendlyError.message)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .regular))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // Action buttons
            if session.failedIssue != nil {
                Button {
                    Task {
                        let issue = session.failedIssue
                        session.errorMessage = nil
                        session.failedIssue = nil
                        if let issue { await session.executeIssue(issue, withRetry: true) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                        Text("Retry")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                copyErrorMessage(error)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    Text("Copy Error")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                }
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.tertiaryBackground.opacity(0.55))
                )
            }
            .buttonStyle(.plain)

            // Close button
            Button {
                session.errorMessage = nil
                session.failedIssue = nil
            } label: {
                Image(systemName: "xmark")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground.opacity(0.5)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.errorColor.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, Self.contentHorizontalPadding)
        .padding(.top, 12)
    }

    private func humanFriendlyError(_ error: String) -> (title: String, message: String) {
        let lowercased = error.lowercased()

        if lowercased.contains("javascript") || lowercased.contains("browser") {
            return (
                "Browser Error",
                "Something went wrong while interacting with the browser. This might be a temporary issue."
            )
        } else if lowercased.contains("timeout") {
            return ("Request Timed Out", "The operation took too long to complete. Please try again.")
        } else if lowercased.contains("network") || lowercased.contains("connection") {
            return ("Connection Issue", "Unable to connect to the service. Please check your internet connection.")
        } else if lowercased.contains("rate limit") || lowercased.contains("too many") {
            return ("Rate Limited", "Too many requests. Please wait a moment before trying again.")
        } else if lowercased.contains("api") || lowercased.contains("unauthorized") || lowercased.contains("401") {
            return ("Authentication Error", "There was an issue with the API credentials. Please check your settings.")
        } else if lowercased.contains("cancelled") || lowercased.contains("canceled") {
            return ("Task Cancelled", "The operation was stopped before it could complete.")
        } else if lowercased.contains("not found") || lowercased.contains("404") {
            return ("Not Found", "The requested resource could not be found.")
        } else if lowercased.contains("server") || lowercased.contains("500") || lowercased.contains("502")
            || lowercased.contains("503")
        {
            return ("Server Error", "The service is temporarily unavailable. Please try again later.")
        } else {
            return ("Something Went Wrong", error)
        }
    }

    private func copyErrorMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }

    // MARK: - Helpers

    private func statusIcon(for status: WorkTaskStatus) -> String {
        switch status {
        case .active: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private func statusColor(for status: WorkTaskStatus) -> Color {
        switch status {
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}

// MARK: - Progress Sidebar Resize Handle

private struct ProgressSidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false
    @State private var isDragging = false
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        // Invisible hit area that becomes visible on hover
        Rectangle()
            .fill(Color.clear)
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay(
                // Visual indicator only shown on hover/drag
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accentColor.opacity(isHovered || isDragging ? 0.6 : 0))
                    .frame(width: 4)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
                    .animation(.easeOut(duration: 0.15), value: isDragging)
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        // Dragging left increases width, dragging right decreases
                        let newWidth = width - value.translation.width
                        width = min(maxWidth, max(minWidth, newWidth))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, ModeToggleButton, ModeIndicatorBadge are now in SharedHeaderComponents.swift

// MARK: - Download Menu Target

private class DownloadMenuTarget: NSObject {
    var selectedTag: Int = -1

    @objc func itemClicked(_ sender: NSMenuItem) {
        selectedTag = sender.tag
    }
}

// MARK: - Artifact Viewer Sheet

struct ArtifactViewerSheet: View {
    let artifact: Artifact
    let onDownload: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isCopied = false
    @State private var showRawSource = false
    @State private var isHoveringCopy = false
    @State private var isHoveringDownload = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader

            // Content
            GeometryReader { geometry in
                ScrollView {
                    if artifact.contentType == .markdown && !showRawSource {
                        // Rendered markdown view
                        MarkdownMessageView(
                            text: artifact.content,
                            baseWidth: min(geometry.size.width - 80, 800)
                        )
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Raw source view with line numbers
                        sourceCodeView
                            .padding(20)
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(minWidth: 750, idealWidth: 950, maxWidth: 1200)
        .frame(minHeight: 550, idealHeight: 750, maxHeight: 900)
        .background(sheetBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: theme.shadowColor.opacity(0.3), radius: 30, x: 0, y: 10)
    }

    // MARK: - Components

    @ViewBuilder
    private var sheetBackground: some View {
        theme.primaryBackground.opacity(theme.glassEnabled ? 0.95 : 1.0)
    }

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                fileIconView
                fileInfoView
                Spacer(minLength: 20)
                if artifact.contentType == .markdown { viewToggle.fixedSize() }
                actionButtons.fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Rectangle().fill(theme.primaryBorder.opacity(0.1)).frame(height: 1)
        }
    }

    private var fileIconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.2), theme.accentColor.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)

            Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                .font(theme.font(size: 18, weight: .medium))
                .foregroundColor(theme.accentColor)
        }
    }

    private var fileInfoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artifact.filename)
                .font(theme.font(size: CGFloat(theme.bodySize) + 2, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Text(artifact.contentType == .markdown ? "Markdown Document" : "Text File")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var viewToggle: some View {
        HStack(spacing: 2) {
            toggleButton("Rendered", isSelected: !showRawSource) { showRawSource = false }
            toggleButton("Source", isSelected: showRawSource) { showRawSource = true }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.tertiaryBackground.opacity(0.5)))
    }

    private func toggleButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { action() }
        } label: {
            Text(title)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? theme.primaryText : theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.secondaryBackground : Color.clear)
                        .shadow(color: isSelected ? theme.shadowColor.opacity(0.1) : .clear, radius: 2, x: 0, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            copyButton; downloadButton; closeButton
        }
    }

    private var copyButton: some View {
        Button {
            copyToClipboard()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                Text(isCopied ? "Copied" : "Copy")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(isCopied ? theme.successColor : (isHoveringCopy ? theme.primaryText : theme.secondaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isCopied
                            ? theme.successColor.opacity(0.15)
                            : theme.tertiaryBackground.opacity(isHoveringCopy ? 0.8 : 0.5)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(isHoveringCopy ? 0.2 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Copy content to clipboard")
        .onHover { isHoveringCopy = $0 }
        .animation(.easeOut(duration: 0.15), value: isHoveringCopy)
        .animation(.easeOut(duration: 0.2), value: isCopied)
    }

    @ViewBuilder
    private var downloadButton: some View {
        if artifact.contentType == .markdown {
            // Markdown: primary save + PDF export option
            HStack(spacing: 0) {
                Button {
                    onDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        Text("Download")
                            .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    }
                    .foregroundColor(isHoveringDownload ? theme.primaryText : theme.secondaryText)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 16)
                    .opacity(0.3)

                Button {
                    showDownloadMenu()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 4, weight: .bold))
                        .foregroundColor(isHoveringDownload ? theme.primaryText : theme.secondaryText)
                        .padding(.leading, 2)
                        .padding(.trailing, 8)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(isHoveringDownload ? 0.8 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(isHoveringDownload ? 0.2 : 0.1), lineWidth: 1)
            )
            .fixedSize()
            .help("Download as Markdown or PDF")
            .onHover { isHoveringDownload = $0 }
            .animation(.easeOut(duration: 0.15), value: isHoveringDownload)
        } else {
            // Plain text: single download button
            Button {
                onDownload()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    Text("Download")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isHoveringDownload ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.tertiaryBackground.opacity(isHoveringDownload ? 0.8 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(isHoveringDownload ? 0.2 : 0.1), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Download")
            .onHover { isHoveringDownload = $0 }
            .animation(.easeOut(duration: 0.15), value: isHoveringDownload)
        }
    }

    private var closeButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.tertiaryBackground.opacity(0.5)))
                .overlay(Circle().strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var sourceCodeView: some View {
        let lines = artifact.content.components(separatedBy: "\n")
        return HStack(alignment: .top, spacing: 0) {
            // Line numbers
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                    Text("\(index + 1)")
                        .font(.system(size: CGFloat(theme.captionSize), design: .monospaced))
                        .foregroundColor(theme.tertiaryText.opacity(0.5))
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12)
            .background(theme.secondaryBackground.opacity(0.3))

            Rectangle().fill(theme.primaryBorder.opacity(0.1)).frame(width: 1)

            // Scrollable code content
            ScrollView(.horizontal, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: CGFloat(theme.captionSize), design: .monospaced))
                            .foregroundColor(theme.primaryText.opacity(0.9))
                            .frame(height: 20, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .textSelection(.enabled)
            }
        }
        .background(theme.codeBlockBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.content, forType: .string)
        isCopied = true

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private func showDownloadMenu() {
        let menu = NSMenu()
        let target = DownloadMenuTarget()

        let markdownItem = NSMenuItem(
            title: "Save as Markdown",
            action: #selector(DownloadMenuTarget.itemClicked(_:)),
            keyEquivalent: ""
        )
        markdownItem.target = target
        markdownItem.tag = 0
        markdownItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        menu.addItem(markdownItem)

        let pdfItem = NSMenuItem(
            title: "Export as PDF",
            action: #selector(DownloadMenuTarget.itemClicked(_:)),
            keyEquivalent: ""
        )
        pdfItem.target = target
        pdfItem.tag = 1
        pdfItem.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        menu.addItem(pdfItem)

        guard let event = NSApp.currentEvent,
            let contentView = event.window?.contentView
        else { return }
        let locationInView = contentView.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: locationInView, in: contentView)

        switch target.selectedTag {
        case 0: onDownload()
        case 1: exportAsPDF()
        default: break
        }
    }

    private func exportAsPDF() {
        // Create save panel
        let panel = NSSavePanel()
        let baseName = (artifact.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName).pdf"
        panel.allowedContentTypes = [.pdf]

        if panel.runModal() == .OK, let url = panel.url {
            generatePDF(to: url)
        }
    }

    private func generatePDF(to url: URL) {
        // Use NSAttributedString for reliable PDF generation
        let pdfWidth: CGFloat = 612  // US Letter width
        let pdfHeight: CGFloat = 792  // US Letter height
        let margin: CGFloat = 72  // 1 inch margins
        let contentWidth = pdfWidth - (margin * 2)

        // Convert markdown to attributed string
        let attributedString = markdownToAttributedString(artifact.content)

        // Create PDF context
        var mediaBox = CGRect(x: 0, y: 0, width: pdfWidth, height: pdfHeight)

        guard let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            print("[ArtifactViewerSheet] Failed to create PDF context")
            return
        }

        // Calculate text layout
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var currentPosition = 0
        let pageContentHeight = pdfHeight - (margin * 2)

        while currentPosition < attributedString.length {
            context.beginPDFPage(nil)

            // Create frame for this page (CoreText uses bottom-left origin)
            let framePath = CGPath(
                rect: CGRect(x: margin, y: margin, width: contentWidth, height: pageContentHeight),
                transform: nil
            )

            let frameRange = CFRangeMake(currentPosition, 0)
            let frame = CTFramesetterCreateFrame(framesetter, frameRange, framePath, nil)

            // Draw the frame
            CTFrameDraw(frame, context)

            // Get the visible range to advance position
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentPosition += max(visibleRange.length, 1)

            context.endPDFPage()

            // Safety: prevent infinite loop
            if visibleRange.length == 0 {
                break
            }
        }

        context.closePDF()
        print("[ArtifactViewerSheet] PDF saved to \(url.path)")
    }

    private func markdownToAttributedString(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Default paragraph style
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        let defaultFont = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.boldSystemFont(ofSize: 11)
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]

        let h1Font = NSFont.boldSystemFont(ofSize: 20)
        let h2Font = NSFont.boldSystemFont(ofSize: 16)
        let h3Font = NSFont.boldSystemFont(ofSize: 13)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var inTable = false
        var tableRows: [[String]] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Handle code blocks
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeBlockContent.joined(separator: "\n")
                    let codeStyle = NSMutableParagraphStyle()
                    codeStyle.lineSpacing = 2
                    codeStyle.paragraphSpacing = 8
                    result.append(
                        NSAttributedString(
                            string: codeText + "\n\n",
                            attributes: [
                                .font: codeFont,
                                .foregroundColor: NSColor.darkGray,
                                .paragraphStyle: codeStyle,
                            ]
                        )
                    )
                    codeBlockContent = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                continue
            }

            // Handle tables
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                // Check if it's a separator row (|---|---|)
                let isSeparator = trimmed.contains("---") || trimmed.contains(":-")
                if isSeparator { continue }

                // Parse table row
                let cells =
                    trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                if !inTable {
                    inTable = true
                    tableRows = []
                }
                tableRows.append(cells)
                continue
            } else if inTable {
                // End of table - render it
                renderTable(
                    tableRows,
                    to: result,
                    headerFont: boldFont,
                    bodyFont: defaultFont,
                    paragraphStyle: paragraphStyle
                )
                tableRows = []
                inTable = false
            }

            // Headings
            if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                let headingStyle = NSMutableParagraphStyle()
                headingStyle.paragraphSpacing = 12
                headingStyle.paragraphSpacingBefore = index > 0 ? 16 : 0
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: h1Font,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: headingStyle,
                        ]
                    )
                )
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                let headingStyle = NSMutableParagraphStyle()
                headingStyle.paragraphSpacing = 10
                headingStyle.paragraphSpacingBefore = index > 0 ? 14 : 0
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: h2Font,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: headingStyle,
                        ]
                    )
                )
            } else if trimmed.hasPrefix("### ") || trimmed.hasPrefix("#### ") || trimmed.hasPrefix("##### ") {
                var dropCount = 4
                if trimmed.hasPrefix("#### ") { dropCount = 5 }
                if trimmed.hasPrefix("##### ") { dropCount = 6 }
                let text = String(trimmed.dropFirst(dropCount))
                let headingStyle = NSMutableParagraphStyle()
                headingStyle.paragraphSpacing = 8
                headingStyle.paragraphSpacingBefore = index > 0 ? 10 : 0
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: h3Font,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: headingStyle,
                        ]
                    )
                )
            }
            // List items
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                let listStyle = NSMutableParagraphStyle()
                listStyle.lineSpacing = 3
                listStyle.paragraphSpacing = 4
                listStyle.headIndent = 20
                listStyle.firstLineHeadIndent = 10
                let formattedText = applyInlineFormatting(to: text, defaultFont: defaultFont, boldFont: boldFont)
                let bulletAttr = NSMutableAttributedString(
                    string: "•  ",
                    attributes: [.font: defaultFont, .foregroundColor: NSColor.black]
                )
                bulletAttr.append(formattedText)
                bulletAttr.append(NSAttributedString(string: "\n"))
                bulletAttr.addAttribute(
                    .paragraphStyle,
                    value: listStyle,
                    range: NSRange(location: 0, length: bulletAttr.length)
                )
                result.append(bulletAttr)
            }
            // Numbered lists
            else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let text = String(trimmed[match.upperBound...])
                let number = String(trimmed[..<match.upperBound])
                let listStyle = NSMutableParagraphStyle()
                listStyle.lineSpacing = 3
                listStyle.paragraphSpacing = 4
                listStyle.headIndent = 20
                listStyle.firstLineHeadIndent = 10
                let formattedText = applyInlineFormatting(to: text, defaultFont: defaultFont, boldFont: boldFont)
                let numberAttr = NSMutableAttributedString(
                    string: number,
                    attributes: [.font: defaultFont, .foregroundColor: NSColor.black]
                )
                numberAttr.append(formattedText)
                numberAttr.append(NSAttributedString(string: "\n"))
                numberAttr.addAttribute(
                    .paragraphStyle,
                    value: listStyle,
                    range: NSRange(location: 0, length: numberAttr.length)
                )
                result.append(numberAttr)
            }
            // Empty line
            else if trimmed.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
            }
            // Regular text with inline formatting
            else {
                let formattedText = applyInlineFormatting(to: trimmed, defaultFont: defaultFont, boldFont: boldFont)
                formattedText.append(NSAttributedString(string: "\n"))
                formattedText.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: 0, length: formattedText.length)
                )
                result.append(formattedText)
            }
        }

        // Handle remaining table if file ends with table
        if inTable && !tableRows.isEmpty {
            renderTable(
                tableRows,
                to: result,
                headerFont: boldFont,
                bodyFont: defaultFont,
                paragraphStyle: paragraphStyle
            )
        }

        return result
    }

    /// Render a markdown table as formatted text
    private func renderTable(
        _ rows: [[String]],
        to result: NSMutableAttributedString,
        headerFont: NSFont,
        bodyFont: NSFont,
        paragraphStyle: NSMutableParagraphStyle
    ) {
        guard !rows.isEmpty else { return }

        let tableStyle = NSMutableParagraphStyle()
        tableStyle.lineSpacing = 2
        tableStyle.paragraphSpacing = 4

        // Add some spacing before table
        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))

        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex == 0
            let font = isHeader ? headerFont : bodyFont

            // Format row as tab-separated values
            let rowText = row.map { cell in
                // Clean up cell content - apply inline formatting
                var cleanCell =
                    cell
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")

                // Handle markdown links: [text](url) -> text
                if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []) {
                    cleanCell = linkRegex.stringByReplacingMatches(
                        in: cleanCell,
                        options: [],
                        range: NSRange(cleanCell.startIndex..., in: cleanCell),
                        withTemplate: "$1"
                    )
                }
                return cleanCell
            }.joined(separator: "    |    ")

            let rowAttr = NSMutableAttributedString(
                string: rowText + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: tableStyle,
                ]
            )
            result.append(rowAttr)

            // Add underline after header
            if isHeader {
                let separator = String(repeating: "─", count: min(rowText.count, 60))
                result.append(
                    NSAttributedString(
                        string: separator + "\n",
                        attributes: [
                            .font: bodyFont,
                            .foregroundColor: NSColor.gray,
                            .paragraphStyle: tableStyle,
                        ]
                    )
                )
            }
        }

        // Add spacing after table
        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
    }

    /// Apply inline formatting (bold, italic, code, links) to text
    private func applyInlineFormatting(to text: String, defaultFont: NSFont, boldFont: NSFont)
        -> NSMutableAttributedString
    {
        var processedText = text

        // Handle markdown links: [text](url) -> text
        if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []) {
            processedText = linkRegex.stringByReplacingMatches(
                in: processedText,
                options: [],
                range: NSRange(processedText.startIndex..., in: processedText),
                withTemplate: "$1"
            )
        }

        let result = NSMutableAttributedString()

        // Simple bold detection: split by ** and alternate
        let boldParts = processedText.components(separatedBy: "**")
        for (index, part) in boldParts.enumerated() {
            if part.isEmpty { continue }
            let isBold = index % 2 == 1
            let font = isBold ? boldFont : defaultFont
            result.append(
                NSAttributedString(
                    string: part,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.black,
                    ]
                )
            )
        }

        // If no bold markers were found, just use the processed text
        if boldParts.count <= 1 {
            return NSMutableAttributedString(
                string: processedText,
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: NSColor.black,
                ]
            )
        }

        return result
    }
}

// MARK: - Work Pulse Modifier

struct WorkPulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.4 : 1.0)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}
