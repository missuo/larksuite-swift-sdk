import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `utils/__tests__/fill-api-path.ts` (LarkURL.fillPath).

@Suite struct NodeFillApiPathTests {
    @Test("fill-api-path: fill right")
    func fillRight() throws {
        #expect(try LarkURL.fillPath("https://aaa", [:]) == "https://aaa")
        #expect(try LarkURL.fillPath("https://s/:aaa", ["aaa": "b"]) == "https://s/b")
        #expect(try LarkURL.fillPath("https://s/:aaa/:ccc", ["aaa": "b", "ccc": "cc"]) == "https://s/b/cc")
    }

    @Test("fill-api-path: preserve explicit port in custom domain")
    func preservePort() throws {
        #expect(
            try LarkURL.fillPath("http://localhost:3000/open-apis/items/:item_id", ["item_id": "item-1"])
                == "http://localhost:3000/open-apis/items/item-1")
        #expect(try LarkURL.fillPath("http://localhost:3000/open-apis/ping", [:]) == "http://localhost:3000/open-apis/ping")
    }

    @Test("fill-api-path: miss argument")
    func missArgument() {
        let error = #expect(throws: LarkError.self) { try LarkURL.fillPath("http://s/:aaa/:bbb", ["aaa": "1"]) }
        guard case .invalidArgument(let msg)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(msg == "request miss bbb path argument")
    }

    @Test("fill-api-path: miss argument reports the parameter, not the port")
    func missArgumentNotPort() {
        let error = #expect(throws: LarkError.self) { try LarkURL.fillPath("http://localhost:3000/open-apis/items/:item_id", [:]) }
        guard case .invalidArgument(let msg)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(msg == "request miss item_id path argument")
    }
}
