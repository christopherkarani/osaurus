//
//  OpenClawPresenceModels.swift
//  osaurus
//

import Foundation

public struct OpenClawPresenceEntry: Codable, Sendable, Identifiable {
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
    public let timestampMs: Double

    public var id: String {
        if let instanceId, !instanceId.isEmpty { return instanceId }
        if let host, !host.isEmpty { return host }
        if let ip, !ip.isEmpty { return ip }
        if let text, !text.isEmpty { return text }
        return "presence-\(Int(timestampMs))"
    }

    public init(
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
        timestampMs: Double
    ) {
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
        self.timestampMs = timestampMs
    }

    enum CodingKeys: String, CodingKey {
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
        case ts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

        if let rawTs = try container.decodeIfPresent(Double.self, forKey: .ts) {
            timestampMs = rawTs
        } else if let rawTs = try container.decodeIfPresent(Int.self, forKey: .ts) {
            timestampMs = Double(rawTs)
        } else if let rawTs = try container.decodeIfPresent(String.self, forKey: .ts),
            let numeric = Double(rawTs.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            timestampMs = numeric
        } else {
            timestampMs = Date().timeIntervalSince1970 * 1000
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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
        try container.encode(timestampMs, forKey: .ts)
    }

    public var connectedAt: Date {
        Date(timeIntervalSince1970: timestampMs / 1000)
    }

    public var displayName: String {
        if let host, !host.isEmpty { return host }
        if let instanceId, !instanceId.isEmpty { return instanceId }
        if let text, !text.isEmpty { return text }
        return "Unknown client"
    }
}
