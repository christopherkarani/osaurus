//
//  OpenClawGatewayConnectionPhase3CronTests.swift
//  osaurusTests
//

import Foundation
import OpenClawProtocol
import Testing
@testable import OsaurusCore

private actor OpenClawCronCallRecorder {
    struct Call: Sendable {
        let method: String
        let params: [String: OpenClawProtocol.AnyCodable]?
    }

    private var calls: [Call] = []

    func record(method: String, params: [String: OpenClawProtocol.AnyCodable]?) {
        calls.append(Call(method: method, params: params))
    }

    func all() -> [Call] {
        calls
    }
}

struct OpenClawGatewayConnectionPhase3CronTests {
    @Test
    func cronStatusAndList_decodeTypedPayloads() async throws {
        let recorder = OpenClawCronCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            switch method {
            case "cron.status":
                let payload: [String: Any] = [
                    "enabled": true,
                    "jobs": 2,
                    "nextWakeAtMs": 1_708_345_600_000,
                    "storePath": "/tmp/cron.json"
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            case "cron.list":
                let payload: [String: Any] = [
                    "jobs": [
                        [
                            "id": "job-1",
                            "name": "Daily summary",
                            "enabled": true,
                            "schedule": [
                                "kind": "cron",
                                "expr": "0 8 * * *",
                                "tz": "UTC"
                            ],
                            "state": [
                                "lastStatus": "ok",
                                "lastDurationMs": 900
                            ]
                        ]
                    ]
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            default:
                return try JSONSerialization.data(withJSONObject: [:])
            }
        }

        let status = try await connection.cronStatus()
        let jobs = try await connection.cronList()
        let calls = await recorder.all()

        #expect(calls.count == 2)
        #expect(calls[0].method == "cron.status")
        #expect(calls[1].method == "cron.list")
        #expect(status.enabled == true)
        #expect(status.jobs == 2)
        #expect(status.nextWakeAt != nil)
        #expect(jobs.count == 1)
        #expect(jobs[0].id == "job-1")
        #expect(jobs[0].schedule.kind == .cron)
        #expect(jobs[0].state.lastStatus == "ok")
    }

    @Test
    func cronRunAndSetEnabled_encodeExpectedParams() async throws {
        let recorder = OpenClawCronCallRecorder()
        let connection = OpenClawGatewayConnection { method, params in
            await recorder.record(method: method, params: params)
            return try JSONSerialization.data(withJSONObject: ["ok": true])
        }

        try await connection.cronRun(jobId: "job-2")
        try await connection.cronSetEnabled(jobId: "job-2", enabled: false)
        let calls = await recorder.all()

        #expect(calls.count == 2)
        #expect(calls[0].method == "cron.run")
        #expect(calls[0].params?["id"]?.value as? String == "job-2")
        #expect(calls[0].params?["mode"]?.value as? String == "force")

        #expect(calls[1].method == "cron.update")
        #expect(calls[1].params?["id"]?.value as? String == "job-2")
        if let patch = calls[1].params?["patch"]?.value as? [String: OpenClawProtocol.AnyCodable] {
            #expect(patch["enabled"]?.value as? Bool == false)
        } else if let patch = calls[1].params?["patch"]?.value as? [String: Any] {
            #expect(patch["enabled"] as? Bool == false)
        } else {
            Issue.record("Expected patch dictionary for cron.update")
        }
    }

    @Test
    func cronRuns_decodesRunEntries() async throws {
        let connection = OpenClawGatewayConnection { method, _ in
            #expect(method == "cron.runs")
            let payload: [String: Any] = [
                "entries": [
                    [
                        "ts": 1_708_345_700_000 as Int,
                        "jobId": "job-3",
                        "status": "error",
                        "durationMs": 1100,
                        "error": "network timeout"
                    ]
                ]
            ]
            return try JSONSerialization.data(withJSONObject: payload)
        }

        let entries = try await connection.cronRuns(jobId: "job-3", limit: 10)

        #expect(entries.count == 1)
        #expect(entries[0].jobId == "job-3")
        #expect(entries[0].status == "error")
        #expect(entries[0].durationMs == 1100)
        #expect(entries[0].error == "network timeout")
    }
}
