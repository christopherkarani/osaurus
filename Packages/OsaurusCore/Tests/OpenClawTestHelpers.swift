//
//  OpenClawTestHelpers.swift
//  osaurusTests
//
//  Shared test helpers for constructing EventFrame instances from dictionaries.
//  EventFrame is Codable with internal memberwise init, so we construct via JSON.
//

import Foundation
import OpenClawProtocol

/// Build an EventFrame from a raw dictionary payload.
/// Uses JSONSerialization → JSONDecoder to trigger AnyCodable.init(from:),
/// which stores nested objects as [String: AnyCodable] — matching real behavior.
func makeEventFrame(
    event: String = "agent.event",
    payload: [String: Any],
    seq: Int = 1
) -> EventFrame {
    let dict: [String: Any] = [
        "type": "event",
        "event": event,
        "payload": payload,
        "seq": seq
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(EventFrame.self, from: data)
}

/// Build an agent event payload envelope with the standard fields.
func makeAgentPayload(
    stream: String,
    runId: String = "test-run-1",
    seq: Int = 1,
    ts: Double = 1708345600000,
    data: [String: Any] = [:]
) -> [String: Any] {
    return [
        "runId": runId,
        "seq": seq,
        "stream": stream,
        "ts": ts,
        "data": data
    ]
}

/// Convenience: build a complete EventFrame for an agent event.
func makeAgentEventFrame(
    stream: String,
    runId: String = "test-run-1",
    seq: Int = 1,
    ts: Double = 1708345600000,
    data: [String: Any] = [:]
) -> EventFrame {
    let payload = makeAgentPayload(
        stream: stream, runId: runId, seq: seq, ts: ts, data: data
    )
    return makeEventFrame(payload: payload, seq: seq)
}
