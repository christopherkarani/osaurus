//
//  OpenClawGatewayConnectionReconnectionTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

private actor OpenClawReconnectCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor OpenClawReconnectDelayRecorder {
    private var values: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        values.append(nanoseconds)
    }

    func seconds() -> [Int] {
        values.map { Int($0 / 1_000_000_000) }
    }

    func nanoseconds() -> [UInt64] {
        values
    }
}

private actor OpenClawConnectionStateRecorder {
    private var states: [OpenClawGatewayConnectionState] = []

    func record(_ state: OpenClawGatewayConnectionState) {
        states.append(state)
    }

    func all() -> [OpenClawGatewayConnectionState] {
        states
    }
}

@Suite(.serialized)
struct OpenClawGatewayConnectionReconnectionTests {

    // MARK: - Exponential Backoff

    @Test
    func reconnectPolicy_usesExponentialBackoff() async {
        let attempts = OpenClawReconnectCounter()
        let delays = OpenClawReconnectDelayRecorder()
        let states = OpenClawConnectionStateRecorder()

        // Fail first 6, succeed on attempt 7
        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                let count = await attempts.value()
                await attempts.increment()
                if count < 6 {
                    throw OpenClawConnectionError.disconnected("simulated reconnect failure")
                }
                // 7th call (count == 6) succeeds
            },
            sleepHook: { nanoseconds in
                await delays.record(nanoseconds)
            },
            reconnectResyncHook: {}
        )

        let listenerID = await connection.addConnectionStateListener { state in
            await states.record(state)
        }
        defer { Task { await connection.removeConnectionStateListener(listenerID) } }

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1006")
        await connection._testWaitForReconnectCompletion()

        #expect(await attempts.value() == 7)

        // For unexpected disconnects (immediate: false), the loop sleeps before
        // each attempt, including the eventual successful one.
        let secs = await delays.seconds()
        #expect(secs.count == 7)

        // Jitter is ±25 %. Verify at minimum that the first delay is ~1 s and
        // the final delay is ~60 s (cap).
        if let first = secs.first {
            #expect(first >= 1 && first <= 2, "First delay \(first)s should be ~1 s")
        }
        if let last = secs.last {
            #expect(last >= 45 && last <= 75, "Final delay \(last)s should be ~60 s")
        }

        let recorded = await states.all()
        #expect(
            recorded.contains {
                if case .reconnecting(let attempt) = $0 { return attempt == 1 }
                return false
            }
        )
        #expect(
            recorded.contains {
                if case .reconnected = $0 { return true }
                return false
            }
        )
    }

    // MARK: - Unlimited Reconnect (past former 5-attempt limit)

    @Test
    func reconnectLoop_continuesPastFormerFiveAttemptLimit() async {
        let attempts = OpenClawReconnectCounter()
        let states = OpenClawConnectionStateRecorder()

        // Fail first 7, succeed on 8th call (count == 7 → attempt 8)
        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                let count = await attempts.value()
                await attempts.increment()
                if count < 7 {
                    throw OpenClawConnectionError.disconnected("simulated failure")
                }
            },
            sleepHook: { _ in },
            reconnectResyncHook: {}
        )

        let listenerID = await connection.addConnectionStateListener { state in
            await states.record(state)
        }
        defer { Task { await connection.removeConnectionStateListener(listenerID) } }

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1006")
        await connection._testWaitForReconnectCompletion()

        // The old code would have stopped at 5 and never reached 8.
        #expect(await attempts.value() == 8)
        #expect(
            await states.all().contains {
                if case .connected = $0 { return true }
                return false
            }
        )
    }

    // MARK: - Rate-limit Handling

    @Test
    func reconnectLoop_rateLimitedError_sleepsForRetryAfterMsAndRetriesSameAttempt() async {
        let connectCallCount = OpenClawReconnectCounter()
        let delays = OpenClawReconnectDelayRecorder()
        let states = OpenClawConnectionStateRecorder()

        // First connect call is rate-limited; second succeeds.
        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                let n = await connectCallCount.value()
                await connectCallCount.increment()
                if n == 0 {
                    throw OpenClawConnectionError.rateLimited(retryAfterMs: 5_000)
                }
                // Second call succeeds
            },
            sleepHook: { ns in
                await delays.record(ns)
            },
            reconnectResyncHook: {}
        )

        let listenerID = await connection.addConnectionStateListener { state in
            await states.record(state)
        }
        defer { Task { await connection.removeConnectionStateListener(listenerID) } }

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1006")
        await connection._testWaitForReconnectCompletion()

        // Two connect calls total: one rate-limited, one successful.
        #expect(await connectCallCount.value() == 2)

        // The rate-limit sleep of 5 000 ms must appear in the recorded delays.
        // max(5000, 1000) * 1_000_000 = 5_000_000_000 ns = 5 s.
        let secs = await delays.seconds()
        #expect(secs.contains(5), "Expected a 5-second rate-limit delay, got: \(secs)")

        // Both connect calls share attempt 1 (rate-limit does not count as a failure).
        let recorded = await states.all()
        let reconnectingStates = recorded.compactMap { state -> Int? in
            if case .reconnecting(let attempt) = state { return attempt }
            return nil
        }
        // Both iterations set reconnecting(1) — same attempt number.
        #expect(reconnectingStates.filter { $0 == 1 }.count >= 2)

        #expect(
            recorded.contains {
                if case .connected = $0 { return true }
                return false
            }
        )
    }

    // MARK: - Jitter

    @Test
    func reconnectLoop_jitterKeepsDelaysWithin30PercentOfBase() async {
        let attempts = OpenClawReconnectCounter()
        let delays = OpenClawReconnectDelayRecorder()

        // Fail first 4 attempts; 5th succeeds.
        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                let count = await attempts.value()
                await attempts.increment()
                if count < 4 {
                    throw OpenClawConnectionError.disconnected("simulated failure")
                }
            },
            sleepHook: { ns in
                await delays.record(ns)
            },
            reconnectResyncHook: {}
        )

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1006")
        await connection._testWaitForReconnectCompletion()

        // Unexpected disconnect → immediate:false → sleeps before all attempts,
        // including the successful one.
        // Expected bases (reconnectBackoffSeconds): [1, 2, 4, 8, 16]
        let expectedBases: [Double] = [1, 2, 4, 8, 16]
        let rawDelays = await delays.nanoseconds()

        #expect(rawDelays.count == 5, "Expected 5 delays, got \(rawDelays.count)")

        for (index, base) in expectedBases.enumerated() {
            guard index < rawDelays.count else { break }
            let actualSeconds = Double(rawDelays[index]) / 1_000_000_000
            let lower = base * 0.70
            let upper = base * 1.30
            #expect(
                actualSeconds >= lower && actualSeconds <= upper,
                "Delay \(actualSeconds)s at index \(index) not within ±30 % of base \(base)s"
            )
        }
    }

    // MARK: - Auth Failure

    @Test
    func authFailureDisconnect_doesNotRetryReconnect() async {
        let attempts = OpenClawReconnectCounter()
        let states = OpenClawConnectionStateRecorder()

        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                await attempts.increment()
            },
            sleepHook: { _ in }
        )

        let listenerID = await connection.addConnectionStateListener { state in
            await states.record(state)
        }
        defer { Task { await connection.removeConnectionStateListener(listenerID) } }

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1008 unauthorized")
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(await attempts.value() == 0)
        #expect(
            await states.all().contains {
                if case .failed(let message) = $0 {
                    return message.lowercased().contains("authentication")
                }
                return false
            }
        )
    }

    // MARK: - Slow Consumer (immediate reconnect)

    @Test
    func slowConsumerDisconnect_reconnectsImmediately() async {
        let attempts = OpenClawReconnectCounter()
        let delays = OpenClawReconnectDelayRecorder()
        let states = OpenClawConnectionStateRecorder()

        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                await attempts.increment()
            },
            sleepHook: { nanoseconds in
                await delays.record(nanoseconds)
            }
        )

        let listenerID = await connection.addConnectionStateListener { state in
            await states.record(state)
        }
        defer { Task { await connection.removeConnectionStateListener(listenerID) } }

        await connection._testSetReconnectContext(host: "127.0.0.1", port: 18789, token: "test-token")
        await connection._testSetConnected(true)
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1008 slow consumer")
        await connection._testWaitForReconnectCompletion()

        #expect(await attempts.value() == 1)
        #expect(await delays.seconds().isEmpty)

        let recorded = await states.all()
        #expect(
            recorded.contains {
                if case .reconnected = $0 { return true }
                return false
            }
        )
        #expect(
            recorded.contains {
                if case .connected = $0 { return true }
                return false
            }
        )
    }

    // MARK: - Disconnect Classification

    @Test
    func disconnectClassification_handlesCloseCodes() {
        #expect(
            OpenClawGatewayConnection._testClassifyDisconnect(
                reason: "close code=1000 normal closure",
                intentional: false
            ) == .intentional
        )
        #expect(
            OpenClawGatewayConnection._testClassifyDisconnect(
                reason: "close code=1006",
                intentional: false
            ) == .unexpected
        )
        #expect(
            OpenClawGatewayConnection._testClassifyDisconnect(
                reason: "close code=1008 slow consumer",
                intentional: false
            ) == .slowConsumer
        )
        #expect(
            OpenClawGatewayConnection._testClassifyDisconnect(
                reason: "close code=1008 unauthorized",
                intentional: false
            ) == .authFailure
        )
    }
}
