//
//  MCPProviderManagerClassificationTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct MCPProviderManagerClassificationTests {
    @Test
    func methodNotAllowedMessage_classifiesAsEndpointMismatch() {
        let manager = MCPProviderManager.shared
        let classification = manager._testInferFailureClass(
            from: "HTTP 405 Method not allowed for this route"
        )

        #expect(classification.failureClass == "misconfigured-endpoint")
        #expect(classification.healthState == .misconfiguredEndpoint)
        #expect(classification.fixIt?.localizedCaseInsensitiveContains("endpoint/protocol mismatch") == true)
    }

    @Test
    func openClawControlURL_reportsEndpointSanityIssue() {
        let manager = MCPProviderManager.shared
        let issue = manager._testOpenClawMCPEndpointSanityIssue(
            url: URL(string: "http://127.0.0.1:18789/health")!
        )

        #expect(issue?.localizedCaseInsensitiveContains("control route") == true)
    }
}
