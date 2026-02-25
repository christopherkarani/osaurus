//
//  ProviderHealthState.swift
//  osaurus
//

import Foundation

public enum ProviderHealthState: String, Codable, Sendable, Equatable {
    case ready = "ready"
    case misconfiguredEndpoint = "misconfigured-endpoint"
    case authFailed = "auth-failed"
    case gatewayUnavailable = "gateway-unavailable"
    case networkUnreachable = "network-unreachable"
    case unknownFailure = "unknown-failure"

    public var label: String {
        switch self {
        case .ready:
            return "Ready"
        case .misconfiguredEndpoint:
            return "Misconfigured endpoint"
        case .authFailed:
            return "Auth failed"
        case .gatewayUnavailable:
            return "Gateway unavailable"
        case .networkUnreachable:
            return "Network unreachable"
        case .unknownFailure:
            return "Connection issue"
        }
    }
}
