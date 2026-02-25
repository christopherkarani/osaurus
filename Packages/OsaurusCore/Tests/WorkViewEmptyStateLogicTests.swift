//
//  WorkViewEmptyStateLogicTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkViewEmptyStateLogicTests {
    @Test
    func route_prioritizesSetupState() {
        let route = WorkEmptyStateLogic.route(
            phase: .notConfigured,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawSetup)
    }

    @Test
    func route_showsLoadingDuringInitialHydrationWhenModelsEmpty() {
        let route = WorkEmptyStateLogic.route(
            phase: .connected,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: false,
            isGatewayConnectionPending: false
        )

        #expect(route == .providerLoading)
    }

    @Test
    func route_showsLoadingWhileGatewayPendingWhenModelsEmpty() {
        let route = WorkEmptyStateLogic.route(
            phase: .connecting,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: true
        )

        #expect(route == .providerLoading)
    }

    @Test
    func route_showsProviderNeededWhenHydratedAndNoModels() {
        let route = WorkEmptyStateLogic.route(
            phase: .connected,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .providerNeeded)
    }

    @Test
    func route_prefersWorkEmptyWhenModelsAvailable() {
        let route = WorkEmptyStateLogic.route(
            phase: .connecting,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: true,
            hasCompletedInitialModelHydration: false,
            isGatewayConnectionPending: true
        )

        #expect(route == .workEmpty)
    }

    @Test
    func route_showsOnboardingGateBeforeProviderStates() {
        let route = WorkEmptyStateLogic.route(
            phase: .connected,
            requiresLocalOnboardingGate: true,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawOnboardingRequired)
    }

    @Test
    func route_setupStateStillWinsWhenNotConfigured() {
        let route = WorkEmptyStateLogic.route(
            phase: .notConfigured,
            requiresLocalOnboardingGate: true,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawSetup)
    }

    @Test
    func route_showsSetupWhenGatewayIsConfiguredButNotConnected() {
        let route = WorkEmptyStateLogic.route(
            phase: .configured,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawSetup)
    }

    @Test
    func route_showsSetupWhenGatewayRunningButDisconnected() {
        let route = WorkEmptyStateLogic.route(
            phase: .gatewayRunning,
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawSetup)
    }

    @Test
    func route_showsSetupWhenConnectionFailed() {
        let route = WorkEmptyStateLogic.route(
            phase: .connectionFailed("unauthorized"),
            requiresLocalOnboardingGate: false,
            hasOpenClawModels: false,
            hasCompletedInitialModelHydration: true,
            isGatewayConnectionPending: false
        )

        #expect(route == .openClawSetup)
    }
}
