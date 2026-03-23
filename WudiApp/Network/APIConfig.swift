//
//  APIConfig.swift
//  WudiApp
//
//  接口 baseURL 配置，与 H5 一致：gva_api 用于登录/验证码，ios_manager_api 用于设备等
//

import Foundation

enum APIConfig {
    /// 主站 host（与 H5 一致；若仅支持 http 需在 Info.plist 配置 ATS 例外）
    static var host: String { "http://47.76.156.108" }
    
    /// 登录、验证码等 base（request.js baseURL /gva_api）
    static var gvaBaseURL: String { "\(host)/gva_api" }
    
    /// 设备、账号等 iOS 管理接口 base（request_ios.js baseURL /ios_manager_api）
    static var iosManagerBaseURL: String { "\(host)/ios_manager_api" }
    
    /// 同步 WebSocket（与 H5 ws_sync_api 一致：推送新消息、容器 WhatsApp 状态）
    /// 建连：`/ws_sync_api/ws?token=...`；可选 `device_token`；审核员 JWT 含 `chat_review` 时追加 `audit=true`（见 AI-REDEME.md）。
    static func syncWebSocketURLString(token: String, deviceToken: String?, includeAudit: Bool) -> String {
        let wsScheme = host.lowercased().hasPrefix("https") ? "wss" : "ws"
        let hostOnly = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        var url = "\(wsScheme)://\(hostOnly)/ws_sync_api/ws?token=\(encodedToken)"
        if let deviceToken, !deviceToken.isEmpty {
            let encodedDeviceToken = deviceToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceToken
            url += "&device_token=\(encodedDeviceToken)"
        }
        if includeAudit {
            url += "&audit=true"
        }
        return url
    }
}
