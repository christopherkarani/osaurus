//
//  ProviderAutoConnectStartupTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ProviderAutoConnectStartupTests {
    actor AttemptCounter {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }

        func value() -> Int {
            count
        }
    }

    @Test
    func remoteStartupAutoConnect_skipsPreviouslyMisconfiguredEndpoint() async {
        let manager = RemoteProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            RemoteProviderManager._testSetHooks(nil)
            RemoteProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = RemoteProvider(
            name: "Remote Startup Skip",
            host: "example.com",
            providerProtocol: .https,
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(RemoteProviderConfiguration(providers: [provider]))

        var state = RemoteProviderState(providerId: provider.id)
        state.healthState = .misconfiguredEndpoint
        state.lastError = "Endpoint mismatch"
        manager._testSetProviderState(state, for: provider.id)

        let attempts = AttemptCounter()
        RemoteProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        RemoteProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    _ = await attempts.next()
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 0)
    }

    @Test
    func remoteStartupAutoConnect_retriesAfterTransientFailure() async {
        let manager = RemoteProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            RemoteProviderManager._testSetHooks(nil)
            RemoteProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = RemoteProvider(
            name: "Remote Startup Retry",
            host: "example.com",
            providerProtocol: .https,
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(RemoteProviderConfiguration(providers: [provider]))
        manager._testSetProviderState(RemoteProviderState(providerId: provider.id), for: provider.id)

        let attempts = AttemptCounter()
        RemoteProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        RemoteProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    let attempt = await attempts.next()
                    if attempt < 2 {
                        throw RemoteProviderError.connectionFailed("network timeout")
                    }
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 2)
    }

    @Test
    func remoteStartupAutoConnect_disablesAutoConnectForOpenClawMisconfiguredEndpoint() async {
        let manager = RemoteProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            RemoteProviderManager._testSetHooks(nil)
            RemoteProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = RemoteProvider(
            name: "OpenClaw Local",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 18789,
            basePath: "/v1",
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(RemoteProviderConfiguration(providers: [provider]))
        manager._testSetProviderState(RemoteProviderState(providerId: provider.id), for: provider.id)

        let attempts = AttemptCounter()
        RemoteProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        RemoteProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    _ = await attempts.next()
                    throw RemoteProviderError.connectionFailed(
                        "Provider returned HTML/non-JSON content for http://127.0.0.1:18789/v1/models. This usually indicates an endpoint mismatch."
                    )
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 0)
        #expect(manager.configuration.provider(id: provider.id)?.autoConnect == false)
    }

    @Test
    func mcpStartupAutoConnect_skipsPreviouslyMisconfiguredEndpoint() async {
        let manager = MCPProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            MCPProviderManager._testSetHooks(nil)
            MCPProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = MCPProvider(
            name: "MCP Startup Skip",
            url: "http://127.0.0.1:18789/health",
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(MCPProviderConfiguration(providers: [provider]))

        var state = MCPProviderState(providerId: provider.id)
        state.healthState = .misconfiguredEndpoint
        state.lastError = "Endpoint mismatch"
        manager._testSetProviderState(state, for: provider.id)

        let attempts = AttemptCounter()
        MCPProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        MCPProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    _ = await attempts.next()
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 0)
    }

    @Test
    func mcpStartupAutoConnect_retriesAfterTransientFailure() async {
        let manager = MCPProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            MCPProviderManager._testSetHooks(nil)
            MCPProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = MCPProvider(
            name: "MCP Startup Retry",
            url: "http://127.0.0.1:3000/mcp",
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(MCPProviderConfiguration(providers: [provider]))
        manager._testSetProviderState(MCPProviderState(providerId: provider.id), for: provider.id)

        let attempts = AttemptCounter()
        MCPProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        MCPProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    let attempt = await attempts.next()
                    if attempt < 2 {
                        throw MCPProviderError.connectionFailed("network timeout")
                    }
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 2)
    }

    @Test
    func mcpStartupAutoConnect_disablesAutoConnectForOpenClawMisconfiguredEndpoint() async {
        let manager = MCPProviderManager.shared
        let originalConfig = manager.configuration
        let originalStates = manager.providerStates
        defer {
            MCPProviderManager._testSetHooks(nil)
            MCPProviderManager._testSetStartupRetryDelaysNs(nil)
            manager._testSetConfiguration(originalConfig)
            for (providerId, state) in originalStates {
                manager._testSetProviderState(state, for: providerId)
            }
        }

        let provider = MCPProvider(
            name: "OpenClaw MCP",
            url: "http://127.0.0.1:18789/mcp",
            enabled: true,
            autoConnect: true
        )
        manager._testSetConfiguration(MCPProviderConfiguration(providers: [provider]))
        manager._testSetProviderState(MCPProviderState(providerId: provider.id), for: provider.id)

        let attempts = AttemptCounter()
        MCPProviderManager._testSetStartupRetryDelaysNs([0, 0, 0])
        MCPProviderManager._testSetHooks(
            .init(
                connectOverride: { _ in
                    _ = await attempts.next()
                    throw MCPProviderError.connectionFailed("Internal error: Method not allowed")
                }
            )
        )

        await manager.connectEnabledProviders(isStartup: true)
        #expect(await attempts.value() == 0)
        #expect(manager.configuration.provider(id: provider.id)?.autoConnect == false)
    }
}
