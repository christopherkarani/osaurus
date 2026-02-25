//
//  OpenClawConfiguration.swift
//  osaurus
//

import Foundation

public struct OpenClawConfiguration: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var gatewayPort: Int
    /// Optional gateway WebSocket URL (for example `ws://127.0.0.1:18789/ws` or `wss://host/ws`).
    /// When nil/empty, Osaurus falls back to the local loopback endpoint.
    public var gatewayURL: String?
    /// Optional explicit health URL override. When nil/empty, Osaurus derives this
    /// from `gatewayURL` (`ws` -> `http`, `wss` -> `https`, path `/health`).
    public var gatewayHealthURL: String?
    public var bindMode: BindMode
    public var autoStartGateway: Bool
    public var autoSyncMCPBridge: Bool
    public var installPath: String
    public var lastKnownVersion: String?

    public enum BindMode: String, Codable, Sendable, CaseIterable {
        case loopback
        case lan
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case gatewayPort
        case gatewayURL
        case gatewayHealthURL
        case bindMode
        case autoStartGateway
        case autoSyncMCPBridge
        case installPath
        case lastKnownVersion
    }

    public init(
        isEnabled: Bool = false,
        gatewayPort: Int = 18789,
        gatewayURL: String? = nil,
        gatewayHealthURL: String? = nil,
        bindMode: BindMode = .loopback,
        autoStartGateway: Bool = true,
        autoSyncMCPBridge: Bool = true,
        installPath: String = "~/.openclaw",
        lastKnownVersion: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.gatewayPort = gatewayPort
        self.gatewayURL = gatewayURL
        self.gatewayHealthURL = gatewayHealthURL
        self.bindMode = bindMode
        self.autoStartGateway = autoStartGateway
        self.autoSyncMCPBridge = autoSyncMCPBridge
        self.installPath = installPath
        self.lastKnownVersion = lastKnownVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.gatewayPort = try container.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? 18789
        self.gatewayURL = try container.decodeIfPresent(String.self, forKey: .gatewayURL)
        self.gatewayHealthURL = try container.decodeIfPresent(String.self, forKey: .gatewayHealthURL)
        self.bindMode = try container.decodeIfPresent(BindMode.self, forKey: .bindMode) ?? .loopback
        self.autoStartGateway = try container.decodeIfPresent(Bool.self, forKey: .autoStartGateway) ?? true
        self.autoSyncMCPBridge = try container.decodeIfPresent(Bool.self, forKey: .autoSyncMCPBridge) ?? true
        self.installPath = try container.decodeIfPresent(String.self, forKey: .installPath) ?? "~/.openclaw"
        self.lastKnownVersion = try container.decodeIfPresent(String.self, forKey: .lastKnownVersion)
    }
}
