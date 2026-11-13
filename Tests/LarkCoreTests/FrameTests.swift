import Foundation
import Testing
@testable import LarkCore

@Suite struct FrameTests {
    // Vectors produced by the Node SDK's protobufjs pbbp2.Frame.encode.
    let nodeFrame = "CLW48P4tECoYByABKg0KBHR5cGUSBWV2ZW50KhAKCm1lc3NhZ2VfaWQSAm0xOgRqc29uQgd7ImEiOjF9Sgdsb2ctbmV3"
    let nodeNegative = "CAAQABj///////////8BIAA="

    @Test func encodesLikeProtobufJS() {
        let f = WSFrame(
            seqID: 12_345_678_901, logID: 42, service: 7, method: 1,
            headers: [.init(key: "type", value: "event"), .init(key: "message_id", value: "m1")],
            payloadType: "json", payload: Data(#"{"a":1}"#.utf8), logIDNew: "log-new")
        #expect(f.serialized().base64EncodedString() == nodeFrame)
        let neg = WSFrame(seqID: 0, logID: 0, service: -1, method: 0)
        #expect(neg.serialized().base64EncodedString() == nodeNegative)
    }

    @Test func decodesProtobufJSOutput() throws {
        let f = try WSFrame(serializedData: Data(base64Encoded: nodeFrame)!)
        #expect(f.seqID == 12_345_678_901)
        #expect(f.logID == 42)
        #expect(f.service == 7)
        #expect(f.method == 1)
        #expect(f.header("type") == "event")
        #expect(f.header("message_id") == "m1")
        #expect(f.payloadType == "json")
        #expect(f.payload == Data(#"{"a":1}"#.utf8))
        #expect(f.logIDNew == "log-new")
        let neg = try WSFrame(serializedData: Data(base64Encoded: nodeNegative)!)
        #expect(neg.service == -1)
    }

    @Test func rejectsTruncatedData() {
        var d = Data(base64Encoded: nodeFrame)!
        d.removeLast(3)
        #expect(throws: (any Error).self) { try WSFrame(serializedData: d) }
    }

    @Test func fragmentsAreReassembled() throws {
        var cache = FragmentCache()
        #expect(try cache.merge(messageId: "m", sum: 3, seq: 2, traceId: "t", data: Data("c".utf8)) == nil)
        #expect(try cache.merge(messageId: "m", sum: 3, seq: 0, traceId: "t", data: Data("a".utf8)) == nil)
        let merged = try cache.merge(messageId: "m", sum: 3, seq: 1, traceId: "t", data: Data("b".utf8))
        #expect(merged == Data("abc".utf8))
        #expect(cache.entries.isEmpty)
        #expect(try cache.merge(messageId: "x", sum: 1, seq: 0, traceId: "t", data: Data("z".utf8)) == Data("z".utf8))
    }

    @Test func invalidFragmentMetadataThrows() {
        var cache = FragmentCache()
        #expect(throws: (any Error).self) { try cache.merge(messageId: "m", sum: 0, seq: 0, traceId: "", data: Data()) }
        #expect(throws: (any Error).self) { try cache.merge(messageId: "m", sum: 2, seq: 2, traceId: "", data: Data()) }
        #expect(throws: (any Error).self) { try cache.merge(messageId: "m", sum: nil, seq: 0, traceId: "", data: Data()) }
        _ = try? cache.merge(messageId: "m", sum: 2, seq: 0, traceId: "", data: Data("a".utf8))
        #expect(throws: (any Error).self) { try cache.merge(messageId: "m", sum: 3, seq: 1, traceId: "", data: Data()) }
    }

    @Test func connectionHostReplacement() throws {
        let u = try WSClient.buildConnectionURL("wss://msg-frontier.feishu.cn/ws/v2?device_id=1&service_id=2", host: "127.0.0.1:8443")
        #expect(u.absoluteString == "wss://127.0.0.1:8443/ws/v2?device_id=1&service_id=2")
        #expect(throws: (any Error).self) { try WSClient.buildConnectionURL("https://x/ws", host: "h") }
    }
}
