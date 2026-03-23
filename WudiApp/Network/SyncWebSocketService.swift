//
//  SyncWebSocketService.swift
//  WudiApp
//
//  与 H5 Index.vue 的 syncWebSocket 一致：登录后连接，用于推送新消息和容器 WhatsApp 状态。
//  URL: ws(s)://host/ws_sync_api/ws?token=xxx[&device_token=][&audit=true]
//  心跳 30s ping，onopen 发送运行中容器 ID 列表（可为空，见 AI-REDEME.md）；消息：会话同步 + scrm_task_* 审核推送
//  另支持 AI-REDEME.md 请求帧 { event_type, params }：get_unread_count / clear_unread / fetch_messages_status
//  时刻监测连接状态，连接断开或收包/心跳失败时自动重连（指数退避，保证与后端长连）。
//

import Foundation
import Combine

#if DEBUG
private let debugLogEnabled = false
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {
    guard debugLogEnabled else { return }
    print(message())
}
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
#endif

/// 同步 WS 上 AI-REDEME.md RPC 的错误（未读/清未读/消息状态监控）
enum SyncWebSocketRPCError: Error {
    case notConnected
    case encodeFailed
    case disconnected
    case serverError(String)
    case unexpectedResponse
    case rpcBusy
}

/// 聊天审核 WS 的 client_hint（AI-REDEME.md）
struct AuditWSClientHint {
    let kind: String?
    let title: String?
    let body: String?
    let instanceId: String?
    let taskId: String?
    let taskStatus: String?
}

/// 同步 WebSocket 推送的消息类型（与 H5 一致 + 审核 scrm_task_*）
struct SyncWSMessage {
    let type: String?
    let instanceId: String?
    let value: String?
    let phone: String?
    let wsError: String?
    let messages: [[String: Any]]?
    /// 仅 type 为 scrm_task_created / scrm_task_updated 时有值
    let auditClientHint: AuditWSClientHint?
    let auditTaskDataStatus: String?
    
    /// 与 H5 一致：后端可能只发 data 字段（即内层）；instance_id 为 number 或 string；messages 在顶层或 data 下
    static func parse(_ data: Data) -> SyncWSMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        
        if let topType = json["type"] as? String,
           topType == "scrm_task_created" || topType == "scrm_task_updated" {
            let dataObj = json["data"] as? [String: Any]
            let status = dataObj?["status"] as? String
            let instFromData: String? = {
                if let s = dataObj?["instance_id"] as? String { return s }
                if let n = dataObj?["instance_id"] as? Int { return "\(n)" }
                if let d = dataObj?["instance_id"] as? Double { return "\(Int(d))" }
                return nil
            }()
            let hint = parseAuditClientHint(json["client_hint"])
            let instanceId = hint?.instanceId ?? instFromData
            return SyncWSMessage(
                type: topType,
                instanceId: instanceId,
                value: nil,
                phone: nil,
                wsError: nil,
                messages: nil,
                auditClientHint: hint,
                auditTaskDataStatus: status
            )
        }
        
        let root = (json["data"] as? [String: Any]) ?? json
        let type = root["type"] as? String
        let instanceId: String? = {
            if let n = root["instance_id"] as? Int { return "\(n)" }
            if let s = root["instance_id"] as? String { return s }
            if let d = root["instance_id"] as? Double { return "\(Int(d))" }
            return nil
        }()
        let value = root["value"] as? String
        let phone = root["phone"] as? String
        let wsError = root["ws_error"] as? String
        let messages = (root["messages"] as? [[String: Any]]) ?? (json["messages"] as? [[String: Any]])
        return SyncWSMessage(
            type: type,
            instanceId: instanceId,
            value: value,
            phone: phone,
            wsError: wsError,
            messages: messages,
            auditClientHint: nil,
            auditTaskDataStatus: nil
        )
    }
    
    private static func parseAuditClientHint(_ any: Any?) -> AuditWSClientHint? {
        guard let dict = any as? [String: Any] else { return nil }
        let inst: String? = {
            if let s = dict["instance_id"] as? String { return s }
            if let n = dict["instance_id"] as? Int { return "\(n)" }
            return nil
        }()
        return AuditWSClientHint(
            kind: dict["kind"] as? String,
            title: dict["title"] as? String,
            body: dict["body"] as? String,
            instanceId: inst,
            taskId: dict["task_id"] as? String,
            taskStatus: dict["task_status"] as? String
        )
    }
}

/// WebSocket 连接状态（用于顶部「连接服务器失败，重新连接中」提示）
enum SyncWSConnectionStatus {
    case disconnected  // 未连接（如已登出）
    case connecting    // 正在连接
    case connected     // 已连接
    case reconnecting  // 连接失败，正在重连（显示顶部提示）
}

/// 面向用户的连接提示状态（不直接暴露技术态）
enum SyncWSUserNoticeState {
    case none
    case connecting  // 轻提示：正在连接…
    case failed      // 失败提示：网络不可用/连接失败（带重试）
}

final class SyncWebSocketService: NSObject, ObservableObject {
    static let shared = SyncWebSocketService()
    
    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus: SyncWSConnectionStatus = .disconnected
    @Published private(set) var userNoticeState: SyncWSUserNoticeState = .none
    @Published private(set) var authInvalidFlag = false
    
    /// 收到容器状态或新消息时回调，主线程更新 UI（如 appState.accountInstances）
    var onSyncMessage: ((SyncWSMessage) -> Void)?
    /// 连接成功时回调，用于发送运行中容器 ID 列表（与 H5 onopen 一致）
    var onConnected: (() -> Void)?
    /// 鉴权失败/被踢下线时回调（必须提示用户重新登录）
    var onAuthInvalid: (() -> Void)?
    
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var noticeScheduleWorkItem: DispatchWorkItem?
    private var reconnectCycleStartedAt: Date?
    private var noticeAnchorAt: Date = Date()
    /// 重连间隔（秒），指数退避，最大 60 秒
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 60
    private let queue = DispatchQueue(label: "syncws")
    /// `nil` 表示本连接尚未成功发送过实例订阅（含空列表），避免与「从未发送」和「已发送 []」混淆（AI-REDEME：无容器也需注册）
    private var lastSentRunningInstanceIDs: [String]?
    private var isHandlingDisconnectCycle = false
    private var runningIDsChunkSize = 40
    private let minRunningIDsChunkSize = 15
    
    // MARK: - AI-REDEME.md RPC（event_type / params → type / data）
    private static let rpcInboundTypes: Set<String> = ["get_unread_count", "clear_unread", "fetch_messages_status"]
    private var pendingGetUnreadHandler: ((Result<[String: [String: Int]], Error>) -> Void)?
    private var pendingClearUnreadHandler: ((Result<Void, Error>) -> Void)?
    private var pendingFetchStatusAckHandler: ((Result<Void, Error>) -> Void)?
    /// `fetch_messages_status` 监控过程中的推送（含 status 变化或 error）；应在主线程读 UI
    var onFetchMessagesStatusData: (([String: Any]) -> Void)?
    
    private override init() {
        super.init()
    }
    
    private func flushRpcPending(_ error: Error) {
        if let h = pendingGetUnreadHandler {
            pendingGetUnreadHandler = nil
            h(.failure(error))
        }
        if let h = pendingClearUnreadHandler {
            pendingClearUnreadHandler = nil
            h(.failure(error))
        }
        if let h = pendingFetchStatusAckHandler {
            pendingFetchStatusAckHandler = nil
            h(.failure(error))
        }
    }
    
    private func sendRpcFrame(eventType: String, params: [String: Any], onSendFailure: @escaping (Error) -> Void) {
        let body: [String: Any] = ["event_type": eventType, "params": params]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: jsonData, encoding: .utf8) else {
            onSendFailure(SyncWebSocketRPCError.encodeFailed)
            return
        }
        guard let t = task else {
            onSendFailure(SyncWebSocketRPCError.notConnected)
            return
        }
        t.send(.string(text)) { [weak self] err in
            guard let err else { return }
            self?.queue.async {
                onSendFailure(err)
            }
        }
    }
    
    private static func parseUnreadCountMap(from dataObj: [String: Any]) -> [String: [String: Int]]? {
        guard let inner = dataObj["data"] as? [String: Any] else { return nil }
        var result: [String: [String: Int]] = [:]
        for (instanceId, any) in inner {
            guard let jidMap = any as? [String: Any] else { continue }
            var unreadByJid: [String: Int] = [:]
            for (jid, value) in jidMap {
                let count: Int = {
                    if let i = value as? Int { return i }
                    if let d = value as? Double { return Int(d) }
                    if let s = value as? String, let i = Int(s) { return i }
                    return 0
                }()
                unreadByJid[jid] = max(0, count)
            }
            result[instanceId] = unreadByJid
        }
        return result
    }
    
    private func dispatchRpcResponse(type: String, data: [String: Any]) {
        if let errText = data["error"] as? String, !errText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let err = SyncWebSocketRPCError.serverError(errText)
            switch type {
            case "get_unread_count":
                if let h = pendingGetUnreadHandler {
                    pendingGetUnreadHandler = nil
                    h(.failure(err))
                }
            case "clear_unread":
                if let h = pendingClearUnreadHandler {
                    pendingClearUnreadHandler = nil
                    h(.failure(err))
                }
            case "fetch_messages_status":
                if let h = pendingFetchStatusAckHandler {
                    pendingFetchStatusAckHandler = nil
                    h(.failure(err))
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onFetchMessagesStatusData?(data)
                }
            default:
                break
            }
            return
        }
        
        switch type {
        case "get_unread_count":
            guard let h = pendingGetUnreadHandler else { return }
            if let map = Self.parseUnreadCountMap(from: data) {
                pendingGetUnreadHandler = nil
                h(.success(map))
            } else {
                pendingGetUnreadHandler = nil
                h(.failure(SyncWebSocketRPCError.unexpectedResponse))
            }
        case "clear_unread":
            guard let h = pendingClearUnreadHandler else { return }
            let msg = (data["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            pendingClearUnreadHandler = nil
            if msg == "success" {
                h(.success(()))
            } else {
                h(.failure(SyncWebSocketRPCError.unexpectedResponse))
            }
        case "fetch_messages_status":
            if let msgRaw = data["message"] as? String {
                let msg = msgRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if msg == "success" || msg.contains("already running") {
                    if let h = pendingFetchStatusAckHandler {
                        pendingFetchStatusAckHandler = nil
                        h(.success(()))
                    }
                    return
                }
            }
            if data["id"] != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.onFetchMessagesStatusData?(data)
                }
            }
        default:
            break
        }
    }
    
    /// AI-REDEME.md `get_unread_count`；与 HTTP GetAllUnreadCount 同语义；单飞，忙则抛 `rpcBusy`
    func requestGetUnreadCount(instanceIds: [String]) async throws -> [String: [String: Int]] {
        let connected = await MainActor.run { self.isConnected }
        guard connected else { throw SyncWebSocketRPCError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: SyncWebSocketRPCError.disconnected)
                    return
                }
                guard self.pendingGetUnreadHandler == nil else {
                    cont.resume(throwing: SyncWebSocketRPCError.rpcBusy)
                    return
                }
                self.pendingGetUnreadHandler = { cont.resume(with: $0) }
                let ids = instanceIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                self.sendRpcFrame(eventType: "get_unread_count", params: ["instance_ids": ids]) { [weak self] err in
                    self?.queue.async {
                        guard let self else { return }
                        if let h = self.pendingGetUnreadHandler {
                            self.pendingGetUnreadHandler = nil
                            h(.failure(err))
                        }
                    }
                }
            }
        }
    }
    
    /// AI-REDEME.md `clear_unread`
    func requestClearUnread(instanceId: String, jid: String) async throws {
        let connected = await MainActor.run { self.isConnected }
        guard connected else { throw SyncWebSocketRPCError.notConnected }
        let iid = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let j = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !iid.isEmpty, !j.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: SyncWebSocketRPCError.disconnected)
                    return
                }
                guard self.pendingClearUnreadHandler == nil else {
                    cont.resume(throwing: SyncWebSocketRPCError.rpcBusy)
                    return
                }
                self.pendingClearUnreadHandler = { result in
                    switch result {
                    case .success:
                        cont.resume(returning: ())
                    case .failure(let e):
                        cont.resume(throwing: e)
                    }
                }
                self.sendRpcFrame(eventType: "clear_unread", params: ["instance_id": iid, "jid": j]) { [weak self] err in
                    self?.queue.async {
                        guard let self else { return }
                        if let h = self.pendingClearUnreadHandler {
                            self.pendingClearUnreadHandler = nil
                            h(.failure(err))
                        }
                    }
                }
            }
        }
    }
    
    /// AI-REDEME.md `fetch_messages_status` 启动监控；首包 ack 返回后结束；后续推送走 `onFetchMessagesStatusData`
    func requestFetchMessagesStatusStart(
        instanceId: String,
        msgId: String,
        chatRowId: String,
        boxIP: String,
        index: String,
        wsType: String?,
        uuid: String?
    ) async throws {
        let connected = await MainActor.run { self.isConnected }
        guard connected else { throw SyncWebSocketRPCError.notConnected }
        var params: [String: Any] = [
            "instance_id": instanceId.trimmingCharacters(in: .whitespacesAndNewlines),
            "msg_id": msgId.trimmingCharacters(in: .whitespacesAndNewlines),
            "chat_row_id": chatRowId.trimmingCharacters(in: .whitespacesAndNewlines),
            "box_ip": boxIP.trimmingCharacters(in: .whitespacesAndNewlines),
            "index": index.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let wsType, !wsType.isEmpty { params["ws_type"] = wsType }
        if let uuid, !uuid.isEmpty { params["uuid"] = uuid }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: SyncWebSocketRPCError.disconnected)
                    return
                }
                guard self.pendingFetchStatusAckHandler == nil else {
                    cont.resume(throwing: SyncWebSocketRPCError.rpcBusy)
                    return
                }
                self.pendingFetchStatusAckHandler = { result in
                    switch result {
                    case .success:
                        cont.resume(returning: ())
                    case .failure(let e):
                        cont.resume(throwing: e)
                    }
                }
                self.sendRpcFrame(eventType: "fetch_messages_status", params: params) { [weak self] err in
                    self?.queue.async {
                        guard let self else { return }
                        if let h = self.pendingFetchStatusAckHandler {
                            self.pendingFetchStatusAckHandler = nil
                            h(.failure(err))
                        }
                    }
                }
            }
        }
    }
    
    func connect(token: String) {
        debugLog("[SyncWS] connect() called tokenEmpty=\(token.isEmpty) status=\(connectionStatus)")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        queue.async { [weak self] in
            self?.isHandlingDisconnectCycle = false
        }
        lastSentRunningInstanceIDs = nil
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        guard !token.isEmpty else {
            setStatus(.disconnected)
            return
        }
        let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token")
        let includeAudit = JWTChatReviewClaim.shouldAppendAuditQuery(jwt: token)
        let urlString = APIConfig.syncWebSocketURLString(token: token, deviceToken: deviceToken, includeAudit: includeAudit)
        guard let url = URL(string: urlString) else {
            setStatus(.disconnected)
            return
        }
        debugLog("[SyncWS] connect url=\(urlString)")
        setStatus(.connecting)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // 与后端握手一致：Origin / Connection 等（参考 curl 示例）
        request.setValue(APIConfig.host, forHTTPHeaderField: "Origin")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.webSocketTask(with: request)
        task?.resume()
    }
    
    func disconnect() {
        debugLog("[SyncWS] disconnect() called")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        noticeScheduleWorkItem?.cancel()
        noticeScheduleWorkItem = nil
        reconnectDelay = 2
        reconnectCycleStartedAt = nil
        lastSentRunningInstanceIDs = nil
        queue.sync { [weak self] in
            self?.flushRpcPending(SyncWebSocketRPCError.disconnected)
        }
        queue.async { [weak self] in
            self?.isHandlingDisconnectCycle = false
        }
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        authInvalidFlag = false
        setStatus(.disconnected)
    }
    
    /// App 前台恢复后重置用户提示计时：3 秒内静默恢复，不打扰用户。
    func beginForegroundReconnectGrace(seconds: TimeInterval = 3) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            debugLog("[SyncWS] beginForegroundReconnectGrace seconds=\(seconds) status=\(self.connectionStatus)")
            self.noticeAnchorAt = Date().addingTimeInterval(max(0, seconds) - 3)
            self.updateUserNotice(for: self.connectionStatus)
        }
    }
    
    /// 用户主动重试
    func retryNow() {
        debugLog("[SyncWS] retryNow() called status=\(connectionStatus)")
        let token = APIClient.shared.token ?? ""
        guard !token.isEmpty else {
            setStatus(.disconnected)
            return
        }
        connect(token: token)
    }
    
    private func setStatus(_ status: SyncWSConnectionStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let previous = self.connectionStatus
            self.connectionStatus = status
            self.isConnected = (status == .connected)
            debugLog("[SyncWS] status \(previous) -> \(status)")
            if status == .connected || status == .disconnected {
                self.reconnectCycleStartedAt = nil
            } else if status == .reconnecting, previous != .reconnecting, self.reconnectCycleStartedAt == nil {
                self.reconnectCycleStartedAt = Date()
            }
            self.updateUserNotice(for: status)
        }
    }
    
    private func updateUserNotice(for status: SyncWSConnectionStatus) {
        noticeScheduleWorkItem?.cancel()
        noticeScheduleWorkItem = nil
        guard status == .reconnecting else {
            userNoticeState = .none
            debugLog("[SyncWS] userNotice -> none (status=\(status))")
            return
        }
        
        let now = Date()
        let cycleStart = reconnectCycleStartedAt ?? now
        let start = max(cycleStart, noticeAnchorAt)
        let elapsed = now.timeIntervalSince(start)
        
        if elapsed < 3 {
            userNoticeState = .none
            debugLog("[SyncWS] userNotice keep none elapsed=\(String(format: "%.2f", elapsed))")
            scheduleNoticeRefresh(after: 3 - elapsed)
            return
        }
        if elapsed < 8 {
            userNoticeState = .connecting
            debugLog("[SyncWS] userNotice -> connecting elapsed=\(String(format: "%.2f", elapsed))")
            scheduleNoticeRefresh(after: 8 - elapsed)
            return
        }
        userNoticeState = .failed
        debugLog("[SyncWS] userNotice -> failed elapsed=\(String(format: "%.2f", elapsed))")
    }
    
    private func scheduleNoticeRefresh(after delay: TimeInterval) {
        let safeDelay = max(0.05, delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updateUserNotice(for: self.connectionStatus)
        }
        noticeScheduleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay, execute: work)
    }
    
    private func markAuthInvalidAndStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.queue.sync {
                self.flushRpcPending(SyncWebSocketRPCError.disconnected)
            }
            debugLog("[SyncWS] markAuthInvalidAndStop()")
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.stopHeartbeat()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.reconnectCycleStartedAt = nil
            self.userNoticeState = .none
            self.authInvalidFlag = true
            self.queue.async { [weak self] in
                self?.isHandlingDisconnectCycle = false
            }
            self.onAuthInvalid?()
        }
    }
    
    private func isLikelyAuthFailure(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) -> Bool {
        if closeCode == .policyViolation || closeCode == .unsupportedData || closeCode == .protocolError {
            return true
        }
        guard let reason,
              let text = String(data: reason, encoding: .utf8)?.lowercased() else {
            return false
        }
        return text.contains("401")
            || text.contains("auth")
            || text.contains("token")
            || text.contains("unauthorized")
            || text.contains("forbidden")
    }
    
    private func isLikelyAuthFailure(error: Error?) -> Bool {
        guard let error = error else { return false }
        let ns = error as NSError
        let desc = ns.localizedDescription.lowercased()
        if desc.contains("401") || desc.contains("unauthorized") || desc.contains("auth") || desc.contains("token") {
            return true
        }
        if ns.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: ns.code)
            if code == .userAuthenticationRequired || code == .userCancelledAuthentication {
                return true
            }
        }
        if ns.domain == NSURLErrorDomain,
           ns.code == NSURLErrorUserAuthenticationRequired || ns.code == NSURLErrorUserCancelledAuthentication {
            return true
        }
        return false
    }
    
    private func connectionLost() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.flushRpcPending(SyncWebSocketRPCError.disconnected)
            guard self.connectionStatus != .disconnected else { return }
            guard !self.isHandlingDisconnectCycle else {
                debugLog("[SyncWS] connectionLost() ignored: already handling disconnect cycle")
                return
            }
            self.isHandlingDisconnectCycle = true
            debugLog("[SyncWS] connectionLost() status=\(self.connectionStatus)")
            DispatchQueue.main.async {
                self.stopHeartbeat()
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.session?.invalidateAndCancel()
                self.session = nil
                if self.reconnectCycleStartedAt == nil { self.reconnectCycleStartedAt = Date() }
            }
            self.scheduleReconnect()
        }
    }
    
    /// 与 H5 一致：发送 JSON 文本帧（实例 ID 数组，去重）
    func sendRunningInstanceIDs(_ ids: [String]) {
        guard let task = task else {
            debugLog("[SyncWS] sendRunningInstanceIDs skip: task=nil")
            return
        }
        var seen = Set<String>()
        let payload = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
        if let last = lastSentRunningInstanceIDs, last == payload {
            debugLog("[SyncWS] sendRunningInstanceIDs skip: unchanged payload count=\(payload.count)")
            return
        }
        let chunkSize = max(minRunningIDsChunkSize, runningIDsChunkSize)
        if payload.count <= chunkSize {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else {
                debugLog("[SyncWS] sendRunningInstanceIDs skip: JSONSerialization failed")
                return
            }
            debugLog("[SyncWS] sendRunningInstanceIDs ids.count=\(payload.count) bytes=\(text.utf8.count)")
            task.send(.string(text)) { [weak self] err in
                guard let self else { return }
                if let e = err {
                    debugLog("[SyncWS] send instance ids error: \(e)")
                } else {
                    self.lastSentRunningInstanceIDs = payload
                    debugLog("[SyncWS] send instance ids ok count=\(payload.count)")
                }
            }
            return
        }

        debugLog("[SyncWS] sendRunningInstanceIDs chunked total=\(payload.count) chunkSize=\(chunkSize)")
        var chunks: [[String]] = []
        chunks.reserveCapacity((payload.count + chunkSize - 1) / chunkSize)
        var i = 0
        while i < payload.count {
            let end = min(i + chunkSize, payload.count)
            chunks.append(Array(payload[i..<end]))
            i = end
        }
        lastSentRunningInstanceIDs = payload
        for (idx, chunk) in chunks.enumerated() {
            let delay = Double(idx) * 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard let task = self.task else { return }
                guard let data = try? JSONSerialization.data(withJSONObject: chunk),
                      let text = String(data: data, encoding: .utf8) else {
                    debugLog("[SyncWS] send instance ids chunk skip: JSONSerialization failed idx=\(idx)")
                    return
                }
                debugLog("[SyncWS] send instance ids chunk \(idx + 1)/\(chunks.count) count=\(chunk.count) bytes=\(text.utf8.count)")
                task.send(.string(text)) { [weak self] err in
                    if let e = err {
                        debugLog("[SyncWS] send instance ids chunk error idx=\(idx): \(e)")
                    } else if idx == chunks.count - 1 {
                        debugLog("[SyncWS] send instance ids chunked ok chunks=\(chunks.count)")
                    }
                }
            }
        }
    }
    
    private func startHeartbeat() {
        stopHeartbeat()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
            RunLoop.main.add(self.heartbeatTimer!, forMode: .common)
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func sendPing() {
        task?.send(.string("ping")) { [weak self] err in
            if err != nil {
                self?.connectionLost()
            }
        }
    }
    
    private func scheduleReconnect() {
        guard reconnectWorkItem == nil else {
            debugLog("[SyncWS] scheduleReconnect skip: already scheduled")
            return
        }
        setStatus(.reconnecting)
        let delay = reconnectDelay
        debugLog("[SyncWS] scheduleReconnect delay=\(delay)s nextDelay=\(min(reconnectDelay * 2, maxReconnectDelay))")
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            let token = APIClient.shared.token ?? ""
            guard !token.isEmpty else {
                debugLog("[SyncWS] reconnect fire but token empty -> disconnected")
                self.setStatus(.disconnected)
                return
            }
            debugLog("[SyncWS] reconnect fire -> connect()")
            self.connect(token: token)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    private func receiveNext() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if text == "pong" { break }
                    if let data = text.data(using: .utf8) {
                        self?.handleMessage(data)
                    }
                case .data(let data):
                    self?.handleMessage(data)
                @unknown default:
                    break
                }
                self?.receiveNext()
            case .failure:
                debugLog("[SyncWS] receive failure -> connectionLost")
                self?.connectionLost()
            }
        }
    }
    
    private func handleMessage(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "pong" { return }
            // 服务端对实例订阅等可能回纯文本 ack，非 JSON，勿当解析失败
            let lower = trimmed.lowercased()
            if lower == "success" || lower == "ok" {
                debugLog("[SyncWS] handleMessage server ack text=\(trimmed)")
                return
            }
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = json["type"] as? String,
           Self.rpcInboundTypes.contains(t) {
            let dataObj = json["data"] as? [String: Any] ?? [:]
            queue.async { [weak self] in
                self?.dispatchRpcResponse(type: t, data: dataObj)
            }
            return
        }
        guard let msg = SyncWSMessage.parse(data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary \(data.count)b>"
            debugLog("[SyncWS] handleMessage parse failed raw=\(preview)")
            return
        }
        let typeDesc = msg.type ?? "new_message"
        let instDesc = msg.instanceId ?? "?"
        let msgCount = msg.messages?.count ?? 0
        debugLog("[SyncWS] handleMessage type=\(typeDesc) instance_id=\(instDesc) messages.count=\(msgCount)")
        DispatchQueue.main.async { [weak self] in
            self?.onSyncMessage?(msg)
        }
    }
}

extension SyncWebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        debugLog("[SyncWS] didOpenWithProtocol connected")
        reconnectDelay = 2
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        queue.async { [weak self] in
            self?.isHandlingDisconnectCycle = false
        }
        setStatus(.connected)
        onConnected?()
        startHeartbeat()
        receiveNext()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        debugLog("[SyncWS] didCloseWith closeCode=\(closeCode.rawValue) reason=\(reasonText)")
        if closeCode == .messageTooBig {
            runningIDsChunkSize = max(minRunningIDsChunkSize, runningIDsChunkSize / 2)
            lastSentRunningInstanceIDs = nil
            debugLog("[SyncWS] close=1009 adjust runningIDsChunkSize -> \(runningIDsChunkSize)")
        }
        if isLikelyAuthFailure(closeCode: closeCode, reason: reason) {
            markAuthInvalidAndStop()
            return
        }
        connectionLost()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            debugLog("[SyncWS] didCompleteWithError=\((error as NSError).domain)#\((error as NSError).code) \(error.localizedDescription)")
        } else {
            debugLog("[SyncWS] didCompleteWithError=nil")
        }
        if isLikelyAuthFailure(error: error) {
            markAuthInvalidAndStop()
        } else if error != nil {
            connectionLost()
        }
    }
}
