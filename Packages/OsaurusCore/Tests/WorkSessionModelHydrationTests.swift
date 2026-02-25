//
//  WorkSessionModelHydrationTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkSessionModelHydrationTests {
    @Test
    func initialHydrationFlag_startsFalse() {
        let session = WorkSession(agentId: UUID())
        #expect(session.hasCompletedInitialModelHydration == false)
    }

    @Test
    func initialHydrationFlag_eventuallyCompletes() async {
        let session = WorkSession(agentId: UUID())
        var completed = false

        for _ in 0..<120 {
            if session.hasCompletedInitialModelHydration {
                completed = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(completed == true)
    }
}
