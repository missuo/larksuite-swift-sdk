import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `dispatcher/__tests__/webhook-credentials-provider.ts`.
// node runs the adapter cases against four HTTP adapters (default, express, koa, koa-router); Swift
// has a single framework-agnostic adapter (`handleWebhook`, the port of `adaptDefault`), so those
// cases are ported once against it.

/// Encrypted bodies produced by node-sdk's `encrypted(payload, key)` helper with Node `crypto`:
/// aes-256-cbc, key = sha256(key), iv = 16 × 0x01, plaintext = JSON.stringify(payload); signature =
/// sha256("timestampnonce" + key + JSON.stringify({ encrypt })).
private enum Vectors {
    /// event('') = {"schema":"2.0","header":{"event_type":"audit.test","token":""},"event":{}}
    static let emptyToken: [String: (body: String, signature: String)] = [
        "first-key": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBASsVMP6kL2iqE29ptYLO7MsIqAqotgcKb78oNBD/BVlyS5IrvB9n2dmRMQvSrRkd7WPVeINTk6uZOGwoH+vMq2Bhf0suDgq/RaMt2dyk9nDo"}"#,
            "181c9a43c427080f8e16e6da056d3adde9e750ece33c96fcc6ee4605affacc39"
        ),
        "second-key": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBAevRSO93fGyP3GFI3kcRIZKl8uxslapwWZyJneP/1dTRBuusoSnzlxtICRYafuoARgEafbgUglMN3FKB89aMwMW2FFDHS+7UXQ45P+ZJNl94"}"#,
            "bfe1eeb60fea193f166064c30e90402f25652e4718c8df75b3ccd28f92ecd17e"
        ),
        "first": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBAbreXSh3ar7uorOhd71fD9mirCt/IvUSo34KTdrSx95S0Ha1tTXUfkmGQgtelqELk1ZhPyKUISWRs0jBxYXbpKp7BSHDajCByRSn2XSItCox"}"#,
            "6a263dc5aad6688797c31070f94b600cb118d60d9bef02d7f652f8a097ab2a79"
        ),
        "second": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBAYoFl56ZIxC0yxan+YzNnQ+VLlIv+HHp8+rqNv7NRyTC29WZ5FI/zhU3VL6W7RhGvPHPUnpVO6R0GBfhYO6HdvizSnKudV8/717XpDKjeA+U"}"#,
            "8b286e85c3ae0811f1113be28b658e0642abefcc68a94bfa5828053861114536"
        ),
    ]
    /// {"type":"url_verification","token":"dynamic-token","challenge":"fixture"}
    static let dynamicChallenge: [String: (body: String, signature: String)] = [
        "first": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBARhFJytyHitjlsi0MQ7s3/9Zvvq+SmnapEqsPO0enlGWmGlxsq11VR0MS3TRqmwuo7bCQIwGehtzUSEpPt4Z5wSy/vx87wgAS9cMMprMvuwn"}"#,
            "8e00145b7f9dc62c9da92df9c0542b96fb873f62f6033c4968e00d67b49401b1"
        ),
        "second": (
            #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBAd8iQsPuU7fq16ssFQWER3huAXZttni6lzGM2+kBv4tmPVc2+fsFaREbi1V+LHEzXOWwBmMvfwwXek6ht+4yzLUvfzIS1pYdQ0lPWP9rlOwk"}"#,
            "e4fa3e7ed77fc380427d0ccc87df2d352cdabe5acd9bcab254fd218bf7642647"
        ),
    ]

    static func request(_ v: (body: String, signature: String)) -> WebhookRequest {
        WebhookRequest(
            headers: ["x-lark-request-timestamp": "timestamp", "x-lark-request-nonce": "nonce", "x-lark-signature": v.signature],
            body: Data(v.body.utf8))
    }
}

/// `jest.fn(() => credentials(...))`: counts calls; the body sees the 1-based call number.
final class ProviderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    let body: @Sendable (Int) async throws -> WebhookCredentials

    init(_ body: @escaping @Sendable (Int) async throws -> WebhookCredentials) { self.body = body }

    var count: Int { lock.withLock { _count } }

    var provider: WebhookCredentialsProvider {
        {
            let n = self.lock.withLock { () -> Int in
                self._count += 1
                return self._count
            }
            return try await self.body(n)
        }
    }
}

private func credentials(_ token: String, _ key: String = "") -> WebhookCredentials {
    WebhookCredentials(encryptKey: key, verificationToken: token)
}

private func event(_ token: String = "") -> WebhookRequest {
    webhook(["schema": "2.0", "header": ["event_type": "audit.test", "token": .string(token)], "event": [:]])
}

private func dispatcher(_ provider: ProviderSpy, verificationToken: String = "", logger: RecordingLogger = RecordingLogger()) -> EventDispatcher {
    EventDispatcher(
        verificationToken: verificationToken, credentialsProvider: provider.provider, cache: DefaultLarkCache(), logLevel: .trace,
        logger: logger)
}

private func jsonBody(_ r: WebhookResponse) -> JSONValue? { try? JSONValue(data: r.body) }

@Suite struct NodeWebhookCredentialsProviderTests {
    @Test("webhook-credentials-provider: provider is lazy, rotates token, and trusted WS bypasses it")
    func lazyRotationAndWSBypass() async throws {
        let current = Box(credentials("first"))
        let provider = ProviderSpy { _ in current.value }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        #expect(provider.count == 0)
        _ = try await d.invoke(event("first"))
        current.value = credentials("second")
        _ = try await d.invoke(event("first"))
        _ = try await d.invoke(event("second"))
        #expect(provider.count == 3)
        #expect(handler.count == 2)
        _ = try await d.invoke(event(), needCheck: false)
        #expect(provider.count == 3)
        #expect(handler.count == 3)
    }

    @Test("webhook-credentials-provider: rotated AES keys are used for signature and decryption")
    func rotatedAESKeys() async throws {
        let key = Box("first-key")
        let provider = ProviderSpy { _ in credentials("", key.value) }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        _ = try await d.invoke(Vectors.request(Vectors.emptyToken["first-key"]!))
        key.value = "second-key"
        _ = try await d.invoke(Vectors.request(Vectors.emptyToken["second-key"]!))
        _ = try await d.invoke(Vectors.request(Vectors.emptyToken["first-key"]!))
        #expect(handler.count == 2)
        #expect(provider.count == 3)
    }

    @Test("webhook-credentials-provider: concurrent asynchronous requests retain independent snapshots")
    func concurrentSnapshots() async throws {
        let resolvers = Box<[Int: CheckedContinuation<WebhookCredentials, Never>]>([:])
        let provider = ProviderSpy { n in
            await withCheckedContinuation { c in resolvers.mutate { $0[n] = c } }
        }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        let first = Task { try await d.invoke(Vectors.request(Vectors.emptyToken["first"]!)) }
        #expect(await eventually { resolvers.value.count == 1 })
        let second = Task { try await d.invoke(Vectors.request(Vectors.emptyToken["second"]!)) }
        #expect(await eventually { resolvers.value.count == 2 })
        resolvers.value[2]!.resume(returning: credentials("", "second"))
        _ = try await second.value
        resolvers.value[1]!.resume(returning: credentials("", "first"))
        _ = try await first.value
        #expect(handler.count == 2)
        #expect(provider.count == 2)
    }

    @Test("webhook-credentials-provider: copied snapshot survives mutation of the returned object")
    func snapshotSurvivesMutation() async throws {
        let supplied = Box(credentials("first"))
        let provider = ProviderSpy { _ in
            // Mutate the source right after handing it out; the returned value is a copy.
            defer { supplied.mutate { $0.verificationToken = "changed" } }
            return supplied.value
        }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        _ = try await d.invoke(event("first"))
        #expect(handler.count == 1)
        #expect(supplied.value.verificationToken == "changed")
    }

    @Test("webhook-credentials-provider: invalid provider result fails without static fallback %#")
    func invalidResultNoStaticFallback() async throws {
        // node feeds undefined / null / {} / wrongly typed fields; WebhookCredentials makes those
        // unrepresentable, so the remaining failure mode is a provider error.
        let provider = ProviderSpy { _ in throw TestError("invalid credentials") }
        let handler = HandlerSpy()
        let d = dispatcher(provider, verificationToken: "static").register("audit.test", handler.handler)
        let error = await #expect(throws: LarkError.self) { try await d.invoke(event("static")) }
        #expect(error?.description.contains("webhook credentials provider failed") == true)
        #expect(handler.count == 0)
    }

    @Test("webhook-credentials-provider: provider failure sanitizes error: async=%s", arguments: [false, true])
    func providerFailureSanitized(isAsync: Bool) async throws {
        let logger = RecordingLogger()
        let provider = ProviderSpy { _ in
            if isAsync { await Task.yield() }
            throw TestError("SECRET-key")
        }
        let handler = HandlerSpy()
        let d = dispatcher(provider, logger: logger).register("audit.test", handler.handler)
        let error = await #expect(throws: LarkError.self) { try await d.invoke(event()) }
        guard case .verificationFailed(let msg)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(msg == "webhook credentials provider failed")
        #expect(!String(describing: error).contains("SECRET-key"))
        #expect(handler.count == 0)
        #expect(!logger.messages(.error).joined().contains("SECRET-key"))
    }

    @Test("webhook-credentials-provider: empty successful credentials override static authentication")
    func emptyCredentialsOverrideStatic() async throws {
        let provider = ProviderSpy { _ in credentials("") }
        let handler = HandlerSpy()
        let d = dispatcher(provider, verificationToken: "static").register("audit.test", handler.handler)
        _ = try await d.invoke(event("wrong"))
        #expect(handler.count == 1)
    }

    @Test("webhook-credentials-provider: direct card callbacks resolve once and reject bad tokens")
    func directCardCallbacks() async throws {
        let provider = ProviderSpy { _ in credentials("card-token") }
        let handler = HandlerSpy()
        let card = CardActionHandler(credentialsProvider: provider.provider, cache: DefaultLarkCache(), logLevel: .fatal, handler: handler.handler)
        #expect(provider.count == 0)
        _ = try await card.invoke(event("card-token"))
        _ = try await card.invoke(event("wrong"))
        #expect(provider.count == 2)
        #expect(handler.count == 1)
    }

    // MARK: default adapter snapshot (`handleWebhook`)

    @Test("webhook-credentials-provider: default adapter snapshot: challenge and ordinary %s requests each resolve once", arguments: ["event", "card"])
    func adapterResolvesOnce(kind: String) async throws {
        let provider = ProviderSpy { n in credentials("token-\(n)") }
        let handler = HandlerSpy(returning: ["ok": true])
        let respond: @Sendable (WebhookRequest) async -> WebhookResponse
        if kind == "event" {
            let d = EventDispatcher(credentialsProvider: provider.provider, cache: DefaultLarkCache(), logLevel: .fatal)
                .register("audit.test", handler.handler)
            respond = { await d.handleWebhook($0) }
        } else {
            let c = CardActionHandler(credentialsProvider: provider.provider, cache: DefaultLarkCache(), logLevel: .fatal, handler: handler.handler)
            respond = { await c.handleWebhook($0) }
        }
        #expect(provider.count == 0)
        let response = await respond(webhook(["type": "url_verification", "token": "token-1", "challenge": "fixture"]))
        #expect(jsonBody(response) == ["challenge": "fixture"])
        _ = await respond(event("token-2"))
        #expect(provider.count == 2)
        #expect(handler.count == 1)
    }

    @Test("webhook-credentials-provider: default adapter snapshot: provider error is sanitized with autoChallenge=%s", arguments: [false, true])
    func adapterProviderErrorSanitized(autoChallenge: Bool) async throws {
        let provider = ProviderSpy { _ in throw TestError("SECRET-key") }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        let response = await d.handleWebhook(event(), autoChallenge: autoChallenge)
        #expect(response.statusCode == 403)
        #expect(jsonBody(response) == ["msg": "webhook verification failed"])
        #expect(provider.count == 1)
        #expect(handler.count == 0)
    }

    @Test("webhook-credentials-provider: default adapter snapshot: empty successful credentials preserve challenge behavior")
    func adapterEmptyCredentialsChallenge() async throws {
        let provider = ProviderSpy { _ in credentials("") }
        let d = dispatcher(provider, verificationToken: "static")
        let response = await d.handleWebhook(webhook(["type": "url_verification", "challenge": "fixture"]))
        #expect(jsonBody(response) == ["challenge": "fixture"])
        #expect(provider.count == 1)
    }

    @Test("webhook-credentials-provider: default adapter snapshot: encrypted challenge uses the rotated provider credentials")
    func adapterEncryptedChallengeRotation() async throws {
        let key = Box("first")
        let provider = ProviderSpy { _ in credentials("dynamic-token", key.value) }
        let d = dispatcher(provider)
        for nextKey in ["first", "second"] {
            key.value = nextKey
            let response = await d.handleWebhook(Vectors.request(Vectors.dynamicChallenge[nextKey]!))
            #expect(jsonBody(response) == ["challenge": "fixture"])
        }
        #expect(provider.count == 2)
    }

    @Test("webhook-credentials-provider: default adapter snapshot: encrypted ordinary requests share the same rotated key")
    func adapterEncryptedOrdinaryRotation() async throws {
        let key = Box("first")
        let provider = ProviderSpy { _ in credentials("", key.value) }
        let handler = HandlerSpy()
        let d = dispatcher(provider).register("audit.test", handler.handler)
        _ = await d.handleWebhook(Vectors.request(Vectors.emptyToken["first"]!))
        key.value = "second"
        _ = await d.handleWebhook(Vectors.request(Vectors.emptyToken["second"]!))
        #expect(provider.count == 2)
        #expect(handler.count == 2)
    }
}
