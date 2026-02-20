//
//  OpenClawCronModels.swift
//  osaurus
//

import Foundation

public struct OpenClawCronStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let jobs: Int
    public let storePath: String?
    public let nextWakeAt: Date?

    public init(enabled: Bool, jobs: Int, storePath: String?, nextWakeAt: Date?) {
        self.enabled = enabled
        self.jobs = jobs
        self.storePath = storePath
        self.nextWakeAt = nextWakeAt
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case jobs
        case storePath
        case nextWakeAtMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        jobs = try container.decodeIfPresent(Int.self, forKey: .jobs) ?? 0
        storePath = try container.decodeIfPresent(String.self, forKey: .storePath)
        nextWakeAt = try Self.decodeTimestampIfPresent(container: container, key: .nextWakeAtMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(jobs, forKey: .jobs)
        try container.encodeIfPresent(storePath, forKey: .storePath)
        if let nextWakeAt {
            try container.encode(Int(nextWakeAt.timeIntervalSince1970 * 1000), forKey: .nextWakeAtMs)
        }
    }

    private static func decodeTimestampIfPresent(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        if let raw = try container.decodeIfPresent(Double.self, forKey: key) {
            return decodeTimestamp(raw)
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: key) {
            return decodeTimestamp(Double(raw))
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: key),
            let numeric = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return decodeTimestamp(numeric)
        }
        return nil
    }

    private static func decodeTimestamp(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 10_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}

public struct OpenClawCronListResponse: Codable, Sendable, Equatable {
    public let jobs: [OpenClawCronJob]
}

public struct OpenClawCronRunsResponse: Codable, Sendable, Equatable {
    public let entries: [OpenClawCronRunLogEntry]
}

public struct OpenClawCronJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let enabled: Bool
    public let schedule: OpenClawCronSchedule
    public let state: OpenClawCronJobState

    public init(
        id: String,
        name: String,
        description: String?,
        enabled: Bool,
        schedule: OpenClawCronSchedule,
        state: OpenClawCronJobState
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.enabled = enabled
        self.schedule = schedule
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case enabled
        case schedule
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled job"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        schedule = try container.decodeIfPresent(OpenClawCronSchedule.self, forKey: .schedule)
            ?? OpenClawCronSchedule(kind: .every, at: nil, everyMs: nil, expr: nil, tz: nil)
        state = try container.decodeIfPresent(OpenClawCronJobState.self, forKey: .state) ?? OpenClawCronJobState()
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled job" : trimmed
    }

    public var scheduleSummary: String {
        schedule.summary
    }
}

public struct OpenClawCronJobState: Codable, Sendable, Equatable {
    public let nextRunAt: Date?
    public let runningAt: Date?
    public let lastRunAt: Date?
    public let lastStatus: String?
    public let lastError: String?
    public let lastDurationMs: Int?

    public init(
        nextRunAt: Date? = nil,
        runningAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        lastError: String? = nil,
        lastDurationMs: Int? = nil
    ) {
        self.nextRunAt = nextRunAt
        self.runningAt = runningAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastDurationMs = lastDurationMs
    }

    enum CodingKeys: String, CodingKey {
        case nextRunAtMs
        case runningAtMs
        case lastRunAtMs
        case lastStatus
        case lastError
        case lastDurationMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextRunAt = try Self.decodeTimestampIfPresent(container: container, key: .nextRunAtMs)
        runningAt = try Self.decodeTimestampIfPresent(container: container, key: .runningAtMs)
        lastRunAt = try Self.decodeTimestampIfPresent(container: container, key: .lastRunAtMs)
        lastStatus = try container.decodeIfPresent(String.self, forKey: .lastStatus)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastDurationMs = try container.decodeIfPresent(Int.self, forKey: .lastDurationMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let nextRunAt {
            try container.encode(Int(nextRunAt.timeIntervalSince1970 * 1000), forKey: .nextRunAtMs)
        }
        if let runningAt {
            try container.encode(Int(runningAt.timeIntervalSince1970 * 1000), forKey: .runningAtMs)
        }
        if let lastRunAt {
            try container.encode(Int(lastRunAt.timeIntervalSince1970 * 1000), forKey: .lastRunAtMs)
        }
        try container.encodeIfPresent(lastStatus, forKey: .lastStatus)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(lastDurationMs, forKey: .lastDurationMs)
    }

    private static func decodeTimestampIfPresent(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        if let raw = try container.decodeIfPresent(Double.self, forKey: key) {
            return decodeTimestamp(raw)
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: key) {
            return decodeTimestamp(Double(raw))
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: key),
            let numeric = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return decodeTimestamp(numeric)
        }
        return nil
    }

    private static func decodeTimestamp(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 10_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}

public struct OpenClawCronSchedule: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case at
        case every
        case cron
    }

    public let kind: Kind
    public let at: Date?
    public let everyMs: Int?
    public let expr: String?
    public let tz: String?

    public init(kind: Kind, at: Date?, everyMs: Int?, expr: String?, tz: String?) {
        self.kind = kind
        self.at = at
        self.everyMs = everyMs
        self.expr = expr
        self.tz = tz
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case at
        case atMs
        case everyMs
        case expr
        case tz
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try container.decodeIfPresent(String.self, forKey: .kind) ?? "every")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawKind {
        case "at", "time":
            kind = .at
        case "every", "interval":
            kind = .every
        default:
            kind = .cron
        }

        at = try Self.decodeAtDate(container: container)
        everyMs = try container.decodeIfPresent(Int.self, forKey: .everyMs)
        expr = try container.decodeIfPresent(String.self, forKey: .expr)
        tz = try container.decodeIfPresent(String.self, forKey: .tz)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch kind {
        case .at:
            if let at {
                try container.encode(Int(at.timeIntervalSince1970 * 1000), forKey: .atMs)
            }
        case .every:
            try container.encodeIfPresent(everyMs, forKey: .everyMs)
        case .cron:
            try container.encodeIfPresent(expr, forKey: .expr)
            try container.encodeIfPresent(tz, forKey: .tz)
        }
    }

    public var summary: String {
        switch kind {
        case .at:
            guard let at else { return "At scheduled time" }
            return "At \(Self.dateFormatter.string(from: at))"
        case .every:
            guard let everyMs, everyMs > 0 else { return "Interval" }
            return "Every \(Self.intervalDescription(everyMs: everyMs))"
        case .cron:
            let expression = expr?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expression, !expression.isEmpty {
                if let tz, !tz.isEmpty {
                    return "\(expression) (\(tz))"
                }
                return expression
            }
            return "Cron"
        }
    }

    private static func decodeAtDate(
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        if let text = try container.decodeIfPresent(String.self, forKey: .at) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let iso = ISO8601DateFormatter().date(from: trimmed) {
                return iso
            }
            if let numeric = Double(trimmed) {
                return decodeTimestamp(numeric)
            }
        }

        if let atMs = try container.decodeIfPresent(Double.self, forKey: .atMs) {
            return decodeTimestamp(atMs)
        }
        if let atMs = try container.decodeIfPresent(Int.self, forKey: .atMs) {
            return decodeTimestamp(Double(atMs))
        }
        return nil
    }

    private static func decodeTimestamp(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        if raw > 10_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }

    private static func intervalDescription(everyMs: Int) -> String {
        if everyMs % 86_400_000 == 0 {
            let days = everyMs / 86_400_000
            return days == 1 ? "1 day" : "\(days) days"
        }
        if everyMs % 3_600_000 == 0 {
            let hours = everyMs / 3_600_000
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = max(1, everyMs / 60_000)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct OpenClawCronRunLogEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        "\(jobId)-\(ts)"
    }

    public let ts: Int
    public let jobId: String
    public let status: String?
    public let durationMs: Int?
    public let error: String?
    public let summary: String?
    public let sessionId: String?
    public let sessionKey: String?

    public var timestamp: Date {
        Date(timeIntervalSince1970: Double(ts) / 1000)
    }

    public init(
        ts: Int,
        jobId: String,
        status: String?,
        durationMs: Int?,
        error: String?,
        summary: String?,
        sessionId: String?,
        sessionKey: String?
    ) {
        self.ts = ts
        self.jobId = jobId
        self.status = status
        self.durationMs = durationMs
        self.error = error
        self.summary = summary
        self.sessionId = sessionId
        self.sessionKey = sessionKey
    }
}
