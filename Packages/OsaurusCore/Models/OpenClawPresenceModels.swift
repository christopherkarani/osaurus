//
//  OpenClawPresenceModels.swift
//  osaurus
//

import Foundation

public struct OpenClawPresenceEntry: Codable, Sendable, Identifiable {
    public let deviceId: String?
    public let instanceId: String?
    public let host: String?
    public let ip: String?
    public let version: String?
    public let platform: String?
    public let deviceFamily: String?
    public let modelIdentifier: String?
    public let roles: [String]
    public let scopes: [String]
    public let mode: String?
    public let lastInputSeconds: Int?
    public let reason: String?
    public let text: String?
    public let tags: [String]
    public let timestampMs: Double

    public var id: String {
        primaryIdentity
    }

    public var primaryIdentity: String {
        if let deviceId = Self.normalized(deviceId) { return deviceId }
        if let instanceId = Self.normalized(instanceId) { return instanceId }
        if let host = Self.normalized(host) { return host }
        if let ip = Self.normalized(ip) { return ip }
        if let text = Self.normalized(text) { return text }
        return "presence-\(Int(timestampMs))"
    }

    public init(
        deviceId: String? = nil,
        instanceId: String?,
        host: String?,
        ip: String?,
        version: String?,
        platform: String?,
        deviceFamily: String?,
        modelIdentifier: String?,
        roles: [String],
        scopes: [String],
        mode: String?,
        lastInputSeconds: Int?,
        reason: String?,
        text: String?,
        tags: [String] = [],
        timestampMs: Double
    ) {
        self.deviceId = deviceId
        self.instanceId = instanceId
        self.host = host
        self.ip = ip
        self.version = version
        self.platform = platform
        self.deviceFamily = deviceFamily
        self.modelIdentifier = modelIdentifier
        self.roles = roles
        self.scopes = scopes
        self.mode = mode
        self.lastInputSeconds = lastInputSeconds
        self.reason = reason
        self.text = text
        self.tags = tags
        self.timestampMs = timestampMs
    }

    enum CodingKeys: String, CodingKey {
        case deviceId
        case instanceId
        case host
        case ip
        case version
        case platform
        case deviceFamily
        case modelIdentifier
        case roles
        case scopes
        case mode
        case lastInputSeconds
        case reason
        case text
        case tags
        case ts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        instanceId = try container.decodeIfPresent(String.self, forKey: .instanceId)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        ip = try container.decodeIfPresent(String.self, forKey: .ip)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        deviceFamily = try container.decodeIfPresent(String.self, forKey: .deviceFamily)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
        roles = try container.decodeIfPresent([String].self, forKey: .roles) ?? []
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        lastInputSeconds = try container.decodeIfPresent(Int.self, forKey: .lastInputSeconds)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []

        if let numeric = Self.decodeTimestamp(from: container) {
            timestampMs = Self.normalizeTimestampMs(numeric)
        } else {
            timestampMs = Date().timeIntervalSince1970 * 1000
        }
    }

    private static func decodeTimestamp(from container: KeyedDecodingContainer<CodingKeys>) -> Double? {
        if let raw = try? container.decode(Double.self, forKey: .ts) {
            return raw
        }
        if let raw = try? container.decode(Int.self, forKey: .ts) {
            return Double(raw)
        }
        if
            let raw = try? container.decode(String.self, forKey: .ts),
            let numeric = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return numeric
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(instanceId, forKey: .instanceId)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(ip, forKey: .ip)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(deviceFamily, forKey: .deviceFamily)
        try container.encodeIfPresent(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(roles, forKey: .roles)
        try container.encode(scopes, forKey: .scopes)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(lastInputSeconds, forKey: .lastInputSeconds)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(text, forKey: .text)
        if !tags.isEmpty {
            try container.encode(tags, forKey: .tags)
        }
        try container.encode(timestampMs, forKey: .ts)
    }

    public var connectedAt: Date {
        Date(timeIntervalSince1970: timestampMs / 1000)
    }

    public var displayName: String {
        if let host = Self.normalized(host) { return host }
        if let instanceId = Self.normalized(instanceId) { return instanceId }
        if let deviceId = Self.normalized(deviceId) { return deviceId }
        if let ip = Self.normalized(ip) { return ip }
        if let text = Self.normalized(text) { return text }
        return primaryIdentity
    }

    private static func normalizeTimestampMs(_ raw: Double) -> Double {
        guard raw > 0 else {
            return Date().timeIntervalSince1970 * 1000
        }
        if raw < 10_000_000_000 {
            return raw * 1000
        }
        return raw
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
