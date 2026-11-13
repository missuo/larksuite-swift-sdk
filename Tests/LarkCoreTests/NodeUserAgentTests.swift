import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `utils/__tests__/user-agent.ts` (UserAgent).
// The product token is `oapi-swift-sdk/<version>` instead of `oapi-node-sdk/<version>` (this is a
// different SDK); the sanitising and token rules are node's.

@Suite struct NodeUserAgentTests {
    static let base = "^oapi-swift-sdk/\\d+\\.\\d+\\.\\d+"

    func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    @Test("user-agent: returns the version from the real package.json")
    func sdkVersion() {
        #expect(matches(UserAgent.sdkVersion, "^\\d+\\.\\d+\\.\\d+"))
        #expect(UserAgent.sdkVersion != "unknown")
    }

    @Test("user-agent: passes token chars through unchanged")
    func sanitizePassThrough() {
        #expect(UserAgent.sanitize("cursor-bot") == "cursor-bot")
        #expect(UserAgent.sanitize("Team_2026.v1") == "Team_2026.v1")
    }

    @Test("user-agent: replaces unsupported chars with underscore")
    func sanitizeReplaces() {
        #expect(UserAgent.sanitize("hello world") == "hello_world")
        #expect(UserAgent.sanitize("foo/bar") == "foo_bar")
        #expect(UserAgent.sanitize("a b\tc\nd") == "a_b_c_d")
    }

    @Test("user-agent: replaces non-ASCII (including CJK) with underscore")
    func sanitizeNonASCII() {
        #expect(UserAgent.sanitize("机器人") == "___")
    }

    @Test("user-agent: clamps to 64 characters")
    func sanitizeClamps() {
        #expect(UserAgent.sanitize(String(repeating: "a", count: 200)).count == 64)
    }

    @Test("user-agent: no source → base UA only")
    func noSource() {
        let ua = UserAgent.build(source: nil, extraTags: [])
        #expect(matches(ua, Self.base))
        #expect(!ua.contains("source/"))
    }

    @Test("user-agent: empty string source → base UA only")
    func emptySource() {
        #expect(!UserAgent.build(source: "", extraTags: []).contains("source/"))
    }

    @Test("user-agent: valid source → appended as source/<name> product token")
    func validSource() {
        #expect(matches(UserAgent.build(source: "cursor-bot", extraTags: []), Self.base + " source/cursor-bot$"))
    }

    @Test("user-agent: source is sanitized before being appended")
    func sourceSanitized() {
        #expect(UserAgent.build(source: "my cool bot!", extraTags: []).contains("source/my_cool_bot_"))
    }

    @Test("user-agent: all-invalid-char source still produces a source/ token of underscores")
    func allInvalidSource() {
        #expect(UserAgent.build(source: "机器人", extraTags: []).contains("source/___"))
    }

    @Test("user-agent: extraTags are appended as bare product tokens after source")
    func extraTagsAfterSource() {
        #expect(matches(UserAgent.build(source: "cursor-bot", extraTags: ["channel"]), Self.base + " source/cursor-bot channel$"))
    }

    @Test("user-agent: extraTags are appended even without source")
    func extraTagsWithoutSource() {
        #expect(matches(UserAgent.build(source: nil, extraTags: ["channel"]), Self.base + " channel$"))
    }

    @Test("user-agent: multiple extraTags are appended in order")
    func multipleExtraTags() {
        #expect(UserAgent.build(source: "x", extraTags: ["channel", "beta"]).contains("source/x channel beta"))
    }

    @Test("user-agent: extraTags are sanitized (non-token chars replaced)")
    func extraTagsSanitized() {
        #expect(UserAgent.build(source: nil, extraTags: ["has space"]).contains("has_space"))
    }

    @Test("user-agent: empty extraTags are dropped (matches sanitize-then-append rule)")
    func emptyExtraTagsDropped() {
        #expect(matches(UserAgent.build(source: "x", extraTags: [""]), Self.base + " source/x$"))
    }
}
