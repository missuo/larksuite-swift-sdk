import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `dispatcher/__tests__/event.ts` (EventDispatcher register / unregister).

/// Counts invocations; returns `result` (node's `jest.fn()` / `mockResolvedValue`).
final class HandlerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [LarkEvent] = []
    let result: JSONValue?

    init(returning result: JSONValue? = nil) { self.result = result }

    var count: Int { lock.withLock { _calls.count } }
    var calls: [LarkEvent] { lock.withLock { _calls } }

    var handler: LarkEventHandler {
        { event in
            self.lock.withLock { self._calls.append(event) }
            return self.result
        }
    }
}

private func makeDispatcher() -> (RecordingLogger, EventDispatcher) {
    let logger = RecordingLogger()
    // trace lets every level through LoggerProxy; no encryptKey, so plaintext requests authenticate
    // with the fixture token.
    let dispatcher = EventDispatcher(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .trace, logger: logger)
    return (logger, dispatcher)
}

private func eventOf(_ type: String) -> WebhookRequest {
    let body: JSONValue = ["schema": "2.0", "header": ["event_type": .string(type), "token": "audit-fixture"], "event": [:]]
    return WebhookRequest(headers: [:], body: Data(body.jsonString().utf8))
}

@Suite struct NodeDispatcherEventTests {
    // MARK: EventDispatcher#unregister

    @Test("dispatcher/event: stops dispatching an event once its handler is removed")
    func unregisterStopsDispatch() async throws {
        let (_, dispatcher) = makeDispatcher()
        let handler = HandlerSpy()
        dispatcher.register("a.b", handler.handler)

        dispatcher.unregister("a.b")

        #expect(try await dispatcher.invoke(eventOf("a.b")) == .string("no a.b event handle"))
        #expect(handler.count == 0)
    }

    @Test("dispatcher/event: returns the dispatcher itself so register can be chained onto it")
    func unregisterChains() async throws {
        let (_, dispatcher) = makeDispatcher()
        let oldHandler = HandlerSpy()
        let newHandler = HandlerSpy()
        dispatcher.register("a.b", oldHandler.handler)

        let chained = dispatcher.unregister("a.b")

        #expect(chained === dispatcher)
        chained.register("a.b", newHandler.handler)
        _ = try await dispatcher.invoke(eventOf("a.b"))
        #expect(newHandler.count == 1)
        #expect(oldHandler.count == 0)
    }

    @Test("dispatcher/event: removes every key passed in a single call and leaves the rest registered")
    func unregisterMany() async throws {
        let (_, dispatcher) = makeDispatcher()
        let a = HandlerSpy(), b = HandlerSpy(), c = HandlerSpy()
        dispatcher.register("a", a.handler).register("b", b.handler).register("c", c.handler)

        dispatcher.unregister("a", "b")

        #expect(try await dispatcher.invoke(eventOf("a")) == .string("no a event handle"))
        #expect(try await dispatcher.invoke(eventOf("b")) == .string("no b event handle"))
        _ = try await dispatcher.invoke(eventOf("c"))
        #expect(a.count == 0)
        #expect(b.count == 0)
        #expect(c.count == 1)
    }

    @Test("dispatcher/event: treats unknown keys, repeated calls and an empty argument list as safe no-ops")
    func unregisterNoOps() async throws {
        let (logger, dispatcher) = makeDispatcher()
        let handlerAB = HandlerSpy()
        let untouched = HandlerSpy()
        dispatcher.register("a.b", handlerAB.handler).register("c", untouched.handler)
        logger.clear()

        dispatcher.unregister("never.registered")
        dispatcher.unregister("a.b")
        dispatcher.unregister("a.b")
        dispatcher.unregister()
        dispatcher.unregister("__proto__")

        #expect(logger.messages(.error).isEmpty)
        // The registry is a dictionary: "__proto__" is an ordinary key, nothing special happens.
        #expect(dispatcher.registeredEventTypes == ["app_ticket", "c"])
        _ = try await dispatcher.invoke(eventOf("c"))
        #expect(untouched.count == 1)
    }

    @Test("dispatcher/event: warns that removing app_ticket makes ISV token lookups trigger a resend")
    func unregisterAppTicketWarns() async throws {
        let (logger, dispatcher) = makeDispatcher()
        logger.clear()

        dispatcher.unregister("app_ticket")

        #expect(try await dispatcher.invoke(eventOf("app_ticket")) == .string("no app_ticket event handle"))
        #expect(logger.messages(.warn).contains { $0.contains("app_ticket") && $0.contains("resend") })
        #expect(logger.messages(.error).isEmpty)
    }

    // MARK: EventDispatcher#register

    @Test("dispatcher/event: logs nothing at warn or error when a handler is replaced via unregister")
    func replaceViaUnregisterIsSilent() async throws {
        let (logger, dispatcher) = makeDispatcher()
        let oldHandler = HandlerSpy()
        let newHandler = HandlerSpy()
        dispatcher.register("a.b", oldHandler.handler)
        logger.clear()

        dispatcher.unregister("a.b")
        dispatcher.register("a.b", newHandler.handler)
        _ = try await dispatcher.invoke(eventOf("a.b"))

        #expect(logger.messages(.error).isEmpty)
        #expect(logger.messages(.warn).isEmpty)
        #expect(newHandler.count == 1)
        #expect(oldHandler.count == 0)
    }

    @Test("dispatcher/event: warns rather than errors when a handler is overwritten without unregister")
    func overwriteWarns() async throws {
        let (logger, dispatcher) = makeDispatcher()
        let oldHandler = HandlerSpy()
        let newHandler = HandlerSpy()
        dispatcher.register("a.b", oldHandler.handler)
        logger.clear()

        dispatcher.register("a.b", newHandler.handler)
        _ = try await dispatcher.invoke(eventOf("a.b"))

        #expect(logger.messages(.error).isEmpty)
        let warnings = logger.messages(.warn)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("a.b") == true)
        #expect(warnings.first?.contains("unregister") == true)
        // Exact node-sdk text.
        #expect(
            warnings.first
                == "a.b handle is already registered and has been replaced, call unregister('a.b') first to replace it explicitly")
        #expect(newHandler.count == 1)
        #expect(oldHandler.count == 0)
    }

    @Test("dispatcher/event: stays silent when the built-in app_ticket handler is overwritten")
    func overwriteAppTicketSilent() async throws {
        let (logger, dispatcher) = makeDispatcher()
        let custom = HandlerSpy()
        logger.clear()

        dispatcher.register("app_ticket", custom.handler)
        _ = try await dispatcher.invoke(eventOf("app_ticket"))

        #expect(logger.messages(.error).isEmpty)
        #expect(logger.messages(.warn).isEmpty)
        #expect(custom.count == 1)
    }

    @Test("dispatcher/event: keeps register-only usage behaving exactly as before")
    func registerOnly() async throws {
        let (logger, dispatcher) = makeDispatcher()
        let handler = HandlerSpy(returning: "handled")
        logger.clear()

        #expect(dispatcher.register("x.y", handler.handler) === dispatcher)
        #expect(logger.messages(.error).isEmpty)
        #expect(logger.messages(.warn).isEmpty)

        #expect(try await dispatcher.invoke(eventOf("x.y")) == .string("handled"))
        #expect(handler.count == 1)
        #expect(try await dispatcher.invoke(eventOf("z.w")) == .string("no z.w event handle"))
    }
}
