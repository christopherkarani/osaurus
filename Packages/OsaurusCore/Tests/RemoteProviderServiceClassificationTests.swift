//
//  RemoteProviderServiceClassificationTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RemoteProviderServiceClassificationTests {
    @Test
    func classifyModelsDecodeFailure_htmlPayload_classifiesEndpointMismatch() {
        let details = RemoteProviderService.classifyModelsDecodeFailure(
            url: URL(string: "http://127.0.0.1:18789/health")!,
            statusCode: 200,
            contentType: "text/html; charset=utf-8",
            data: Data("<html><body>not json</body></html>".utf8),
            decodeError: NSError(domain: "RemoteProviderTests", code: 1)
        )

        #expect(details.failureClass == .misconfiguredEndpoint)
        #expect(details.message.localizedCaseInsensitiveContains("endpoint mismatch"))
        #expect(details.fixIt?.localizedCaseInsensitiveContains("OpenClaw gateway UI/control route") == true)
        #expect(details.bodyPreview?.localizedCaseInsensitiveContains("<html>") == true)
    }

    @Test
    func classifyModelsHTTPFailure_methodNotAllowed_classifiesEndpointMismatch() {
        let details = RemoteProviderService.classifyModelsHTTPFailure(
            url: URL(string: "https://provider.example.com/models")!,
            statusCode: 405,
            contentType: "text/plain",
            data: Data("Method not allowed".utf8)
        )

        #expect(details.failureClass == .misconfiguredEndpoint)
        #expect(details.statusCode == 405)
        #expect(details.message.localizedCaseInsensitiveContains("misconfigured"))
        #expect(details.fixIt?.localizedCaseInsensitiveContains("model API") == true)
    }
}
