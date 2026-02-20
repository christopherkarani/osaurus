//
//  OpenClawChannelStatus.swift
//  osaurus
//

import Foundation

public struct ChannelsStatusResult: Codable, Sendable {
    public let ts: Int?
    public let channelOrder: [String]
    public let channelLabels: [String: String]
    public let channelDetailLabels: [String: String]
    public let channelSystemImages: [String: String]
    public let channelMeta: [ChannelMeta]
    public let channelAccounts: [String: [ChannelAccountSnapshot]]
    public let channelDefaultAccountId: [String: String]

    public init(
        ts: Int? = nil,
        channelOrder: [String],
        channelLabels: [String: String],
        channelDetailLabels: [String: String],
        channelSystemImages: [String: String],
        channelMeta: [ChannelMeta],
        channelAccounts: [String: [ChannelAccountSnapshot]],
        channelDefaultAccountId: [String: String]
    ) {
        self.ts = ts
        self.channelOrder = channelOrder
        self.channelLabels = channelLabels
        self.channelDetailLabels = channelDetailLabels
        self.channelSystemImages = channelSystemImages
        self.channelMeta = channelMeta
        self.channelAccounts = channelAccounts
        self.channelDefaultAccountId = channelDefaultAccountId
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case channelOrder
        case channelLabels
        case channelDetailLabels
        case channelSystemImages
        case channelMeta
        case channelAccounts
        case channelDefaultAccountId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decodeIfPresent(Int.self, forKey: .ts)
        channelOrder = try container.decodeIfPresent([String].self, forKey: .channelOrder) ?? []
        channelLabels = try container.decodeIfPresent([String: String].self, forKey: .channelLabels) ?? [:]
        channelDetailLabels =
            try container.decodeIfPresent([String: String].self, forKey: .channelDetailLabels) ?? [:]
        channelSystemImages =
            try container.decodeIfPresent([String: String].self, forKey: .channelSystemImages) ?? [:]
        channelMeta = try container.decodeIfPresent([ChannelMeta].self, forKey: .channelMeta) ?? []
        channelAccounts =
            try container.decodeIfPresent([String: [ChannelAccountSnapshot]].self, forKey: .channelAccounts) ?? [:]
        channelDefaultAccountId =
            try container.decodeIfPresent([String: String].self, forKey: .channelDefaultAccountId) ?? [:]
    }
}

public struct ChannelMeta: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let detailLabel: String?
    public let systemImage: String

    public init(id: String, label: String, detailLabel: String?, systemImage: String) {
        self.id = id
        self.label = label
        self.detailLabel = detailLabel
        self.systemImage = systemImage
    }
}

public struct ChannelAccountSnapshot: Codable, Sendable, Identifiable {
    public let accountId: String
    public let name: String?
    public let enabled: Bool
    public let configured: Bool
    public let linked: Bool
    public let running: Bool
    public let connected: Bool
    public let reconnectAttempts: Int?
    public let lastConnectedAt: Date?
    public let lastError: String?
    public let lastInboundAt: Date?
    public let lastOutboundAt: Date?
    public let mode: String?
    public let dmPolicy: String?

    public var id: String { accountId }

    public init(
        accountId: String,
        name: String?,
        enabled: Bool,
        configured: Bool,
        linked: Bool,
        running: Bool,
        connected: Bool,
        reconnectAttempts: Int?,
        lastConnectedAt: Date?,
        lastError: String?,
        lastInboundAt: Date?,
        lastOutboundAt: Date?,
        mode: String?,
        dmPolicy: String?
    ) {
        self.accountId = accountId
        self.name = name
        self.enabled = enabled
        self.configured = configured
        self.linked = linked
        self.running = running
        self.connected = connected
        self.reconnectAttempts = reconnectAttempts
        self.lastConnectedAt = lastConnectedAt
        self.lastError = lastError
        self.lastInboundAt = lastInboundAt
        self.lastOutboundAt = lastOutboundAt
        self.mode = mode
        self.dmPolicy = dmPolicy
    }

    enum CodingKeys: String, CodingKey {
        case accountId
        case name
        case enabled
        case configured
        case linked
        case running
        case connected
        case reconnectAttempts
        case lastConnectedAt
        case lastError
        case lastInboundAt
        case lastOutboundAt
        case mode
        case dmPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        linked = try container.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        reconnectAttempts = try container.decodeIfPresent(Int.self, forKey: .reconnectAttempts)
        lastConnectedAt = try Self.decodeDateIfPresent(container: container, key: .lastConnectedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastInboundAt = try Self.decodeDateIfPresent(container: container, key: .lastInboundAt)
        lastOutboundAt = try Self.decodeDateIfPresent(container: container, key: .lastOutboundAt)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        dmPolicy = try container.decodeIfPresent(String.self, forKey: .dmPolicy)
    }

    private static func decodeDateIfPresent(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        if let millis = try container.decodeIfPresent(Double.self, forKey: key) {
            return decodeTimestamp(millis)
        }
        if let millis = try container.decodeIfPresent(Int.self, forKey: key) {
            return decodeTimestamp(Double(millis))
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            if let numeric = Double(trimmed) {
                return decodeTimestamp(numeric)
            }
            if let iso = ISO8601DateFormatter().date(from: trimmed) {
                return iso
            }
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
