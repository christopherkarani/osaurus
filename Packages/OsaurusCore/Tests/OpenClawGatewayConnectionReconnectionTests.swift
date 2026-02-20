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
    @Test
    func reconnectPolicy_usesExponentialBackoffAndStopsAfterMaxAttempts() async {
        let attempts = OpenClawReconnectCounter()
        let delays = OpenClawReconnectDelayRecorder()
        let states = OpenClawConnectionStateRecorder()

        let connection = OpenClawGatewayConnection(
            reconnectConnectHook: { _, _, _ in
                await attempts.increment()
                throw OpenClawConnectionError.disconnected("simulated reconnect failure")
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
        await connection._testTriggerDisconnect(reason: "receive failed: close code=1006")
        await connection._testWaitForReconnectCompletion()

        #expect(await attempts.value() == 5)
        #expect(await delays.seconds() == [1, 2, 4, 8, 16])

        let recorded = await states.all()
        #expect(
            recorded.contains {
                if case .reconnecting(let attempt) = $0 {
                    return attempt == 1
                }
                return false
            }
        )
        #expect(
            recorded.contains {
                if case .failed(let message) = $0 {
                    return message.contains("failed to reconnect")
                }
                return false
            }
        )
    }

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
                if case .reconnected = $0 {
                    return true
                }
                return false
            }
        )
        #expect(
            recorded.contains {
                if case .connected = $0 {
                    return true
                }
                return false
            }
        )
    }

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
