//
//  OpenClawManager.swift
//  osaurus
//
//  Orchestrates the OpenClaw gateway connection lifecycle and owns the activity store.
//  Full implementation (connection, configuration, health monitoring) defined in
//  the main integration plan (openclaw-osaurus-integration.md).
//

import Combine
import Foundation

// MARK: - OpenClawManager

/// Manages the OpenClaw gateway integration for Osaurus
@MainActor
public final class OpenClawManager: ObservableObject {
    public static let shared = OpenClawManager()

    /// The activity store that processes and indexes agent events
    public let activityStore = OpenClawActivityStore()

    private init() {}

    // MARK: - Gateway Lifecycle (Future)

    // On gateway connect:
    // activityStore.subscribe(to: gatewayNodeSession)

    // On gateway disconnect:
    // activityStore.unsubscribe()

    // On session switch:
    // activityStore.reset()
    // activityStore.subscribe(to: newSession)
}
