//
//  WorkDatabaseTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkDatabaseTests {
    @Test
    func listTasks_autoOpensDatabaseWhenNotExplicitlyInitialized() throws {
        let root = testRootURL(name: "autopen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        WorkDatabase.shared.close()
        defer {
            WorkDatabase.shared.close()
            OsaurusPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }

        let tasks = try IssueStore.listTasks()

        #expect(tasks.isEmpty)
        #expect(WorkDatabase.shared.isOpen == true)
    }

    @Test
    func listTasks_reopensAfterCloseWithoutThrowingNotOpen() throws {
        let root = testRootURL(name: "reopen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        WorkDatabase.shared.close()
        defer {
            WorkDatabase.shared.close()
            OsaurusPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }

        _ = try IssueStore.listTasks()
        WorkDatabase.shared.close()

        let tasksAfterReopen = try IssueStore.listTasks()

        #expect(tasksAfterReopen.isEmpty)
        #expect(WorkDatabase.shared.isOpen == true)
    }

    private func testRootURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-workdb-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
