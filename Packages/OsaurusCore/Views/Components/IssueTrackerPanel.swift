//
//  IssueTrackerPanel.swift
//  osaurus
//
//  Sidebar panel displaying issues for the current work task with status indicators.
//

import AppKit
import SwiftUI

extension IssueTrackerPanel {
    enum StepStatus: Equatable {
        case pending
        case running
        case completed
        case failed
    }

    struct StepItem: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let status: StepStatus
        let duration: TimeInterval?
    }

    struct WrittenFileItem: Identifiable, Equatable {
        let id: String
        let path: String
        let toolName: String
        let timestamp: Date
        let status: ActivityStatus
    }

    enum ActionLevel: Equatable {
        case info
        case success
        case warning
        case error
    }

    struct ActionItem: Identifiable, Equatable {
        let id: String
        let timestamp: Date
        let title: String
        let detail: String?
        let level: ActionLevel
    }

    struct MemorySnapshot: Equatable {
        let fileName: String
        let content: String
        let updatedAt: Date?
        let isMissing: Bool
    }
}

struct IssueTrackerPanel: View {
    /// Ordered list of execution steps (tool calls, thinking, lifecycle)
    let steps: [StepItem]
    /// Loop progress fraction (0.0–1.0), nil when not in a loop
    let loopProgress: Double?
    /// Current loop iteration, nil when not looping
    let loopIteration: Int?
    /// Maximum loop iterations, nil when not looping
    let loopMaxIterations: Int?
    /// Final artifact from task completion
    let finalArtifact: Artifact?
    /// All generated artifacts
    let artifacts: [Artifact]
    /// File operations for undo tracking
    let fileOperations: [WorkFileOperation]
    /// Live OpenClaw action feed
    let actionItems: [ActionItem]
    /// Files written/edited by OpenClaw tool calls
    let writtenFiles: [WrittenFileItem]
    /// Current memory file snapshot from OpenClaw agent workspace
    let memorySnapshot: MemorySnapshot?
    /// Whether memory content is currently being refreshed
    let memoryIsLoading: Bool
    /// Binding to control collapse state
    @Binding var isCollapsed: Bool
    /// Called when user wants to view an artifact
    let onArtifactView: (Artifact) -> Void
    /// Called when user wants to download an artifact
    let onArtifactDownload: (Artifact) -> Void
    /// Called when user wants to undo a file operation
    let onUndoOperation: (UUID) -> Void
    /// Called when user wants to undo all file operations
    let onUndoAllOperations: () -> Void
    /// Called when user wants to open/preview a runtime-written file path
    let onWrittenFileView: (String) -> Void
    /// Called when user wants to refresh memory snapshot
    let onRefreshMemory: () -> Void
    /// Called when user wants to view current memory snapshot content
    let onViewMemory: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @Namespace private var stepFeedNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            if steps.isEmpty && finalArtifact == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        progressDashboardSection

                        if let artifact = finalArtifact { resultSection(artifact: artifact) }

                        let additionalArtifacts = artifacts.filter { !$0.isFinalResult }
                        if !additionalArtifacts.isEmpty { artifactsSection(artifacts: additionalArtifacts) }

                        if !writtenFiles.isEmpty { writtenFilesSection }
                        if !actionItems.isEmpty { actionFeedSection }
                        if memorySnapshot != nil || memoryIsLoading { memorySection }
                        if !fileOperations.isEmpty { changedFilesSection }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(panelBorder)
        .compositingGroup()
        .shadow(color: theme.shadowColor.opacity(theme.shadowOpacity * 0.5), radius: 8, x: 0, y: 2)
    }

    // MARK: - Panel Styling

    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            // Layer 1: Glass material (if enabled)
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // Layer 2: Semi-transparent background
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.75 : 0.85))

            // Layer 3: Subtle accent gradient at top
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.05 : 0.03),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.18 : 0.25),
                        theme.primaryBorder.opacity(0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Sections

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }

    private func resultSection(artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").font(.system(size: 12)).foregroundColor(theme.successColor)
                Text("Result").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
                Spacer()

                HStack(spacing: 4) {
                    Button {
                        onArtifactView(artifact)
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.accentColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain).help("View artifact")

                    Button {
                        onArtifactDownload(artifact)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground.opacity(0.5)))
                    }
                    .buttonStyle(.plain).help("Download artifact")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ArtifactPreviewCard(artifact: artifact, onView: { onArtifactView(artifact) })
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private func artifactsSection(artifacts: [Artifact]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundColor(theme.secondaryText)
                Text("Artifacts").font(.system(size: 12, weight: .medium)).foregroundColor(theme.secondaryText)
                Text("(\(artifacts.count))").font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(artifacts) { artifact in
                    ArtifactRow(
                        artifact: artifact,
                        onView: { onArtifactView(artifact) },
                        onDownload: { onArtifactDownload(artifact) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Progress Dashboard (Animated Feed)

    private var progressDashboardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress bar (only when looping)
            if let iteration = loopIteration, let maxIterations = loopMaxIterations, maxIterations > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.tertiaryBackground.opacity(0.5))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.accentColor)
                                .frame(width: max(0, geo.size.width * (loopProgress ?? 0)), height: 4)
                                .animation(.easeInOut(duration: 0.3), value: loopProgress)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 12)

                    HStack {
                        Text("\(Int((loopProgress ?? 0) * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text("\(iteration)/\(maxIterations) iterations")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            // Animated step feed — chronological, newest at bottom, auto-scrolls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(steps) { step in
                            stepFeedRow(step: step)
                                .id(step.id)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .bottom)
                                            .combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .animation(.easeInOut(duration: 0.25), value: steps.count)
                .onChange(of: steps.count) { _ in
                    // Auto-scroll to the newest step
                    if let lastId = steps.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func stepFeedRow(step: StepItem) -> some View {
        let isRunning = step.status == .running
        let isFailed = step.status == .failed

        return HStack(spacing: 8) {
            MorphingStatusIcon(
                state: stepIconState(for: step),
                accentColor: stepIconColor(for: step),
                size: isRunning ? 14 : 12
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: isRunning ? 12 : 11, weight: isRunning ? .semibold : .regular))
                    .foregroundColor(isRunning ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                if isRunning, let subtitle = step.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isRunning {
                Text("...")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            } else if let duration = step.duration {
                Text(Self.formatDuration(duration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(isFailed ? theme.errorColor.opacity(0.7) : theme.tertiaryText)
            } else {
                Text("--")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isRunning ? 8 : 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isRunning ? theme.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isRunning ? theme.accentColor.opacity(0.2) : Color.clear,
                    lineWidth: 1
                )
        )
        .shimmerEffect(isActive: isRunning, accentColor: theme.accentColor)
    }

    private func stepIconState(for step: StepItem) -> StatusIconState {
        switch step.status {
        case .pending: return .pending
        case .running: return .active
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    private func stepIconColor(for step: StepItem) -> Color {
        switch step.status {
        case .pending: return theme.tertiaryText
        case .running: return theme.accentColor
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.1 { return "<0.1s" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }

    private var writtenFilesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.text.below.ecg")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Files Written")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("\(writtenFiles.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.tertiaryBackground.opacity(0.6)))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            VStack(spacing: 6) {
                ForEach(writtenFiles) { file in
                    WrittenFileRow(file: file, onView: { onWrittenFileView(file.path) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var actionFeedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Action Feed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            VStack(spacing: 6) {
                ForEach(actionItems) { item in
                    ActionFeedRow(item: item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()

                Button(action: onRefreshMemory) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Refresh memory file")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if memoryIsLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Refreshing memory…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else if let snapshot = memorySnapshot {
                MemoryRow(snapshot: snapshot, onView: onViewMemory)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Changed Files Section

    private var changedFilesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                // Section icon with subtle background
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.accentColor.opacity(0.1))
                        .frame(width: 20, height: 20)
                    Image(systemName: "doc.badge.clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                Text("Changed Files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("\(fileOperations.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.tertiaryBackground.opacity(0.6)))

                Spacer()

                // Undo All button
                Button {
                    onUndoAllOperations()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Undo All")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.warningColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.warningColor.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.warningColor.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Undo all file changes")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                ForEach(groupedOperations, id: \.path) { group in
                    FileOperationRow(
                        operation: group.latestOperation,
                        operationCount: group.operations.count,
                        onUndo: { onUndoOperation(group.latestOperation.id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    /// Group operations by path, showing the latest operation for each file
    private var groupedOperations: [FileOperationGroup] {
        var groups: [String: [WorkFileOperation]] = [:]
        for op in fileOperations {
            groups[op.path, default: []].append(op)
        }
        return groups.map { path, ops in
            FileOperationGroup(path: path, operations: ops.sorted { $0.timestamp < $1.timestamp })
        }.sorted { $0.latestOperation.timestamp > $1.latestOperation.timestamp }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("Progress")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if !steps.isEmpty {
                let completed = steps.filter { $0.status == .completed || $0.status == .failed }.count
                HStack(spacing: 4) {
                    Text("\(completed)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.successColor)
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text("\(steps.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide progress")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.1))
                .frame(height: 1)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText.opacity(0.6))

            Text("Ready to start")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Artifact Preview Card

private struct ArtifactPreviewCard: View {
    let artifact: Artifact
    let onView: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    /// Preview of content (first few lines)
    private var contentPreview: String {
        let lines = artifact.content.components(separatedBy: .newlines)
        let previewLines = lines.prefix(6)
        let preview = previewLines.joined(separator: "\n")
        if lines.count > 6 {
            return preview + "\n..."
        }
        return preview
    }

    var body: some View {
        Button {
            onView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Filename badge
                HStack(spacing: 4) {
                    Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                        .font(.system(size: 9))
                        .foregroundColor(theme.accentColor)

                    Text(artifact.filename)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.1))
                )

                // Content preview - plain text
                Text(contentPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.6 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Artifact Row

private struct ArtifactRow: View {
    let artifact: Artifact
    let onView: () -> Void
    let onDownload: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        Button {
            onView()
        } label: {
            HStack(spacing: 8) {
                // File icon
                Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                // Filename
                Text(artifact.filename)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                // Action buttons - always rendered, opacity controlled by hover
                // This prevents layout jiggle when hovering
                HStack(spacing: 4) {
                    Button(action: onView) {
                        Image(systemName: "eye")
                            .font(.system(size: 9))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(theme.primaryBackground))
                            .overlay(Circle().stroke(theme.accentColor.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("View")

                    Button(action: onDownload) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(theme.primaryBackground))
                            .overlay(Circle().stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Download")
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? theme.tertiaryBackground.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Written File Row

private struct WrittenFileRow: View {
    let file: IssueTrackerPanel.WrittenFileItem
    let onView: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    private var statusColor: Color {
        switch file.status {
        case .failed:
            return theme.errorColor
        case .running:
            return theme.warningColor
        case .completed:
            return theme.successColor
        case .pending:
            return theme.tertiaryText
        }
    }

    private var filename: String {
        let value = (file.path as NSString).lastPathComponent
        return value.isEmpty ? file.path : value
    }

    var body: some View {
        Button(action: onView) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(file.path)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                    Text(file.toolName)
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.accentColor.opacity(isHovered ? 1 : 0.65))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.45 : 0.3))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Action Feed Row

private struct ActionFeedRow: View {
    let item: IssueTrackerPanel.ActionItem
    @Environment(\.theme) private var theme: ThemeProtocol

    private var accent: Color {
        switch item.level {
        case .info:
            return theme.secondaryText
        case .success:
            return theme.successColor
        case .warning:
            return theme.warningColor
        case .error:
            return theme.errorColor
        }
    }

    private var timeLabel: String {
        Self.timeFormatter.string(from: item.timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(timeLabel)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(0.25))
        )
    }
}

// MARK: - Memory Row

private struct MemoryRow: View {
    let snapshot: IssueTrackerPanel.MemorySnapshot
    let onView: () -> Void
    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    private var previewText: String {
        if snapshot.isMissing {
            return "Memory file has not been created yet. It will appear after OpenClaw writes memory."
        }
        let trimmed = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Memory file is currently empty." }
        return String(trimmed.prefix(180))
    }

    var body: some View {
        Button(action: onView) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text(snapshot.fileName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    if snapshot.isMissing {
                        Text("Not created yet")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Text(previewText)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(4)

                if let updatedAt = snapshot.updatedAt {
                    Text("Updated \(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.45 : 0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - File Operation Group

private struct FileOperationGroup {
    let path: String
    let operations: [WorkFileOperation]

    var latestOperation: WorkFileOperation {
        operations.last!
    }
}

// MARK: - File Operation Row

private struct FileOperationRow: View {
    let operation: WorkFileOperation
    let operationCount: Int
    let onUndo: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    private var fileExtension: String? {
        let ext = (operation.path as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    private var fullURL: URL? {
        WorkFolderContextService.shared.currentContext?.rootPath.appendingPathComponent(operation.path)
    }

    private var fileExists: Bool {
        guard let url = fullURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isClickable: Bool {
        operation.type != .delete && fileExists
    }

    var body: some View {
        HStack(spacing: 0) {
            // Colored left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(iconColor)
                .frame(width: 3)
                .padding(.vertical, 4)

            HStack(spacing: 10) {
                // Operation type icon with background
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: operation.type.iconName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(iconColor)
                }

                // Filename and info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(operation.filename)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isClickable ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)

                        // File extension badge
                        if let ext = fileExtension {
                            Text(ext)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground.opacity(0.6))
                                )
                        }
                    }

                    HStack(spacing: 4) {
                        Text(operation.type.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(iconColor.opacity(0.8))

                        if operationCount > 1 {
                            Text("•")
                                .font(.system(size: 8))
                                .foregroundColor(theme.tertiaryText)
                            Text("\(operationCount) changes")
                                .font(.system(size: 9))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }

                Spacer()

                // Action buttons (visible on hover)
                HStack(spacing: 6) {
                    // Open/Reveal button
                    if isClickable {
                        Button(action: openFile) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.accentColor)
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(theme.accentColor.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open file")
                    }

                    // Undo button
                    Button(action: onUndo) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.warningColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Undo this change")
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? theme.tertiaryBackground.opacity(0.5) : theme.tertiaryBackground.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovered ? theme.primaryBorder.opacity(0.15) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering && isClickable {
                NSCursor.pointingHand.push()
            } else if !hovering {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            if isClickable {
                openFile()
            }
        }
        .contextMenu {
            if isClickable {
                Button {
                    openFile()
                } label: {
                    Label("Open File", systemImage: "arrow.up.forward.square")
                }
                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
            }
            Button {
                onUndo()
            } label: {
                Label("Undo Change", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var iconColor: Color {
        switch operation.type {
        case .create, .dirCreate:
            return theme.successColor
        case .write:
            return theme.accentColor
        case .move, .copy:
            return theme.secondaryText
        case .delete:
            return theme.errorColor
        }
    }

    // MARK: - Actions

    private func openFile() {
        guard let url = fullURL, fileExists else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = fullURL,
            let rootPath = WorkFolderContextService.shared.currentContext?.rootPath
        else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: rootPath.path)
    }
}
