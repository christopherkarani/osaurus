//
//  StartupDiagnostics.swift
//  osaurus
//

import Foundation

public enum StartupDiagnosticsLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct StartupDiagnosticRecord: Codable, Sendable {
    public let ts: String
    public let level: String
    public let component: String
    public let event: String
    public let startupRunId: String
    public let context: [String: String]

    public init(
        ts: String,
        level: String,
        component: String,
        event: String,
        startupRunId: String,
        context: [String: String]
    ) {
        self.ts = ts
        self.level = level
        self.component = component
        self.event = event
        self.startupRunId = startupRunId
        self.context = context
    }
}

public actor StartupDiagnostics {
    public struct Hooks: Sendable {
        var fileURL: @Sendable () -> URL
        var startupRunId: @Sendable () -> String
        var now: @Sendable () -> Date
    }

    nonisolated(unsafe) static var hooks: Hooks?
    public static let shared = StartupDiagnostics()

    private static let sensitiveContextKeyFragments = [
        "authorization",
        "api_key",
        "apikey",
        "token",
        "secret",
        "password",
        "bearer",
    ]
    private static let maxContextValueLength = 256

    private let outputURL: URL
    public let startupRunId: String
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder

    public init(
        outputURL: URL? = nil,
        startupRunId: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let resolvedHooks = Self.hooks
        self.outputURL = outputURL ?? resolvedHooks?.fileURL() ?? Self.defaultOutputURL()
        self.startupRunId = startupRunId ?? resolvedHooks?.startupRunId() ?? UUID().uuidString
        self.now = resolvedHooks?.now ?? now
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func emit(
        level: StartupDiagnosticsLevel = .info,
        component: String,
        event: String,
        context: [String: String] = [:]
    ) {
        let record = StartupDiagnosticRecord(
            ts: Self.iso8601String(from: now()),
            level: level.rawValue,
            component: component,
            event: event,
            startupRunId: startupRunId,
            context: Self.sanitizeContext(context)
        )

        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        append(line: line)
    }

    public func logFileURL() -> URL {
        outputURL
    }

    nonisolated static func sanitizeContext(_ context: [String: String]) -> [String: String] {
        guard !context.isEmpty else { return [:] }

        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(context.count)

        for (key, value) in context {
            let normalizedKey = key.lowercased()
            if sensitiveContextKeyFragments.contains(where: { normalizedKey.contains($0) }) {
                sanitized[key] = "<redacted>"
                continue
            }

            let collapsed = value.replacingOccurrences(of: "\n", with: "\\n")
            sanitized[key] = truncateValue(collapsed)
        }

        return sanitized
    }

    nonisolated static func truncateValue(_ value: String, maxLength: Int = maxContextValueLength) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "...(truncated)"
    }

    private func append(line: Data) {
        OsaurusPaths.ensureExistsSilent(outputURL.deletingLastPathComponent())
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputURL.path) {
            _ = fileManager.createFile(atPath: outputURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics must never crash product flows.
        }
    }

    nonisolated private static func defaultOutputURL() -> URL {
        OsaurusPaths.runtime().appendingPathComponent("startup-diagnostics.jsonl")
    }

    nonisolated private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
