import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `utils/__tests__/format-url.ts` (LarkClient.makeURL (`${domain}/${formatUrl(url)}`)).

@Suite struct NodeFormatUrlTests {
    @Test("format-url: format right")
    func formatRight() throws {
        let client = try LarkClient(
            LarkConfiguration(appId: "cli_x", appSecret: "s", domain: .custom("https://d.test"), logLevel: .fatal, httpClient: MockHTTPClient { _ in
                throw TestError("unexpected")
            }))
        // formatUrl strips exactly one leading "/", then node joins with "/".
        #expect(try client.makeURL(path: "/a/b/c", query: nil, options: .none).absoluteString == "https://d.test/a/b/c")
        #expect(try client.makeURL(path: "a/b/c", query: nil, options: .none).absoluteString == "https://d.test/a/b/c")
        #expect(try client.makeURL(path: "", query: nil, options: .none).absoluteString == "https://d.test/")
    }
}
