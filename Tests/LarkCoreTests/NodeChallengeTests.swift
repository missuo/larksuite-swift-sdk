import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `adaptor/services/__tests__/challenge.ts` (`generateChallenge`).

@Suite struct NodeChallengeTests {
    @Test("challenge: generate right with normal challenge")
    func normalChallenge() throws {
        let result = try WebhookAdapter.generateChallenge(
            body: ["challenge": "ajls384kdjx98XX", "type": "url_verification", "token": "audit-fixture"],
            encryptKey: "", verificationToken: "audit-fixture")
        #expect(result.isChallenge)
        #expect(result.challenge == ["challenge": "ajls384kdjx98XX"])
    }

    @Test("challenge: generate right with encrypt challenge")
    func encryptedChallenge() throws {
        // Vector from the node-sdk test itself.
        let result = try WebhookAdapter.generateChallenge(
            body: [
                "encrypt":
                    "tT1xP+ovuc0T3b/rnZX3ax76exqAn0ANQ6/U45GcciC0mgNBc8JtvqOJGNAPMKpgRs2dVU1NYk9VDeqS8T4SYtU0hzNU54aS84WnxvZ3VFfDcy/RyABlNqlUiGyLDzFI0yxdCMT4KR/YEQXlt6nZi50KwRlZ+A75r645KesZuLMljezYyY8VeeXEVjPw35+e"
            ],
            encryptKey: "mazhe.nerd", verificationToken: "iRdCP2WwXNBXRM3mGLqhrgch3cn0gbT6")
        #expect(result.isChallenge)
        #expect(result.challenge == ["challenge": "5634b122-c042-4634-bc7f-b07a3c3e77ad"])
    }

    @Test("challenge: generate right with no challenge")
    func noChallenge() throws {
        let result = try WebhookAdapter.generateChallenge(body: [:], encryptKey: "")
        #expect(!result.isChallenge)
        // `{ challenge: undefined }`: the key is absent once serialised.
        #expect(result.challenge["challenge"] == nil)
        #expect(result.challenge.jsonString() == "{}")
    }

    @Test("challenge: should throw in encrypt scene but not pass encryptKey")
    func encryptWithoutKey() {
        let error = #expect(throws: LarkError.self) {
            try WebhookAdapter.generateChallenge(body: ["encrypt": "encrypt"], encryptKey: "")
        }
        #expect(error?.description.contains("auto-challenge need encryptKey, please check for missing in dispatcher") == true)
    }
}
