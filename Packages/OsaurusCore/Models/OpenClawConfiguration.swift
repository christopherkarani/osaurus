//
//  OpenClawConfiguration.swift
//  osaurus
//

import Foundation

public struct OpenClawConfiguration: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var gatewayPort: Int
    public var bindMode: BindMode
    public var autoStartGateway: Bool
    public var installPath: String
    public var lastKnownVersion: String?

    public enum BindMode: String, Codable, Sendable, CaseIterable {
        case loopback
        case lan
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case gatewayPort
        case bindMode
        case autoStartGateway
        case installPath
        case lastKnownVersion
    }

    public init(
        isEnabled: Bool = false,
        gatewayPort: Int = 18789,
        bindMode: BindMode = .loopback,
        autoStartGateway: Bool = true,
        installPath: String = "~/.openclaw",
        lastKnownVersion: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.gatewayPort = gatewayPort
        self.bindMode = bindMode
        self.autoStartGateway = autoStartGateway
        self.installPath = installPath
        self.lastKnownVersion = lastKnownVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.gatewayPort = try container.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? 18789
        self.bindMode = try container.decodeIfPresent(BindMode.self, forKey: .bindMode) ?? .loopback
        self.autoStartGateway = try container.decodeIfPresent(Bool.self, forKey: .autoStartGateway) ?? true
        self.installPath = try container.decodeIfPresent(String.self, forKey: .installPath) ?? "~/.openclaw"
        self.lastKnownVersion = try container.decodeIfPresent(String.self, forKey: .lastKnownVersion)
    }
}
