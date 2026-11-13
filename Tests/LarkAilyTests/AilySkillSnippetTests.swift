import Foundation
import LarkAily
import LarkCore
import Testing

/// Compile-checks the Aily code shown in skills/lark-swift-sdk/SKILL.md (never executed).
@Suite struct AilySkillSnippetTests {
    func snippet(client: LarkClient) async throws {
        let aily = AilyClient(client: client)
        let reply = try await aily.completions.create(.init(message: "hi", ailyAppId: "spring_xxx"))
        print(reply)
        for try await chunk in try await aily.completions.createWithStream(.init(message: "hi", ailyAppId: "spring_xxx")) {
            print(chunk)
        }
    }

    @Test func compiles() {}
}
