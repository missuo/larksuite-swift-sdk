import Foundation
import LarkCore

/// Feishu `receive_id_type` (node-sdk `ReceiveIdType`).
enum ReceiveIdType: String, Sendable {
    case chatId = "chat_id"
    case openId = "open_id"
    case userId = "user_id"
    case unionId = "union_id"
    case email
}

/// Infers `receive_id_type` from the target id prefix:
/// `oc_` → chat_id, `ou_` → open_id, `on_` → union_id, contains `@` → email, else user_id.
///
/// - Throws: `LarkError.invalidArgument("empty receive_id")` for an empty id
///   (node-sdk throws a plain `Error` with the same message).
func detectReceiveIdType(_ to: String) throws -> ReceiveIdType {
    if to.isEmpty { throw LarkError.invalidArgument("empty receive_id") }
    if to.hasPrefix("oc_") { return .chatId }
    if to.hasPrefix("ou_") { return .openId }
    if to.hasPrefix("on_") { return .unionId }
    if to.contains("@") { return .email }
    return .userId
}
