import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/data-cache.ts` (`DataCache` → `FragmentCache`).
// node's `mergeData` also JSON-parses the merged bytes; `FragmentCache.merge` returns the bytes and
// `WSClient.handleData` parses them (see NodeWSReceiveEventsTests for the parse-failure path).
// node sweeps expired entries on a 10 s timer; Swift sweeps with `sweep(now:)` (called on every
// merge), so fake timers become an explicit clock.

private func merged(_ data: Data?) throws -> JSONValue? {
    guard let data else { return nil }
    return try JSONValue(data: data)
}

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Suite struct NodeWSDataCacheTests {
    @Test("data-cache: mergeData is right when sum = 1")
    func sumOne() throws {
        var cache = FragmentCache()
        let combined = try merged(
            cache.merge(messageId: "message_id", sum: 1, seq: 0, traceId: "trace_id", data: bytes(#"{"data":"hello,world"}"#)))
        #expect(combined?["data"]?.stringValue == "hello,world")
        #expect(cache.entries["message_id"] == nil)
    }

    @Test("data-cache: mergeData is right when sum > 2")
    func sumTwo() throws {
        var cache = FragmentCache()
        let first = try cache.merge(messageId: "message_id", sum: 2, seq: 0, traceId: "trace_id", data: bytes(#"{"data":"hello,"#))
        #expect(first == nil)
        let combined = try merged(cache.merge(messageId: "message_id", sum: 2, seq: 1, traceId: "trace_id", data: bytes(#"world"}"#)))
        #expect(combined?["data"]?.stringValue == "hello,world")
    }

    @Test("data-cache: data is expired")
    func expired() throws {
        var cache = FragmentCache()
        _ = try cache.merge(messageId: "message_id", sum: 2, seq: 0, traceId: "trace_id", data: bytes(#"{"data":"hello,world"}"#))
        let created = try #require(cache.entries["message_id"]?.created)
        cache.sweep(now: created.addingTimeInterval(10 * 2 + 0.1))
        #expect(cache.entries["message_id"] == nil)
    }

    @Test("data-cache: data is lived")
    func lived() throws {
        var cache = FragmentCache()
        _ = try cache.merge(messageId: "message_id", sum: 2, seq: 0, traceId: "trace_id", data: bytes(#"{"data":"hello,world"}"#))
        let created = try #require(cache.entries["message_id"]?.created)
        cache.sweep(now: created.addingTimeInterval(5))
        #expect(cache.entries["message_id"] != nil)
    }

    @Test("data-cache: destroy stops the sweep and clears the cache")
    func destroyClears() throws {
        // Swift has no sweep timer to stop (nothing keeps a process alive); `removeAll()` is what
        // `WSClient.close()` calls to drop cached fragments.
        var cache = FragmentCache()
        _ = try cache.merge(messageId: "message_id", sum: 2, seq: 0, traceId: "trace_id", data: bytes(#"{"data":"hello,"#))
        cache.removeAll()
        #expect(cache.entries.isEmpty)
    }

    // MARK: fragment metadata validation (#201)

    private let payload = bytes(#"{"a":1}"#)

    @Test("data-cache: merges out-of-order fragments")
    func outOfOrder() throws {
        var cache = FragmentCache()
        #expect(try cache.merge(messageId: "m", sum: 2, seq: 1, traceId: "t", data: payload.suffix(from: 4)) == nil)
        #expect(try merged(cache.merge(messageId: "m", sum: 2, seq: 0, traceId: "t", data: payload.prefix(4))) == ["a": 1])
    }

    /// node passes `Number(header)`; Swift parses the header with `Int(_:)`, so NaN / 2.5 / Infinity
    /// arrive as nil.
    @Test("data-cache: invalid sum %p throws", arguments: ["NaN", "0", "-1", "2.5", "Infinity"])
    func invalidSum(sum: String) {
        var cache = FragmentCache()
        let error = #expect(throws: LarkError.self) {
            try cache.merge(messageId: "m", sum: Int(sum), seq: 0, traceId: "t", data: payload.prefix(4))
        }
        #expect(error?.description.contains("invalid event fragment metadata") == true)
    }

    @Test("data-cache: invalid seq %p throws for sum = 2", arguments: ["-1", "2", "1.5", "NaN"])
    func invalidSeq(seq: String) {
        var cache = FragmentCache()
        let error = #expect(throws: LarkError.self) {
            try cache.merge(messageId: "m", sum: 2, seq: Int(seq), traceId: "t", data: payload.prefix(4))
        }
        #expect(error?.description.contains("invalid event fragment metadata") == true)
    }

    @Test("data-cache: a later fragment whose sum disagrees with the first one throws")
    func sumDisagrees() throws {
        var cache = FragmentCache()
        #expect(try cache.merge(messageId: "m", sum: 2, seq: 0, traceId: "t", data: payload.prefix(4)) == nil)
        let error = #expect(throws: LarkError.self) {
            try cache.merge(messageId: "m", sum: 3, seq: 2, traceId: "t", data: payload.prefix(4))
        }
        #expect(error?.description.contains("invalid event fragment metadata") == true)
        // The original fragment set is untouched and can still complete.
        #expect(try merged(cache.merge(messageId: "m", sum: 2, seq: 1, traceId: "t", data: payload.suffix(from: 4))) == ["a": 1])
    }
}
