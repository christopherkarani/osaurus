//
//  OpenClawSetupWizardSheetTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

@MainActor
struct OpenClawSetupWizardSheetTests {
    @Test
    func cliReadiness_rejectsIncompatibleAndMissingStates() {
        #expect(OpenClawSetupWizardSheet.isCLIReady(.missingCLI) == false)
        #expect(
            OpenClawSetupWizardSheet.isCLIReady(
                .incompatibleVersion(found: "1.1.0", required: "1.2.0")
            ) == false
        )
        #expect(OpenClawSetupWizardSheet.isCLIReady(.error("boom")) == false)
        #expect(
            OpenClawSetupWizardSheet.isCLIReady(
                .ready(nodeVersion: "22.0.1", cliVersion: "1.2.0")
            ) == true
        )
    }

    @Test
    func installAction_onlyAllowedWhenCliMissing() {
        #expect(OpenClawSetupWizardSheet.canInstallCLIFromWizard(.missingCLI) == true)
        #expect(OpenClawSetupWizardSheet.canInstallCLIFromWizard(.missingNode) == false)
        #expect(
            OpenClawSetupWizardSheet.canInstallCLIFromWizard(
                .incompatibleVersion(found: "1.1.0", required: "1.2.0")
            ) == false
        )
    }

    @Test
    func blockerMessage_isSpecificForKnownFailures() {
        #expect(
            OpenClawSetupWizardSheet.environmentBlockerMessage(for: .missingNode)
                == "Node.js is required before installing OpenClaw CLI."
        )
        #expect(
            OpenClawSetupWizardSheet.environmentBlockerMessage(
                for: .incompatibleVersion(found: "1.1.0", required: "1.2.0")
            ) == "OpenClaw CLI 1.1.0 is incompatible. Update to 1.2.0 or newer."
        )
        #expect(
            OpenClawSetupWizardSheet.environmentBlockerMessage(for: .error("custom error"))
                == "custom error"
        )
    }
}
