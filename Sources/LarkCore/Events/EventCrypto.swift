import Crypto
import _CryptoExtras
import Foundation

/// Decrypts encrypted event / callback payloads (`{"encrypt": "..."}`).
///
/// The key is `SHA256(encryptKey)`; the ciphertext is base64(IV(16) + AES-256-CBC/PKCS#7).
public struct AESCipher: Sendable {
    let key: SymmetricKey

    public init(_ encryptKey: String) {
        key = SymmetricKey(data: SHA256.hash(data: Data(encryptKey.utf8)))
    }

    /// Decrypts a base64 payload into a UTF-8 string.
    public func decrypt(_ encrypted: String) throws -> String {
        guard let raw = Data(base64Encoded: encrypted), raw.count > 16 else {
            throw LarkError.verificationFailed("invalid encrypted payload")
        }
        let iv = try AES._CBC.IV(ivBytes: raw.prefix(16))
        let plain = try AES._CBC.decrypt(raw.dropFirst(16), using: key, iv: iv)
        guard let s = String(data: plain, encoding: .utf8) else {
            throw LarkError.verificationFailed("decrypted payload is not UTF-8")
        }
        return s
    }

    /// Encrypts a string (useful for tests and local tooling).
    public func encrypt(_ plain: String, iv: Data? = nil) throws -> String {
        let ivData = iv ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let cipher = try AES._CBC.encrypt(Data(plain.utf8), using: key, iv: try AES._CBC.IV(ivBytes: ivData))
        return (ivData + cipher).base64EncodedString()
    }
}

enum LarkDigest {
    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time string comparison.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
