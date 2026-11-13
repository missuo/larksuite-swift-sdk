import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/reconnect.ts`: reconnect timer leak (#177), retryable vs
// fatal classification, pingTimeout watchdog, handshake timeout and connection status.
//
// node drives private methods (`reConnect`, `armLiveness`, ...) and fields through `client as any`;
// the Swift tests call the same internal actor methods via `@testable import` and set state with
// the `testSet` helpers in Mocks.swift. Pending HTTP requests / handshakes come from
// ControlledHTTPClient / ControlledConnector (the node tests' deferred mocks). Fake-timer waits
// become short real intervals (milliseconds) pushed through `applyClientConfig`, like the node
// tests' `wsConfig.updateWs`.

private final class Callbacks: Sendable {
    let ready = Box(0)
    let errors = Box<[String]>([])
}

private func makeClient(
    _ http: ControlledHTTPClient, connector: ControlledConnector = ControlledConnector(), appId: String = testWSAppId,
    handshakeTimeout: TimeInterval? = nil, pingTimeout: TimeInterval? = nil, callbacks: Callbacks = Callbacks()
) throws -> WSClient {
    try WSClient(
        .init(
            appId: appId, appSecret: "test-app-secret", logLevel: .fatal, httpClient: http, webSocketConnector: connector,
            autoReconnect: true, handshakeTimeout: handshakeTimeout, pingTimeout: pingTimeout,
            onReady: { callbacks.ready.mutate { $0 += 1 } },
            onError: { e in callbacks.errors.mutate { $0.append("\(e)") } }))
}

private func dispatcher() -> EventDispatcher { EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal) }

private func start(_ client: WSClient) -> Task<Void, Never> {
    Task { await client.start(eventDispatcher: dispatcher()) }
}

/// Closes the client and fails everything still pending so no task outlives the test.
private func cleanUp(_ client: WSClient, _ http: ControlledHTTPClient, _ connector: ControlledConnector, _ tasks: Task<Void, Never>...) async {
    await client.close()
    http.rejectAll()
    connector.failAll()
    for t in tasks { await t.value }
}

@Suite struct NodeWSReconnectTests {
    // MARK: WSClient reconnect timer leak (#177)

    @Test("reconnect: close() during an in-flight first handshake must not resurrect the client")
    func closeDuringFirstHandshake() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector, handshakeTimeout: 0.05)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsSuccess)  // pullConnectConfig succeeds
        #expect(await eventually { connector.pendingCount == 1 })  // connect() waits on the handshake

        // Caller gives up while the handshake is still in flight.
        await client.close()
        #expect(await client.testState.closed)

        // Watchdog fires -> connect() resolves false -> the abandoned isStart branch resumes.
        await started.value
        await sleepMs(120)

        // No new pullConnectConfig: the retry loop was never started.
        #expect(http.pendingCount == 0)
        #expect(http.requests.count == 1)
        #expect(await !client.testHasReconnectTimer)
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: a handshake that wins the race with close() is torn down, not adopted")
    func handshakeWinsRaceWithClose() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let callbacks = Callbacks()
        let client = try makeClient(http, connector: connector, callbacks: callbacks)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsSuccess)
        #expect(await eventually { connector.pendingCount == 1 })

        // Caller closes while the handshake is in flight...
        await client.close()
        // ...and only then does the peer complete it.
        let socket = try #require(connector.openNext())
        await started.value

        // The connection must not be adopted by a client the caller closed.
        #expect(callbacks.ready.value == 0)
        #expect(socket.closeCalls == [true])
        #expect(await !client.testHasConnection)
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: generation counter prevents stale loops from continuing")
    func generationCounterStopsStaleLoops() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        await client.testSet(isConnecting: false, dispatcher: dispatcher())
        await client.applyClientConfig(["ReconnectNonce": 0, "ReconnectInterval": 0.01, "ReconnectCount": 3])

        // reConnect(false) starts a reconnect loop; reconnectNonce = 0 fires it immediately.
        await client.reconnect()
        #expect(await eventually { http.pendingCount == 1 })
        let gen1 = await client.testState.generation

        // close() invalidates the loop.
        await client.close()
        #expect(await client.testState.generation > gen1)

        // Resolve the old in-flight request (fails), wait past reconnectInterval.
        http.resolveNext(ControlledHTTPClient.wsFailure(99999, "system busy"))
        await sleepMs(50)

        // The stale loop did not schedule a new tryConnect.
        #expect(http.pendingCount == 0)
        #expect(http.requests.count == 1)
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: reConnect(true) bypasses isConnecting guard and invalidates old loop")
    func reconnectStartBypassesGuard() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        await client.testSet(dispatcher: dispatcher())
        await client.applyClientConfig(["ReconnectNonce": 0, "ReconnectInterval": 0.01, "ReconnectCount": 3])

        await client.reconnect()
        #expect(await eventually { http.pendingCount == 1 })
        #expect(await client.testState.isConnecting)

        // reConnect(true) is not blocked by isConnecting: a new request is queued.
        let restarted = Task { await client.reconnect(isStart: true) }
        #expect(await eventually { http.pendingCount == 2 })

        // Resolve the old request: discarded by the generation check.
        http.resolveNext(ControlledHTTPClient.wsFailure(99999, "system busy"))
        await sleepMs(50)
        // Only the new reConnect(true)'s request remains.
        #expect(http.pendingCount == 1)

        // Clean up: let the new session reach its handshake, then fail it.
        http.resolveNext(ControlledHTTPClient.wsSuccess)
        #expect(await eventually { connector.pendingCount == 1 })
        await cleanUp(client, http, connector, restarted)
    }

    @Test("reconnect: 5 rapid close/start cycles produce no orphaned loops")
    func rapidCloseStartCycles() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        await client.testSet(dispatcher: dispatcher())
        await client.applyClientConfig(["ReconnectNonce": 0, "ReconnectInterval": 0.01, "ReconnectCount": 3])

        for _ in 0..<5 {
            await client.testSet(isConnecting: false)
            await client.reconnect()
            await sleepMs(5)
            await client.close()
        }

        // Resolve every in-flight tryConnect as a failure.
        while http.resolveNext(ControlledHTTPClient.wsFailure(99999, "system busy")) {}
        await sleepMs(100)  // well past any reconnectInterval

        // All loops exited on the generation / closed check: no new requests.
        #expect(http.pendingCount == 0)
        await cleanUp(client, http, connector)
    }

    // MARK: retryable vs fatal classification (only code 1000040343 is retryable)

    @Test("reconnect: first-connect: non-1000040343 code is fatal — onError fires once, no retry")
    func firstConnectFatal403() async throws {
        let http = ControlledHTTPClient()
        let callbacks = Callbacks()
        let client = try makeClient(http, callbacks: callbacks)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsFailure(403, "forbidden"))
        await started.value
        await sleepMs(30)

        #expect(callbacks.errors.value.count == 1)
        #expect(callbacks.errors.value.first?.contains("code=403") == true)
        #expect(http.pendingCount == 0)
    }

    @Test("reconnect: first-connect: code 1 (system_busy) is fatal under new rule")
    func firstConnectSystemBusyFatal() async throws {
        let http = ControlledHTTPClient()
        let callbacks = Callbacks()
        let client = try makeClient(http, callbacks: callbacks)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsFailure(1, "system busy"))
        await started.value
        await sleepMs(30)

        #expect(callbacks.errors.value.count == 1)
        #expect(callbacks.errors.value.first?.contains("code=1") == true)
        #expect(http.pendingCount == 0)
    }

    /// Answers every request with `reply` until onError fires (the node tests' drain loop).
    private func drain(_ http: ControlledHTTPClient, _ callbacks: Callbacks, _ reply: (ControlledHTTPClient) -> Void) async {
        for _ in 0..<20 {
            guard await eventually({ http.pendingCount > 0 || !callbacks.errors.value.isEmpty }) else { return }
            if !callbacks.errors.value.isEmpty { return }
            reply(http)
        }
    }

    @Test("reconnect: first-connect: code 1000040343 is retryable — enters retry loop")
    func firstConnectInternalErrorRetryable() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let callbacks = Callbacks()
        let client = try makeClient(http, connector: connector, callbacks: callbacks)
        // Bound the retry loop so the test exits.
        await client.applyClientConfig(["ReconnectCount": 2, "ReconnectInterval": 0.005, "ReconnectNonce": 0])

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })

        // 1st attempt (from isStart): retryable failure.
        http.resolveNext(ControlledHTTPClient.wsFailure(1000040343, "internal"))
        // The retry loop produces another request; onError has not fired yet.
        #expect(await eventually { http.pendingCount >= 1 })
        #expect(callbacks.errors.value.isEmpty)

        // Drain until exhausted.
        await drain(http, callbacks) { $0.resolveNext(ControlledHTTPClient.wsFailure(1000040343, "internal")) }

        #expect(await eventually { callbacks.errors.value.count == 1 })
        #expect(callbacks.errors.value.first?.contains("exhausted") == true)
        await cleanUp(client, http, connector, started)
    }

    @Test("reconnect: first-connect: HTTP exception (catch branch) is retryable")
    func firstConnectTransportErrorRetryable() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let callbacks = Callbacks()
        let client = try makeClient(http, connector: connector, callbacks: callbacks)
        await client.applyClientConfig(["ReconnectCount": 2, "ReconnectInterval": 0.005, "ReconnectNonce": 0])

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })

        // 1st attempt rejects with a network error.
        http.rejectNext(TestError("ETIMEDOUT"))
        #expect(await eventually { http.pendingCount >= 1 })
        #expect(callbacks.errors.value.isEmpty)

        await drain(http, callbacks) { $0.rejectNext(TestError("ETIMEDOUT")) }

        #expect(await eventually { callbacks.errors.value.count == 1 })
        #expect(callbacks.errors.value.first?.contains("exhausted") == true)
        await cleanUp(client, http, connector, started)
    }

    @Test("reconnect: reconnect-loop fatal resets hasEverConnected to false")
    func reconnectLoopFatalResetsHasEverConnected() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let callbacks = Callbacks()
        let client = try makeClient(http, connector: connector, callbacks: callbacks)
        // Simulate a prior successful connect.
        await client.testSet(hasEverConnected: true, dispatcher: dispatcher())
        await client.applyClientConfig(["ReconnectCount": 3, "ReconnectInterval": 0.005, "ReconnectNonce": 0])

        await client.reconnect()
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsFailure(403, "forbidden"))
        #expect(await eventually { !callbacks.errors.value.isEmpty })

        #expect(await client.testState.hasEverConnected == false)
        #expect(callbacks.errors.value.count == 1)
        #expect(callbacks.errors.value.first?.contains("code=403") == true)
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: start() with invalid appId logs error and does not connect")
    func invalidAppId() async throws {
        let cases = [
            "test-app-id",  // legacy fixture format
            "cli_short",  // too short
            "cli_00000000000000000",  // too long (17 hex chars)
            "cli_g000000000000001",  // non-hex char
            "CLI_0000000000000001",  // wrong prefix case
            "",  // empty
        ]
        for appId in cases {
            let http = ControlledHTTPClient()
            let logger = RecordingLogger()
            let client = try WSClient(
                .init(appId: appId, appSecret: "secret", logLevel: .error, logger: logger, httpClient: http, webSocketConnector: ControlledConnector()))
            await client.start(eventDispatcher: dispatcher())
            #expect(http.requests.isEmpty, "appId \(appId)")
            #expect(logger.messages(.error).contains("[ws] invalid appId: \(appId)"))
        }
    }

    @Test("reconnect: start() accepts uppercase hex appId (loose validation)")
    func uppercaseHexAppId() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector, appId: "cli_ABCDEF0123456789")
        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        await cleanUp(client, http, connector, started)
    }

    @Test("reconnect: first-connect fatal also resets hasEverConnected to false")
    func firstConnectFatalResetsHasEverConnected() async throws {
        let http = ControlledHTTPClient()
        let callbacks = Callbacks()
        let client = try makeClient(http, callbacks: callbacks)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsFailure(514, "auth failed"))
        await started.value

        #expect(await client.testState.hasEverConnected == false)
        #expect(callbacks.errors.value.count == 1)
        #expect(callbacks.errors.value.first?.contains("code=514") == true)
    }

    // MARK: pingTimeout liveness watchdog

    @Test("reconnect: disabled by default — no watchdog, no auto-terminate")
    func watchdogDisabledByDefault() async throws {
        let client = try makeClient(ControlledHTTPClient())
        let id = await client.testAdopt(MockWebSocket())
        await client.armLiveness(id: id)
        #expect(await !client.testHasLivenessTimer)
    }

    @Test("reconnect: armLiveness schedules a timer when pingTimeout > 0")
    func watchdogArms() async throws {
        let client = try makeClient(ControlledHTTPClient(), pingTimeout: 1)
        let id = await client.testAdopt(MockWebSocket())
        await client.armLiveness(id: id)
        #expect(await client.testHasLivenessTimer)
        await client.clearLiveness()
    }

    @Test("reconnect: inbound message clears (not re-arms) the watchdog")
    func inboundClearsWatchdog() async throws {
        let client = try makeClient(ControlledHTTPClient(), pingTimeout: 1)
        let socket = MockWebSocket()
        let id = await client.testAdopt(socket)
        await client.armLiveness(id: id)
        #expect(await client.testHasLivenessTimer)
        // Any inbound frame (here a pong) runs the receive path, which clears the watchdog.
        await client.received(WSFrame(method: 0, headers: [.init(key: "type", value: "pong")]).serialized(), id: id)
        #expect(await !client.testHasLivenessTimer)
        await client.close()
    }

    @Test("reconnect: timer firing calls terminate() on the wsInstance")
    func watchdogTerminates() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector, pingTimeout: 0.05)
        let socket = MockWebSocket()
        let id = await client.testAdopt(socket)

        await client.armLiveness(id: id)
        #expect(await eventually { socket.closeCalls == [true] })
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: idle connection after pong does NOT trigger watchdog (regression)")
    func idleAfterPongDoesNotTerminate() async throws {
        // ping → arm → pong inbound → clear → idle past the original window.
        let client = try makeClient(ControlledHTTPClient(), pingTimeout: 0.3)
        let socket = MockWebSocket()
        let id = await client.testAdopt(socket)

        await client.armLiveness(id: id)  // simulate "ping sent"
        await sleepMs(20)
        await client.clearLiveness()  // simulate "pong received"
        await sleepMs(450)  // wait past the original window

        #expect(socket.closeCalls.isEmpty)
        await client.close()
    }

    // MARK: handshakeTimeoutMs

    @Test("reconnect: hung handshake → terminate is guarded, connect resolves false, retry kicks in")
    func hungHandshakeTimesOut() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector, handshakeTimeout: 0.05)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsSuccess)  // pullConnectConfig succeeds
        // The connector never completes. The 50 ms watchdog abandons the attempt (connect() resolves
        // false) and the retry queues a second pullConnectConfig request.
        #expect(await eventually { http.requests.count == 2 })
        #expect(await eventually { connector.cancelledCount >= 1 })

        // A socket that completes after the watchdog gave up is terminated, never adopted.
        let late = try #require(connector.openNext())
        #expect(await eventually { late.closeCalls == [true] })

        await cleanUp(client, http, connector, started)
    }

    /// node's `ws` emits a late 'error' after `terminate()` / `close()` on a connecting socket, which
    /// would crash the process without a listener; Swift has no event emitters, so what remains is the
    /// close call itself (once, with the right mode).
    @Test("reconnect: closing a connecting socket keeps its late error handled ($label)", arguments: [true, false])
    func closeCallsTransportOnce(force: Bool) async throws {
        let client = try makeClient(ControlledHTTPClient(), appId: "cli_ABCDEF0123456789")
        let socket = MockWebSocket()
        await client.testAdopt(socket)

        await client.close(force: force)

        #expect(socket.closeCalls == [force])
        #expect(await !client.testHasConnection)
    }

    @Test("reconnect: unset handshakeTimeoutMs preserves original \"no timeout\" behavior")
    func noHandshakeTimeout() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsSuccess)
        #expect(await eventually { connector.pendingCount == 1 })
        await sleepMs(80)

        // Without a timeout, connect() stays pending → no second request.
        #expect(http.requests.count == 1)
        #expect(connector.cancelledCount == 0)
        await cleanUp(client, http, connector, started)
    }

    // MARK: getConnectionStatus

    @Test("reconnect: idle before start()")
    func idleBeforeStart() async throws {
        let client = try makeClient(ControlledHTTPClient())
        let s = await client.connectionStatus
        #expect(s.state == .idle)
        #expect(s.reconnectAttempts == 0)
        #expect(s.lastConnectTime == nil)
    }

    @Test("reconnect: connecting after start() before pullConfig resolves")
    func connectingAfterStart() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        #expect(await client.connectionStatus.state == .connecting)
        await cleanUp(client, http, connector, started)
    }

    @Test("reconnect: failed after fatal pullConnectConfig error")
    func failedAfterFatal() async throws {
        let http = ControlledHTTPClient()
        let callbacks = Callbacks()
        let client = try makeClient(http, callbacks: callbacks)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })
        // makeFailResponse() returns code 99999 — fatal.
        http.resolveNext(ControlledHTTPClient.wsFailure(99999, "system busy"))
        await started.value

        #expect(callbacks.errors.value.count == 1)
        #expect(await client.connectionStatus.state == .failed)
    }

    @Test("reconnect: reconnectAttempts counter increments in loopReConnect")
    func reconnectAttemptsIncrement() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        await client.testSet(dispatcher: dispatcher())
        await client.applyClientConfig(["ReconnectNonce": 0, "ReconnectInterval": 0.01, "ReconnectCount": 5])

        await client.reconnect()
        #expect(await eventually { http.pendingCount == 1 })

        // 1st retry attempt: retryable, so it loops once more.
        http.resolveNext(ControlledHTTPClient.wsFailure(1000040343, "internal"))
        await sleepMs(20)

        #expect(await client.connectionStatus.reconnectAttempts >= 1)
        await cleanUp(client, http, connector)
    }

    @Test("reconnect: start() clears stale terminalError")
    func startClearsTerminalError() async throws {
        let http = ControlledHTTPClient()
        let connector = ControlledConnector()
        let client = try makeClient(http, connector: connector)
        await client.testSet(terminalError: true, reconnectAttempts: 7)

        let started = start(client)
        #expect(await eventually { http.pendingCount == 1 })

        let s = await client.connectionStatus
        #expect(s.state == .connecting)
        #expect(s.reconnectAttempts == 0)
        await cleanUp(client, http, connector, started)
    }
}
