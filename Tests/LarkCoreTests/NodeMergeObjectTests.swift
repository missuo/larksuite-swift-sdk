import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `utils/__tests__/merge-object.ts` (UserAccessTokenManager.update (the only core caller of mergeObject)).

@Suite struct NodeMergeObjectTests {
    func manager() throws -> (LarkClient, String) {
        let client = try LarkClient(
            LarkConfiguration(appId: "cli_merge", appSecret: "s", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: MockHTTPClient { _ in
                throw TestError("unexpected")
            }))
        return (client, "k")
    }

    func stored(_ client: LarkClient, _ key: String) async throws -> UserTokenInfo {
        let raw = try #require(await client.config.cache.get("cli_merge/\(LarkCacheKey.userAccessToken)/\(key)", namespace: nil))
        return try JSONDecoder().decode(UserTokenInfo.self, from: Data(raw.utf8))
    }

    @Test("merge-object: normal merge")
    func normalMerge() async throws {
        let (client, key) = try manager()
        await client.userAccessToken.update([key: UserTokenInfo(code: "1")])
        await client.userAccessToken.update([key: UserTokenInfo(token: "2")])
        #expect(try await stored(client, key) == UserTokenInfo(code: "1", token: "2"))
    }

    @Test("merge-object: intersect merge")
    func intersectMerge() async throws {
        let (client, key) = try manager()
        await client.userAccessToken.update([key: UserTokenInfo(code: "1")])
        await client.userAccessToken.update([key: UserTokenInfo(code: "2")])
        #expect(try await stored(client, key) == UserTokenInfo(code: "2"))
    }

    @Test("merge-object: undefined merge")
    func undefinedMerge() async throws {
        // mergeObject({a: 1, b: undefined}, {b: 2, c: undefined}) → {a: 1, b: 2}
        let (client, key) = try manager()
        await client.userAccessToken.update([key: UserTokenInfo(code: "1", token: nil)])
        await client.userAccessToken.update([key: UserTokenInfo(token: "2", refreshToken: nil)])
        #expect(try await stored(client, key) == UserTokenInfo(code: "1", token: "2"))

        // mergeObject({a: 1, b: undefined}, {a: 2, c: 3}) → {a: 2, b: undefined, c: 3}
        let key2 = "k2"
        await client.userAccessToken.update([key2: UserTokenInfo(code: "1", token: nil)])
        await client.userAccessToken.update([key2: UserTokenInfo(code: "2", refreshToken: "3")])
        #expect(try await stored(client, key2) == UserTokenInfo(code: "2", token: nil, refreshToken: "3"))
    }
}
