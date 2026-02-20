//
//  OpenClawCronView.swift
//  osaurus
//

import SwiftUI

struct OpenClawCronView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var manager: OpenClawManager

    @State private var selectedJobID: String?
    @State private var busyJobID: String?
    @State private var actionError: String?
    @State private var hasLoaded = false
    @State private var toggleOverrides: [String: Bool] = [:]

    private var selectedRuns: [OpenClawCronRunLogEntry] {
        guard let selectedJobID else { return [] }
        return manager.cronRunsByJobID[selectedJobID] ?? []
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                schedulerStatusRow

                if manager.cronJobs.isEmpty {
                    Text("No scheduled tasks yet.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    VStack(spacing: 8) {
                        ForEach(manager.cronJobs) { job in
                            cronJobRow(job)
                        }
                    }
                }

                if let selectedJobID {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run History")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.secondaryText)

                        if selectedRuns.isEmpty {
                            Text("No runs found for \(selectedJobID).")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        } else {
                            ForEach(selectedRuns.prefix(8)) { entry in
                                runEntryRow(entry)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if let actionError, !actionError.isEmpty {
                    Text(actionError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            Task {
                await manager.refreshCron()
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Scheduled Tasks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                Task { await manager.refreshCron() }
            }
        }
    }

    private var schedulerStatusRow: some View {
        HStack(spacing: 8) {
            let enabled = manager.cronStatus?.enabled ?? false
            Circle()
                .fill(enabled ? theme.successColor : theme.warningColor)
                .frame(width: 7, height: 7)
            Text(enabled ? "Scheduler enabled" : "Scheduler disabled")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            if let nextWakeAt = manager.cronStatus?.nextWakeAt {
                Text("• Next wake \(Self.relativeDateFormatter.localizedString(for: nextWakeAt, relativeTo: Date()))")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func cronJobRow(_ job: OpenClawCronJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(job.scheduleSummary)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)

                    if let nextRun = job.state.nextRunAt {
                        Text("Next: \(Self.relativeDateFormatter.localizedString(for: nextRun, relativeTo: Date()))")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                Spacer(minLength: 8)

                statusChip(job.state.lastStatus ?? "pending")

                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            OpenClawCronViewLogic.displayedToggleValue(
                                serverEnabled: job.enabled,
                                overrideEnabled: toggleOverrides[job.id]
                            )
                        },
                        set: { enabled in
                            let previous = OpenClawCronViewLogic.displayedToggleValue(
                                serverEnabled: job.enabled,
                                overrideEnabled: toggleOverrides[job.id]
                            )
                            toggleOverrides[job.id] = enabled
                            busyJobID = job.id
                            Task {
                                do {
                                    try await manager.setCronJobEnabled(jobId: job.id, enabled: enabled)
                                    await MainActor.run {
                                        actionError = nil
                                        toggleOverrides[job.id] = OpenClawCronViewLogic
                                            .finalToggleValue(previous: previous, desired: enabled, succeeded: true)
                                        toggleOverrides.removeValue(forKey: job.id)
                                    }
                                } catch {
                                    await manager.refreshCron()
                                    await MainActor.run {
                                        actionError = error.localizedDescription
                                        toggleOverrides[job.id] = OpenClawCronViewLogic
                                            .finalToggleValue(previous: previous, desired: enabled, succeeded: false)
                                        toggleOverrides.removeValue(forKey: job.id)
                                    }
                                }
                                await MainActor.run { busyJobID = nil }
                            }
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel("\(job.displayName) enabled")
                .accessibilityHint("Disabled while schedule update is in progress.")
                .accessibilityValue(
                    OpenClawCronViewLogic.toggleAccessibilityValue(
                        isBusy: busyJobID == job.id,
                        isEnabled: OpenClawCronViewLogic.displayedToggleValue(
                            serverEnabled: job.enabled,
                            overrideEnabled: toggleOverrides[job.id]
                        )
                    )
                )
                .disabled(busyJobID == job.id)

                HeaderSecondaryButton("Run", icon: "play.fill") {
                    busyJobID = job.id
                    Task {
                        do {
                            try await manager.runCronJob(jobId: job.id)
                            await MainActor.run { actionError = nil }
                        } catch {
                            await MainActor.run { actionError = error.localizedDescription }
                        }
                        await MainActor.run { busyJobID = nil }
                    }
                }
                .accessibilityLabel("Run \(job.displayName) now")
                .accessibilityHint("Disabled while the selected task is running.")
                .accessibilityValue(busyJobID == job.id ? "Busy" : "Ready")
                .disabled(busyJobID == job.id)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            selectedJobID == job.id ? theme.accentColor.opacity(0.65) : theme.primaryBorder,
                            lineWidth: 1
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedJobID = job.id
            Task {
                await manager.refreshCronRuns(jobId: job.id)
            }
        }
    }

    @ViewBuilder
    private func runEntryRow(_ entry: OpenClawCronRunLogEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(entry.status))
                .frame(width: 6, height: 6)

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.secondaryText)

            if let summary = normalized(entry.summary) {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            } else {
                Text((entry.status ?? "pending").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor(entry.status))
            }

            Spacer()

            if let durationMs = entry.durationMs {
                Text("\(durationMs)ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusChip(_ status: String) -> some View {
        Text(status.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor(status).opacity(0.12)))
    }

    private func statusColor(_ status: String?) -> Color {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "success":
            return theme.successColor
        case "error", "failed":
            return theme.errorColor
        case "skipped":
            return theme.warningColor
        default:
            return theme.tertiaryText
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum OpenClawCronViewLogic {
    static func displayedToggleValue(serverEnabled: Bool, overrideEnabled: Bool?) -> Bool {
        overrideEnabled ?? serverEnabled
    }

    static func finalToggleValue(previous: Bool, desired: Bool, succeeded: Bool) -> Bool {
        succeeded ? desired : previous
    }

    static func toggleAccessibilityValue(isBusy: Bool, isEnabled: Bool) -> String {
        if isBusy {
            return "Updating"
        }
        return isEnabled ? "Enabled" : "Disabled"
    }
}
