//
//  JWTChatReviewClaim.swift
//  WudiApp
//
//  从 JWT payload 读取聊天审核订阅标记（与 AI-REDEME.md：chat_review: true 一致）。
//  未包含该字段时不拼接 audit=true，避免无权限用户 WS 握手 401。
//

import Foundation

enum JWTChatReviewClaim {
    /// 是否在同步 WebSocket URL 上附加 `audit=true`（SCRM 侧校验 chat_review 或 ios_roles 等）。
    static func shouldAppendAuditQuery(jwt: String) -> Bool {
        guard let payload = decodePayload(jwt: jwt) else {
            return false
        }
        let result: Bool
        if let b = payload["chat_review"] as? Bool {
            result = b
        } else if let i = payload["chat_review"] as? Int {
            result = i != 0
        } else if let s = payload["chat_review"] as? String {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result = v == "1" || v == "true" || v == "yes"
        } else {
            result = false
        }
        return result
    }

    private static func decodePayload(jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadPart = String(parts[1])
        guard let data = base64URLDecode(payloadPart),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - str.count % 4) % 4
        if pad > 0 { str.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: str)
    }
}
