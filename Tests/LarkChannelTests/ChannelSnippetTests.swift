import Foundation
import LarkChannel
import LarkCore
import Testing

/// Compile-checks the Channel code shown in README.md and the skill (never executed).
@Suite struct ChannelSnippetTests {
    func snippet() async throws {
        let channel = try createLarkChannel(LarkChannelOptions(appId: "cli_xxx", appSecret: "xxx"))
        _ = channel.on(.message) { msg in
            guard msg.chatType == .p2p || msg.mentionedBot else { return }
            _ = try await channel.send(msg.chatId, .markdown("**echo** \(msg.content)"), options: SendOptions(replyTo: msg.messageId))
        }
        _ = channel.on(.cardAction) { action in print(action) }
        try await channel.connect()

        _ = try await channel.send("oc_xxx", .image("/tmp/chart.png"))
        _ = try await channel.stream("oc_xxx", .markdown { stream in
            for word in ["Hello", ", ", "world"] { try await stream.append(word) }
        })
        await channel.disconnect()
    }

    @Test func compiles() {}
}
