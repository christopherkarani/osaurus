//
//  OpenClawLogViewer.swift
//  osaurus
//

import AppKit
import SwiftUI

public enum OpenClawLogLevel: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case trace
    case debug
    case info
    case warning
    case error
    case critical
    case fatal
    case unknown

    static var knownLevels: [OpenClawLogLevel] {
        [.trace, .debug, .info, .warning, .error, .critical, .fatal]
    }

    var label: String {
        switch self {
        case .trace:
            "Trace"
        case .debug:
            "Debug"
        case .info:
            "Info"
        case .warning:
            "Warn"
        case .error:
            "Error"
        case .critical:
            "Critical"
        case .fatal:
            "Fatal"
        case .unknown:
            "Other"
        }
    }

    static func from(_ raw: String?) -> OpenClawLogLevel {
        guard let raw else { return .unknown }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info", "information", "notice":
            return .info
        case "warn", "warning":
            return .warning
        case "error":
            return .error
        case "critical":
            return .critical
        case "fatal":
            return .fatal
        default:
            return .unknown
        }
    }
}

public struct OpenClawLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let level: OpenClawLogLevel
    public let message: String
    public let timestamp: Date?
    public let rawLine: String

    public init(
        id: UUID = UUID(),
        level: OpenClawLogLevel,
        message: String,
        timestamp: Date?,
        rawLine: String
    ) {
        self.id = id
        self.level = level
        self.message = message
        self.timestamp = timestamp
        self.rawLine = rawLine
    }
}

enum OpenClawLogParser {
    private static let timestampKeyCandidates = ["timestamp", "ts", "time", "@timestamp", "loggedAt", "logTime"]
    private static let messageKeyCandidates = ["message", "msg", "text", "event"]
    private static let levelKeyCandidates = ["level", "severity", "severityText", "logLevel"]

    static func parseLine(_ line: String) -> OpenClawLogEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let object = raw as? [String: Any]
        else {
            return nil
        }

        let rawLevel = levelKeyCandidates
            .compactMap { object[$0] }
            .first(where: { !($0 is NSNull) })
        let level = OpenClawLogLevel.from(parsedLevel(from: rawLevel))

        let message = messageKeyCandidates.compactMap { (key) -> String? in
            guard let value = object[key], !(value is NSNull) else { return nil }
            return "\(value)"
        }.first ?? line.trimmingCharacters(in: .whitespacesAndNewlines)

        let timestamp = parseTimestamp(from: object)

        return OpenClawLogEntry(level: level, message: message, timestamp: timestamp, rawLine: line)
    }

    private static func parsedLevel(from raw: Any?) -> String? {
        if let text = raw as? String {
            return text
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        if let number = raw as? Int {
            return String(number)
        }
        return nil
    }

    static func parseFile(url: URL, limit: Int = 250) -> [OpenClawLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseJSONL(text, limit: limit)
    }

    static func parseJSONL(_ text: String, limit: Int = 250) -> [OpenClawLogEntry] {
        var parsed: [OpenClawLogEntry] = []
        text.enumerateLines { line, _ in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let entry = parseLine(line) {
                parsed.append(entry)
            }
        }
        let limited = parsed.suffix(limit)
        return Array(limited)
    }

    static func filter(_ entries: [OpenClawLogEntry], levels: Set<OpenClawLogLevel>) -> [OpenClawLogEntry] {
        guard levels.count < OpenClawLogLevel.allCases.count else { return entries }
        return entries.filter { levels.contains($0.level) }
    }

    private static func parseTimestamp(from values: [String: Any]) -> Date? {
        for key in timestampKeyCandidates {
            guard let raw = values[key], !(raw is NSNull) else { continue }
            if let text = raw as? String, let parsed = parseISODate(from: text) {
                return parsed
            }
            if let number = raw as? NSNumber {
                return parseDate(fromNumeric: number.doubleValue)
            }
            if let value = raw as? Double {
                return parseDate(fromNumeric: value)
            }
            if let value = raw as? Int {
                return parseDate(fromNumeric: Double(value))
            }
        }
        return nil
    }

    private static func parseISODate(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let date = formatter.date(from: trimmed) {
            return date
        }

        if let iso = ISO8601DateFormatter().date(from: trimmed) {
            return iso
        }

        if let epoch = Double(trimmed) {
            return parseDate(fromNumeric: epoch)
        }

        return nil
    }

    private static func parseDate(fromNumeric value: Double) -> Date {
        let isEpochMs = abs(value) > 10_000_000
        return Date(timeIntervalSince1970: isEpochMs ? (value / 1_000) : value)
    }
}

private let openClawLogMaxDisplay = 250

struct OpenClawLogViewer: View {
    @Environment(\.theme) private var theme

    @State private var entries: [OpenClawLogEntry] = []
    @State private var selectedLevels: Set<OpenClawLogLevel> = Set(OpenClawLogLevel.knownLevels)
    @State private var searchQuery = ""
    @State private var refreshError: String?
    @State private var autoScroll = true
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var isCopySuccess = false
    @State private var hasAppeared = false

    private var hasAnyEntries: Bool {
        !filteredEntries.isEmpty
    }

    private var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("OpenClaw")
            .appendingPathComponent("diagnostics.jsonl")
    }

    private var filteredEntries: [OpenClawLogEntry] {
        let filteredByLevel = OpenClawLogParser.filter(entries, levels: selectedLevels)
        guard !searchQuery.isEmpty else {
            return filteredByLevel
        }
        return filteredByLevel.filter { entry in
            entry.message.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gateway Logs")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        if let pathText = logFilePathLabel {
                            Text(pathText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    Spacer()

                    Button("Copy Logs", systemImage: "doc.on.doc") {
                        copyLogs()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.primaryText)
                    .disabled(filteredEntries.isEmpty)

                    Button("Open Log File", systemImage: "arrow.up.right.square") {
                        openLogFile()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.primaryText)
                    .disabled(!FileManager.default.fileExists(atPath: logFileURL.path))
                }
                .font(.system(size: 11, weight: .medium))

                HStack(spacing: 8) {
                    TextField("Filter message...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            refreshStatus()
                        }

                    Button(action: { refreshStatus() }) {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.7)
                                .help("Refreshing logs")
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .help("Refresh logs")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.accentColor)
                    .disabled(isRefreshing)
                }

                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if refreshError != nil {
                                Text("Failed to read logs")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.errorColor)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background(theme.errorColor.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            if !hasAnyEntries {
                                emptyLogState
                            } else {
                                ForEach(filteredEntries) { entry in
                                    logRow(entry)
                                        .id(entry.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("log-tail")
                        }
                        .onChange(of: filteredEntries) { _, _ in
                            if autoScroll {
                                withAnimation(.linear(duration: 0.18)) {
                                    proxy.scrollTo("log-tail", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: selectedLevels) { _, _ in
                            if autoScroll {
                                withAnimation(.linear(duration: 0.18)) {
                                    proxy.scrollTo("log-tail", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.tertiaryBackground, lineWidth: 1)
                    )
                }

                if !entries.isEmpty {
                    logLevelChips
                }

                if !selectedLevels.isEmpty && selectedLevels.count < OpenClawLogLevel.knownLevels.count {
                    HStack(spacing: 8) {
                        Toggle("Auto scroll to latest", isOn: $autoScroll)
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                        Spacer()
                        if isCopySuccess {
                            Text("Copied")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.successColor)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                hasAppeared = true
            }
            startAutoRefreshLoop()
            refreshStatus()
        }
        .onDisappear {
            stopAutoRefreshLoop()
            hasAppeared = false
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)
    }

    @ViewBuilder
    private var emptyLogState: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(theme.accentColor.opacity(0.14))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "doc.text.magnifyingglass").foregroundColor(theme.accentColor))

            Text("No matching logs.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var logFilePathLabel: String? {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return nil }
        return logFileURL.path
    }

    @ViewBuilder
    private var logLevelChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OpenClawLogLevel.knownLevels, id: \.self) { level in
                    Button {
                        toggle(level)
                    } label: {
                        Text(level.label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(
                                selectedLevels.contains(level) ? theme.primaryText : theme.secondaryText
                            )
                            .background(
                                Capsule()
                                    .fill(selectedLevels.contains(level) ? theme.secondaryBackground : theme.tertiaryBackground)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(levelColor(level).opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Toggle \(level.label)")
                }

                Button {
                    selectedLevels = Set(OpenClawLogLevel.knownLevels)
                } label: {
                    Text("All")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundColor(theme.primaryText)
                        .background(Capsule().fill(theme.accentColor.opacity(0.15)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func logRow(_ entry: OpenClawLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(levelBadge(entry.level))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(levelColor(entry.level))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(
                    Capsule()
                        .stroke(levelColor(entry.level).opacity(0.4), lineWidth: 1)
                )

            Text(entry.timestamp.map(timestampFormatter.string(from:)) ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .frame(width: 130, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(theme.secondaryBackground.opacity(0.45))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(levelColor(entry.level).opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @State private var timestampFormatter = OpenClawLogViewer.makeFormatter()
    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        return f
    }

    private func levelBadge(_ level: OpenClawLogLevel) -> String {
        level.label
    }

    private func levelColor(_ level: OpenClawLogLevel) -> Color {
        switch level {
        case .trace, .debug:
            theme.tertiaryText
        case .info:
            theme.accentColor
        case .warning:
            theme.warningColor
        case .error, .fatal:
            theme.errorColor
        case .critical:
            theme.warningColor
        case .unknown:
            theme.secondaryText
        }
    }

    private func toggle(_ level: OpenClawLogLevel) {
        if selectedLevels.contains(level) {
            selectedLevels.remove(level)
            if selectedLevels.isEmpty {
                selectedLevels = Set(OpenClawLogLevel.knownLevels)
            }
        } else {
            selectedLevels.insert(level)
        }
    }

    private func refreshStatus() {
            guard !isRefreshing else { return }

        Task {
            await MainActor.run { isRefreshing = true }
            defer {
                Task {
                    await MainActor.run {
                        isRefreshing = false
                    }
                }
            }

            do {
                let fileURL = logFileURL
                let filePath = fileURL.path
                let parsed = try await Task.detached(priority: .utility) { () throws -> [OpenClawLogEntry] in
                    guard FileManager.default.fileExists(atPath: filePath) else {
                        return []
                    }
                    let parsed = OpenClawLogParser.parseFile(url: fileURL, limit: openClawLogMaxDisplay)
                    return parsed
                }.value

                await MainActor.run {
                    refreshError = nil
                    entries = parsed
                }
            } catch {
                await MainActor.run {
                    refreshError = error.localizedDescription
                }
            }
        }
    }

    private func startAutoRefreshLoop() {
        // Single initial load. Auto-refresh removed — users click the
        // refresh button when they want updated logs.
        refreshStatus()
    }

    private func stopAutoRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func copyLogs() {
        let payload = filteredEntries.map { $0.rawLine }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        isCopySuccess = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { isCopySuccess = false }
        }
    }

    private func openLogFile() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        _ = NSWorkspace.shared.open(logFileURL)
    }
}
