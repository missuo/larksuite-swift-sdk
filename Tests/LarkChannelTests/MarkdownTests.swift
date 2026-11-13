import Foundation
import Testing
@testable import LarkChannel
import LarkCore

/// Ports of node-sdk `outbound/__tests__/{splitter,to-post,compose-mentions,merge-text}.test.ts`
/// plus node-produced vectors.
@Suite struct MarkdownTests {
    // MARK: compose-mentions.test.ts

    @Test func composeMentionsTextPrefix() {
        #expect(MarkdownTools.composeMentionsTextPrefix([]) == "")
        #expect(MarkdownTools.composeMentionsTextPrefix([MentionInfo(key: "@_user_1", openId: "ou_alice", name: "Alice")]) == #"<at user_id="ou_alice">Alice</at> "#)
        #expect(
            MarkdownTools.composeMentionsTextPrefix([
                MentionInfo(key: "@_user_1", openId: "ou_a", name: "A"), MentionInfo(key: "@_user_2", openId: "ou_b", name: "B"),
            ]) == #"<at user_id="ou_a">A</at> <at user_id="ou_b">B</at> "#)
        #expect(MarkdownTools.composeMentionsTextPrefix([MentionInfo(key: "@_x", name: "Anon")]) == "")
        #expect(
            MarkdownTools.composeMentionsTextPrefix([
                MentionInfo(key: "@_a", openId: "ou_a", name: "A"), MentionInfo(key: "@_b", openId: "ou_b"), MentionInfo(key: "@_c", name: "C"),
            ]) == Vectors["composeText"].string!)
    }

    @Test func composePostMentionElements() {
        #expect(
            MarkdownTools.composePostMentionElements([MentionInfo(key: "@_user_1", openId: "ou_alice", name: "Alice")]).map { $0.stringify() }
                == [#"{"tag":"at","user_id":"ou_alice","user_name":"Alice"}"#])
        #expect(MarkdownTools.composePostMentionElements([]).isEmpty)
    }

    // MARK: to-post.test.ts

    static func mdText(_ post: OrderedJSON) -> String { post["zh_cn"]!["content"]!.arrayValue![0].arrayValue![0]["text"]!.stringValue! }

    @Test func markdownToPostSingleMdElement() {
        let r = MarkdownTools.markdownToPost("hello world")
        #expect(r["zh_cn"]!["content"]!.arrayValue!.count == 1)
        #expect(r["zh_cn"]!["content"]!.arrayValue![0].arrayValue!.count == 1)
        #expect(r["zh_cn"]!["content"]!.arrayValue![0].arrayValue![0] == .obj(["tag": "md", "text": "hello world"]))
        #expect(Self.mdText(MarkdownTools.markdownToPost("hi **there** and `code` and [link](https://x)")) == "hi **there** and `code` and [link](https://x)")
    }

    @Test func markdownToPostHeadingDemotion() {
        #expect(Self.mdText(MarkdownTools.markdownToPost("# Title\n\nbody")).contains("#### Title"))
        let t = Self.mdText(MarkdownTools.markdownToPost("# A\n\n## B\n\n### C\n\n#### D"))
        #expect(t.contains("#### A") && t.contains("##### B") && t.contains("##### C") && t.contains("##### D"))
        #expect(Self.mdText(MarkdownTools.markdownToPost("#### existing H4")) == "#### existing H4")
        let code = Self.mdText(MarkdownTools.markdownToPost("# heading\n\n```ts\n# not a heading inside code\n```"))
        #expect(code.contains("#### heading") && code.contains("# not a heading inside code"))
        #expect(Self.mdText(MarkdownTools.markdownToPost("a\n\n\n\nb")) == "a\n\nb")
    }

    @Test func markdownToPostMentionsAndTitle() {
        #expect(
            Self.mdText(MarkdownTools.markdownToPost("hello", mentions: [MentionInfo(key: "@_user_1", openId: "ou_xxx", name: "Alice")]))
                == #"<at user_id="ou_xxx">Alice</at> hello"#)
        #expect(
            Self.mdText(
                MarkdownTools.markdownToPost(
                    "hi", mentions: [MentionInfo(key: "@_user_1", openId: "ou_a", name: "Alice"), MentionInfo(key: "@_user_2", openId: "ou_b", name: "Bob")]))
                == #"<at user_id="ou_a">Alice</at> <at user_id="ou_b">Bob</at> hi"#)
        #expect(MarkdownTools.markdownToPost("body", title: "My title")["zh_cn"]!["title"] == "My title")
        #expect(MarkdownTools.markdownToPost("body")["zh_cn"]!["title"] == "")
    }

    @Test func postToPlainText() {
        #expect(MarkdownTools.postToPlainText(MarkdownTools.markdownToPost("hello **world** [link](https://x)")) == "hello **world** [link](https://x)")
        let legacy = OrderedJSON.parse(
            #"{"zh_cn":{"content":[[{"tag":"text","text":"hello "},{"tag":"at","user_name":"Alice"},{"tag":"text","text":" see "},{"tag":"a","text":"docs","href":"https://x"},{"tag":"img","image_key":"img_1"}]]}}"#)
        #expect(MarkdownTools.postToPlainText(legacy) == "hello @Alice see docs[image]")
        #expect(MarkdownTools.postToPlainText(nil) == "")
        #expect(MarkdownTools.postToPlainText(.null) == "")
        #expect(MarkdownTools.postToPlainText(.object([])) == "")
    }

    @Test func markdownMatchesNodeVectors() {
        for p in Vectors["markdownToPost"].array {
            #expect(MarkdownTools.markdownToPost(p[0]!.string!).stringify() == p[1]!.string!, "\(p[0]!)")
        }
        #expect(
            MarkdownTools.markdownToPost(
                "hi",
                mentions: [MentionInfo(key: "@_user_1", openId: "ou_a", name: "Alice"), MentionInfo(key: "@_x", name: "NoId"), MentionInfo(key: "@_user_2", openId: "ou_b")],
                title: "T"
            ).stringify() == Vectors["markdownToPostMentions"].string!)
        for p in Vectors["optimizeV2"].array {
            #expect(MarkdownTools.optimizeMarkdownStyle(p[0]!.string!, cardVersion: 2) == p[1]!.string!, "\(p[0]!)")
        }
        for p in Vectors["postToPlainText"].array {
            #expect(MarkdownTools.postToPlainText(OrderedJSON(p[0]!)) == p[1]!.string!)
        }
    }

    // MARK: splitter.test.ts

    @Test func splitShortAndEmpty() {
        #expect(MarkdownTools.splitWithCodeFences("hello", limit: 100) == ["hello"])
        #expect(MarkdownTools.splitWithCodeFences("", limit: 100) == [""])
    }

    @Test func splitLongPlainText() {
        let text = Array(repeating: "aaaaaaaa", count: 20).joined(separator: "\n")
        let out = MarkdownTools.splitWithCodeFences(text, limit: 30)
        #expect(out.count > 1)
        #expect(out.allSatisfy { $0.count <= 40 })
    }

    @Test func splitClosesAndReopensFences() {
        let text = "```ts\n" + String(repeating: "x", count: 60) + "\n" + String(repeating: "y", count: 60) + "\n```"
        let out = MarkdownTools.splitWithCodeFences(text, limit: 40)
        for c in out { #expect((c.components(separatedBy: "```").count - 1) % 2 == 0) }
        for c in out.dropFirst() { #expect(c.hasPrefix("```")) }
        let py = MarkdownTools.splitWithCodeFences("```python\n" + String(repeating: "a", count: 100) + "\n```", limit: 40)
        #expect(py.count > 1)
        #expect(py[1].hasPrefix("```python"))
    }

    @Test func splitBeforeHeadingWhenMostlyFull() {
        let out = MarkdownTools.splitWithCodeFences(String(repeating: "a", count: 30) + "\n## Heading\nafter", limit: 40)
        #expect(out.contains { $0.hasPrefix("## Heading") })
    }

    @Test func splitMatchesNodeVectors() {
        for c in Vectors["split"].array {
            let out = MarkdownTools.splitWithCodeFences(c[0]!.string!, limit: c[1]!.intValue!)
            #expect(out == c[2]!.array.map { $0.string! }, "\(c[0]!)")
        }
        #expect(MarkdownTools.splitPlain("abcdefghij", limit: 4) == ["abcd", "efgh", "ij"])
        #expect(MarkdownTools.splitPlain("abc", limit: 4) == ["abc"])
    }

    // MARK: merge-text.test.ts

    @Test func mergeStreamingText() {
        #expect(MarkdownTools.mergeStreamingText("", "hello") == "hello")
        #expect(MarkdownTools.mergeStreamingText("hello", "") == "hello")
        #expect(MarkdownTools.mergeStreamingText("hello", "hello world") == "hello world")
        #expect(MarkdownTools.mergeStreamingText("hello world", "hello") == "hello world")
        #expect(MarkdownTools.mergeStreamingText("hello wor", "world foo") == "hello world foo")
        #expect(MarkdownTools.mergeStreamingText("abc", "xyz") == "abcxyz")
        #expect(MarkdownTools.mergeStreamingText("foo", "oo bar") == "foo bar")
        for c in Vectors["merge"].array {
            #expect(MarkdownTools.mergeStreamingText(c[0]!.string!, c[1]!.string!) == c[2]!.string!)
        }
    }

    // MARK: JS helpers

    @Test func jsHelpers() {
        #expect(JS.numberString(30) == "30")
        #expect(JS.numberString(1.5) == "1.5")
        #expect(JS.numberString(1e21) == "1e+21")
        #expect(JS.numberString(1.5e-7) == "1.5e-7")
        #expect(JS.numberString(0.000001) == "0.000001")
        #expect(JS.numberString(1.2345678901234568e20) == "123456789012345680000")
        #expect(JS.toFixed1(1.25) == "1.3")
        #expect(JS.toFixed1(1.75) == "1.8")
        #expect(JS.toFixed1(1.45) == "1.4")
        #expect(JS.parseInt("  42px") == 42)
        #expect(JS.parseInt("-7") == -7)
        #expect(JS.parseInt("x1") == nil)
        #expect(JS.trim("\u{FEFF}\u{3000} a \n") == "a")
        #expect(JS.slice("a😀b", 1, 3) == "😀")
        #expect(JS.replaceFirst("a X b X", "X", "[$&|$`|$'|$$|$1]") == "a [X|a | b X|$|$1] b X")
        #expect(JS.splitLines("a\r\nb\n") == ["a\r", "b", ""])
    }
}
