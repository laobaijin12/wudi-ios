//
//  AppState.swift
//  WudiApp
//
//  全局登录状态：从 token 持久化推导 isLoggedIn，与 H5 user store 一致；
//  currentContainer / selectedTab 支持账号页「进入会话」切到对话 Tab。
//

import SwiftUI
import UserNotifications
import UIKit
import AudioToolbox

#if DEBUG
private let debugLogEnabled = false
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {
    guard debugLogEnabled else { return }
    print(message())
}
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
#endif

private let appStateStatusTraceEnabled = false
@inline(__always) private func appStateStatusTrace(_ message: @autoclosure () -> String) {
    guard appStateStatusTraceEnabled else { return }
    print("[AppStateStatus] \(message())")
}

extension Notification.Name {
    static let syncWSMessagesDidArrive = Notification.Name("syncWSMessagesDidArrive")
}

struct LiveChatSnapshot: Equatable {
    let displayName: String
    let avatarBase64: String?
    let preview: String
    let timestamp: Int64
}

struct InAppMessageBannerData: Identifiable, Equatable {
    let id = UUID()
    let notificationTitle: String
    let displayName: String
    let preview: String
    let instanceIdForApi: String
    let jid: String
}

struct PendingOpenChatRequest: Equatable {
    let instanceIdForApi: String
    let jid: String
    let displayName: String?
}

struct AppUserFeedback: Identifiable, Equatable {
    enum Level: Equatable {
        case success
        case error
        case info
    }
    
    let id = UUID()
    let message: String
    let level: Level
}

// MARK: - 账号容器菜单权限（POST /menu/getMenu → device → instances → btns，与 H5 asyncMenu 一致）
enum InstanceMenuButtonAuth {
    /// 进入会话 / 查看对话类能力；与菜单 `instances.btns` 对齐（如 `enter_chat_app`、`enter_conversation`）
    static let enterChatSessionKeys: [String] = [
        "enter_chat_app",
        "enter_conversation",
        "enter_session",
        "goto_chat",
        "chat_instance",
        "instance_chat",
        "to_chat",
        "open_chat",
        "instance_msg"
    ]
    /// 「分配设备」等；后端若使用其它 key 可在此补充
    static let assignDeviceKeys: [String] = [
        "assign_instance", "instance_assign", "assign", "wait_assign"
    ]
    
    /// `nil`：尚未拉到菜单，保持与历史行为一致（不隐藏账号页按钮）
    static func isGrantedLenient(_ auth: [String: Int]?, anyOf keys: [String]) -> Bool {
        guard let auth else { return true }
        return keys.contains { (auth[$0] ?? 0) != 0 }
    }
    
    /// `nil`：尚未拉到菜单，不发起依赖权限的网络请求（避免无权限窗口期误拉「全部对话」）
    static func isGrantedStrict(_ auth: [String: Int]?, anyOf keys: [String]) -> Bool {
        guard let auth else { return false }
        return keys.contains { (auth[$0] ?? 0) != 0 }
    }
}

final class AppState: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published var userNickName: String
    @Published var userLoginName: String?
    @Published var userHeaderImgURL: String?
    @Published var userID: Int?
    @Published var imEnabled: Bool
    @Published var imToken: String?
    @Published var imUserID: String?
    @Published var imExpireAt: Int64?
    /// 当前选中的容器（进入会话后对话页使用）
    @Published var currentContainer: Instance?
    /// 当前选中的 Tab（账号页「进入会话」可切换为 .chat）
    @Published var selectedTab: TabItem = .account
    /// 双击「对话」Tab 的回顶信号（仅用于 UI 滚动，不参与业务同步）
    @Published var chatTabScrollToTopToken: Int = 0
    /// 从「全部对话」请求跳转到账号页某个容器并高亮
    @Published var accountJumpToInstanceKey: String?
    @Published var accountJumpRequestToken: Int = 0
    
    /// 账号页持久化：切换 Tab 不丢失
    @Published var accountBoxes: [Box] = []
    @Published var accountSelectedBoxIPs: Set<String> = []
    @Published var accountInstances: [Instance] = []
    /// 账号页容器按钮权限（来自 /menu/getMenu 的 device/instances/btns）；nil 表示尚未拉到菜单
    @Published var accountInstanceButtonAuth: [String: Int]? = nil
    
    /// 对话页：WebSocket 新消息未读增量，key = "instanceId_jid"，与 H5 containerChatNewMessageCounts 一致
    @Published var sessionChatUnreadDelta: [String: Int] = [:]
    /// 服务端 unread_count 快照（按会话），用于稳定列表红点，避免切页刷新抖动
    @Published var serverUnreadByConversation: [String: Int] = [:]
    /// WS 实时消息快照：用于「全部对话」实时刷新预览/时间/头像
    @Published var liveChatSnapshots: [String: LiveChatSnapshot] = [:]
    @Published var liveChatSnapshotVersion: Int = 0
    /// 会话已读抵扣：key = "instanceId_jid"，value = 已抵扣的基础未读（用于覆盖 chat.newMessageCount）
    @Published var consumedBaseUnreadByConversation: [String: Int] = [:]
    /// 前台微信风格新消息弹窗
    @Published var inAppMessageBanner: InAppMessageBannerData?
    /// 前台弹窗点击后触发的会话跳转请求
    @Published var pendingOpenChatRequest: PendingOpenChatRequest?
    /// 聊天详情滚动位置记忆：key = "instanceId_jid"，value = message.id
    @Published var chatScrollAnchorByConversation: [String: String] = [:]
    /// 会话草稿：key = "instanceId_jid"，value = 草稿文本
    @Published var chatDraftByConversation: [String: String] = [:]
    /// 当前前台可见聊天会话 key（instanceId_jid），用于避免会话内仍累计未读
    @Published var activeChatConversationKey: String?
    /// 全局统一交互提示（保存/编辑/删除等）
    @Published var userFeedback: AppUserFeedback?
    /// 聊天审核列表刷新信号（WS `scrm_task_*` 时递增，供「消息审核」页监听）
    @Published var chatReviewListRefreshToken: Int = 0
    /// JWT 含 `chat_review` 时可见「消息审核」入口（与 WS `audit=true` 判定一致，见 AI-REDEME.md）
    @Published private(set) var hasChatReviewPermission: Bool = false
    /// GVA 待审核条数（仅在有审核权限时拉取/更新）
    @Published private(set) var chatReviewPendingCount: Int = 0
    
    /// 是否正在展示聊天详情页（进入聊天页后隐藏底部 TabBar）
    @Published var isInChatDetail: Bool = false
    
    private let tokenKey = "x-token"
    private let nickNameKey = "user_nick_name"
    private let loginNameKey = "user_login_name"
    private let headerImgKey = "user_header_img"
    private let userIDKey = "user_id"
    private let imEnabledKey = "im_enabled"
    private let imTokenKey = "im_token"
    private let imUserIDKey = "im_user_id"
    private let imExpireAtKey = "im_expire_at"
    private let accountSelectedBoxIPsKey = "account_selected_box_ips"
    private let chatDraftStoreKey = "chat_draft_by_conversation_v1"
    private var inAppBannerDismissWorkItem: DispatchWorkItem?
    private var userFeedbackDismissWorkItem: DispatchWorkItem?
    private var unauthorizedObserver: NSObjectProtocol?
    private var lastActiveChatIncomingSoundAt: TimeInterval = 0
    
    init() {
        let token = UserDefaults.standard.string(forKey: tokenKey)
        isLoggedIn = !(token ?? "").isEmpty
        userNickName = UserDefaults.standard.string(forKey: nickNameKey) ?? "未设置昵称"
        userLoginName = UserDefaults.standard.string(forKey: loginNameKey)
        userHeaderImgURL = UserDefaults.standard.string(forKey: headerImgKey)
        let id = UserDefaults.standard.object(forKey: userIDKey) as? Int
        userID = id
        imEnabled = UserDefaults.standard.object(forKey: imEnabledKey) as? Bool ?? false
        imToken = UserDefaults.standard.string(forKey: imTokenKey)
        imUserID = UserDefaults.standard.string(forKey: imUserIDKey)
        if let exp = UserDefaults.standard.object(forKey: imExpireAtKey) as? Int64 {
            imExpireAt = exp
        } else if let exp = UserDefaults.standard.object(forKey: imExpireAtKey) as? Int {
            imExpireAt = Int64(exp)
        } else {
            imExpireAt = nil
        }
        if let arr = UserDefaults.standard.array(forKey: accountSelectedBoxIPsKey) as? [String], !arr.isEmpty {
            accountSelectedBoxIPs = Set(arr)
        }
        if let drafts = UserDefaults.standard.dictionary(forKey: chatDraftStoreKey) as? [String: String] {
            chatDraftByConversation = drafts
        }
        if isLoggedIn {
            let t = UserDefaults.standard.string(forKey: tokenKey) ?? ""
            hasChatReviewPermission = JWTChatReviewClaim.shouldAppendAuditQuery(jwt: t)
        }
        Task { await restoreCachedStartupData() }
        if isLoggedIn {
            Task { await bootstrapUserAndMenuAfterLogin() }
        }
        unauthorizedObserver = NotificationCenter.default.addObserver(
            forName: .apiUnauthorizedDetected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUnauthorizedKickout()
        }
    }

    deinit {
        if let unauthorizedObserver {
            NotificationCenter.default.removeObserver(unauthorizedObserver)
        }
    }
    
    /// 登录成功后调用：保存 token 与用户信息，与 H5 setToken/setUserInfo 一致
    func didLogin(
        token: String,
        userName: String?,
        userID: Int?,
        headerImg: String?,
        imEnabled: Bool? = nil,
        imToken: String? = nil,
        imUserID: String? = nil,
        imExpireAt: Int64? = nil
    ) {
        UserDefaults.standard.set(token, forKey: tokenKey)
        APIClient.shared.token = token
        UserDefaults.standard.set(userName ?? userNickName, forKey: nickNameKey)
        UserDefaults.standard.set(userName, forKey: loginNameKey)
        UserDefaults.standard.set(headerImg, forKey: headerImgKey)
        let resolvedUserID = userID ?? Int((imUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        if let id = resolvedUserID {
            UserDefaults.standard.set(id, forKey: userIDKey)
        }
        userNickName = userName ?? userNickName
        userLoginName = userName
        userHeaderImgURL = headerImg
        self.userID = resolvedUserID
        self.imEnabled = imEnabled ?? false
        self.imToken = imToken
        self.imUserID = imUserID
        self.imExpireAt = imExpireAt
        UserDefaults.standard.set(self.imEnabled, forKey: imEnabledKey)
        if let imToken, !imToken.isEmpty {
            UserDefaults.standard.set(imToken, forKey: imTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: imTokenKey)
        }
        if let imUserID, !imUserID.isEmpty {
            UserDefaults.standard.set(imUserID, forKey: imUserIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: imUserIDKey)
        }
        if let imExpireAt {
            UserDefaults.standard.set(imExpireAt, forKey: imExpireAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: imExpireAtKey)
        }
        isLoggedIn = true
        accountInstanceButtonAuth = [:]
        APNSPushManager.shared.activateForLogin()
        Task { @MainActor in
            self.syncChatReviewPermissionFromToken()
        }
        Task { await bootstrapUserAndMenuAfterLogin() }
    }
    
    /// 退出登录：清除 token 与用户信息
    func logout() {
        let tokenBeforeLogout = APIClient.shared.token
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: nickNameKey)
        UserDefaults.standard.removeObject(forKey: loginNameKey)
        UserDefaults.standard.removeObject(forKey: headerImgKey)
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: imEnabledKey)
        UserDefaults.standard.removeObject(forKey: imTokenKey)
        UserDefaults.standard.removeObject(forKey: imUserIDKey)
        UserDefaults.standard.removeObject(forKey: imExpireAtKey)
        APIClient.shared.token = nil
        userNickName = "未设置昵称"
        userLoginName = nil
        userHeaderImgURL = nil
        userID = nil
        imEnabled = false
        imToken = nil
        imUserID = nil
        imExpireAt = nil
        currentContainer = nil
        selectedTab = .account
        accountBoxes = []
        accountSelectedBoxIPs = []
        accountInstances = []
        accountInstanceButtonAuth = nil
        sessionChatUnreadDelta = [:]
        serverUnreadByConversation = [:]
        liveChatSnapshots = [:]
        liveChatSnapshotVersion = 0
        consumedBaseUnreadByConversation = [:]
        inAppMessageBanner = nil
        pendingOpenChatRequest = nil
        chatScrollAnchorByConversation = [:]
        chatDraftByConversation = [:]
        activeChatConversationKey = nil
        userFeedback = nil
        inAppBannerDismissWorkItem?.cancel()
        inAppBannerDismissWorkItem = nil
        userFeedbackDismissWorkItem?.cancel()
        userFeedbackDismissWorkItem = nil
        UserDefaults.standard.removeObject(forKey: accountSelectedBoxIPsKey)
        UserDefaults.standard.removeObject(forKey: chatDraftStoreKey)
        SyncWebSocketService.shared.disconnect()
        SyncWebSocketService.shared.onSyncMessage = nil
        SyncWebSocketService.shared.onConnected = nil
        Task { await AppCacheStore.shared.removeCurrentUserCache() }
        APNSPushManager.shared.deactivateOnLogout(jwt: tokenBeforeLogout)
        isLoggedIn = false
        hasChatReviewPermission = false
        chatReviewPendingCount = 0
    }
    
    /// 根据当前 JWT 同步是否展示「消息审核」（`chat_review`）
    @MainActor
    func syncChatReviewPermissionFromToken() {
        let jwt = (APIClient.shared.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = !jwt.isEmpty && JWTChatReviewClaim.shouldAppendAuditQuery(jwt: jwt)
        hasChatReviewPermission = allowed
        if !allowed {
            chatReviewPendingCount = 0
        }
    }
    
    /// 拉取待审核总数（用于「我的」角标；无权限时不请求）
    func refreshChatReviewPendingCount() async {
        let allowed = await MainActor.run {
            syncChatReviewPermissionFromToken()
            return hasChatReviewPermission
        }
        guard allowed else { return }
        do {
            // 角标统计全部待审；勿传 userID，避免后端按当前用户过滤导致恒为 0
            let data = try await AuthService.shared.getChatReviewList(
                page: 1,
                pageSize: 1,
                reviewStatus: "pending",
                userID: nil
            )
            await MainActor.run {
                self.chatReviewPendingCount = max(0, data.total)
            }
        } catch {
            await MainActor.run {
                self.chatReviewPendingCount = 0
            }
        }
    }
    
    /// 消息审核页已拉待审列表时直接同步角标，避免重复请求
    @MainActor
    func applyChatReviewPendingTotalFromListFetch(total: Int) {
        guard hasChatReviewPermission else { return }
        chatReviewPendingCount = max(0, total)
    }
    
    /// 紧急清除：清空本地数据并退出登录（无确认弹窗）
    func emergencyWipeAndLogout() {
        let tokenBeforeLogout = APIClient.shared.token
        logout()
        Task {
            await AppCacheStore.shared.removeCurrentUserCache()
            await MainActor.run {
                self.purgeAllLocalAppData(tokenBeforeLogout: tokenBeforeLogout)
            }
        }
    }

    private func handleUnauthorizedKickout() {
        guard isLoggedIn else { return }
        logout()
    }
    
    private func purgeAllLocalAppData(tokenBeforeLogout: String?) {
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        
        APNSPushManager.shared.deactivateOnLogout(jwt: tokenBeforeLogout)
        
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        
        if let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil) {
            for url in items {
                try? fm.removeItem(at: url)
            }
        }
        
        if let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: supportURL, includingPropertiesForKeys: nil) {
            for url in items {
                try? fm.removeItem(at: url)
            }
        }
        
        if let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil) {
            for url in items {
                try? fm.removeItem(at: url)
            }
        }
        
        URLCache.shared.removeAllCachedResponses()

        isLoggedIn = false
        terminateAppIfPossible()
    }
    
    private func terminateAppIfPossible() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                exit(0)
            }
        }
    }
    
    private func bootstrapUserAndMenuAfterLogin() async {
        do {
            let info = try await AuthService.shared.getCurrentUserInfo()
            await MainActor.run {
                let mergedName = info.userName ?? info.nickName ?? self.userNickName
                self.userNickName = mergedName
                self.userLoginName = info.userName ?? self.userLoginName
                self.userHeaderImgURL = info.headerImg ?? self.userHeaderImgURL
                if let id = info.ID {
                    self.userID = id
                    UserDefaults.standard.set(id, forKey: self.userIDKey)
                }
                if let enabled = info.imEnabled {
                    self.imEnabled = enabled
                    UserDefaults.standard.set(enabled, forKey: self.imEnabledKey)
                }
                UserDefaults.standard.set(self.userNickName, forKey: self.nickNameKey)
                UserDefaults.standard.set(self.userLoginName, forKey: self.loginNameKey)
                UserDefaults.standard.set(self.userHeaderImgURL, forKey: self.headerImgKey)
            }
        } catch {
            // 用户信息拉取失败不阻塞主流程
        }
        
        do {
            let auth = try await AuthService.shared.getInstanceButtonPermissions()
            await MainActor.run {
                self.accountInstanceButtonAuth = auth
            }
        } catch {
            await MainActor.run {
                self.accountInstanceButtonAuth = [:]
            }
        }
        
        await MainActor.run {
            self.syncChatReviewPermissionFromToken()
        }
        await refreshChatReviewPendingCount()
        await MainActor.run {
            self.notifyAccountInstancesDidUpdate()
        }
    }
    
    func setChatDraft(conversationKey: String, text: String) {
        let key = conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            chatDraftByConversation.removeValue(forKey: key)
        } else {
            chatDraftByConversation[key] = draft
        }
        UserDefaults.standard.set(chatDraftByConversation, forKey: chatDraftStoreKey)
    }
    
    func clearChatDraft(conversationKey: String) {
        setChatDraft(conversationKey: conversationKey, text: "")
    }

    func setActiveChatConversation(instanceIdForApi: String, jid: String?) {
        let cleanInstance = instanceIdForApi.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJid = (jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstance.isEmpty, !cleanJid.isEmpty else {
            activeChatConversationKey = nil
            return
        }
        activeChatConversationKey = "\(cleanInstance)_\(cleanJid)"
    }

    func clearActiveChatConversation(instanceIdForApi: String, jid: String?) {
        let cleanInstance = instanceIdForApi.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJid = (jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstance.isEmpty, !cleanJid.isEmpty else {
            activeChatConversationKey = nil
            return
        }
        let key = "\(cleanInstance)_\(cleanJid)"
        if activeChatConversationKey == key {
            activeChatConversationKey = nil
        }
    }
    
    var isIMTokenExpired: Bool {
        guard let exp = imExpireAt, exp > 0 else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        return exp <= now
    }
    
    var isIMReady: Bool {
        guard imEnabled else { return false }
        let uid = (imUserID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (imToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, !token.isEmpty else { return false }
        return !isIMTokenExpired
    }
    
    var isAdminUser: Bool {
        (userLoginName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin"
    }
    
    func toggleAccountBoxSelection(_ boxIP: String) {
        if accountSelectedBoxIPs.contains(boxIP) {
            accountSelectedBoxIPs.remove(boxIP)
        } else {
            accountSelectedBoxIPs.insert(boxIP)
        }
        persistSelectedBoxIPs()
    }
    
    func removeAccountBoxSelection(_ boxIP: String) {
        accountSelectedBoxIPs.remove(boxIP)
        if accountSelectedBoxIPs.isEmpty {
            accountInstances = []
        }
        persistSelectedBoxIPs()
    }
    
    private func persistSelectedBoxIPs() {
        UserDefaults.standard.set(Array(accountSelectedBoxIPs), forKey: accountSelectedBoxIPsKey)
    }
    
    /// 账号页「全选」等一次性设置已选 box 时调用，会持久化以便下次启动后 WS 能订阅
    func setAccountSelectedBoxIPs(_ ips: Set<String>) {
        accountSelectedBoxIPs = ips
        persistSelectedBoxIPs()
    }
    
    /// 容器列表变更后通知同步 WebSocket 订阅（与 H5 onopen 发送运行中容器 ID 一致）。
    /// 无「进入会话」类菜单权限时不向 WS 上报实例 ID（发送空列表），与无对话能力角色一致。
    func notifyAccountInstancesDidUpdate() {
        let ids: [String]
        if canFetchInstanceChatLists {
            ids = accountInstances
                .filter { ($0.state ?? "").lowercased() == "running" }
                .compactMap(\.syncSubscriptionId)
        } else {
            ids = []
        }
        SyncWebSocketService.shared.sendRunningInstanceIDs(ids)
    }
    
    /// WebSocket 连接成功后：在 MainActor 上拉取实例（若有已选 box）并发送订阅，保证后端只收到一次有效列表、红点/推送能收到
    func refreshAccountInstancesForSyncIfNeeded() async {
        let hasBox = !accountSelectedBoxIPs.isEmpty
        debugLog("[SyncWS] refreshAccountInstancesForSyncIfNeeded accountSelectedBoxIPs.count=\(accountSelectedBoxIPs.count) accountInstances.count=\(accountInstances.count)")
        if hasBox {
            do {
                let all = try await AccountService.shared.getAllVisibleInstances(pageSize: 200)
                let filtered = all.filter { inst in
                    guard let boxIP = inst.boxIP else { return false }
                    return accountSelectedBoxIPs.contains(boxIP)
                }
                let running = filtered.filter { ($0.state ?? "").lowercased() == "running" }
                debugLog("[SyncWS] refreshAccountInstancesForSyncIfNeeded fetched total=\(filtered.count) running=\(running.count)")
                var merged = filtered
                // 关键修复：自动连接 WS 后也要合并 WhatsApp 同步状态，否则账号页右侧“已登录/未登录”要手动刷新才出现
                do {
                    let runningKeys = running.compactMap { inst -> String? in
                        guard let id = inst.ID else { return nil }
                        return "\(id)"
                    }
                    if !runningKeys.isEmpty {
                        let statusMap = try await AccountService.shared.getSyncStatus(instanceIds: runningKeys)
                        appStateStatusTrace("refreshAccountInstancesForSyncIfNeeded running=\(runningKeys.count) statusMap=\(statusMap.count)")
                        merged = filtered.map { inst in
                            let key = "\(inst.ID ?? 0)"
                            guard let s = statusMap[key] else { return inst }
                            var wsStatus = s.scrmWsStatus ?? ""
                            if let detail = s.scrmWsStatusDetail, !detail.isEmpty, detail != "登录" {
                                wsStatus = detail
                            }
                            appStateStatusTrace("instance=\(key) ws=\(s.scrmWsStatus ?? "-") detail=\(s.scrmWsStatusDetail ?? "-") final=\(wsStatus.isEmpty ? "-" : wsStatus)")
                            return inst.with(scrmWsStatus: wsStatus.isEmpty ? nil : wsStatus, scrmWsError: s.scrmWsError)
                        }
                    }
                } catch {
                    debugLog("[SyncWS] refreshAccountInstancesForSyncIfNeeded getSyncStatus error: \(error)")
                }
                await MainActor.run {
                    self.accountInstances = self.mergeStableUnreadIntoInstances(merged)
                    self.sortAccountInstances()
                    self.notifyAccountInstancesDidUpdate()
                }
                await AppCacheStore.shared.saveInstances(selectedBoxIPs: accountSelectedBoxIPs, instances: self.accountInstances)
                // 关键兜底：实例刷新后立即拉一次服务端未读，避免 APNS 后红点迟迟不出现
                await refreshUnreadCountsFromServerIfNeeded()
            } catch {
                debugLog("[SyncWS] refreshAccountInstancesForSyncIfNeeded fetch error: \(error)")
                await MainActor.run { self.notifyAccountInstancesDidUpdate() }
            }
        } else {
            let running = accountInstances.filter { ($0.state ?? "").lowercased() == "running" }
            debugLog("[SyncWS] refreshAccountInstancesForSyncIfNeeded no box selected, sending current running=\(running.count)")
            await MainActor.run { self.notifyAccountInstancesDidUpdate() }
        }
    }
    
    /// 账号页「进入会话」等入口：`nil` 未拉菜单时不拦截；已返回菜单则按 btns 判定
    var allowsEnterSessionByMenu: Bool {
        InstanceMenuButtonAuth.isGrantedLenient(accountInstanceButtonAuth, anyOf: InstanceMenuButtonAuth.enterChatSessionKeys)
    }
    
    /// 「我的」→「分配设备」：`nil` 未拉菜单时不隐藏；已返回菜单则按 btns 判定
    var allowsAssignDeviceByMenu: Bool {
        InstanceMenuButtonAuth.isGrantedLenient(accountInstanceButtonAuth, anyOf: InstanceMenuButtonAuth.assignDeviceKeys)
    }
    
    /// 「全部对话」聚合拉取、未读轮询、SessionView 拉对话/联系人：仅菜单已返回且具备进入会话类权限时为 true
    var canFetchInstanceChatLists: Bool {
        InstanceMenuButtonAuth.isGrantedStrict(accountInstanceButtonAuth, anyOf: InstanceMenuButtonAuth.enterChatSessionKeys)
    }
    
    /// 进入会话：设置当前容器并切换到对话 Tab
    func enterSession(container: Instance) {
        guard allowsEnterSessionByMenu else {
            presentUserFeedback("当前账号无进入会话权限", level: .info)
            return
        }
        currentContainer = container
        selectedTab = .chat
    }

    
    /// 与 H5 sortContainerList 一致：已登录优先 → running 优先 → 有新消息优先
    func sortAccountInstances() {
        guard !accountInstances.isEmpty else { return }
        accountInstances = accountInstances.sorted { a, b in
            let aLoggedIn = (a.scrmWsStatus ?? "") == "已登录"
            let bLoggedIn = (b.scrmWsStatus ?? "") == "已登录"
            if aLoggedIn && !bLoggedIn { return true }
            if !aLoggedIn && bLoggedIn { return false }
            let aRunning = (a.state ?? "").lowercased() == "running"
            let bRunning = (b.state ?? "").lowercased() == "running"
            if aRunning && !bRunning { return true }
            if !aRunning && bRunning { return false }
            let aNew = (a.newMessageCount ?? 0) > 0
            let bNew = (b.newMessageCount ?? 0) > 0
            if aNew && !bNew { return true }
            if !aNew && bNew { return false }
            return false
        }
    }
    
    /// 对话 Tab 总未读数：与“全部对话”页口径保持一致，仅统计 running 容器。
    var totalUnreadCount: Int {
        accountInstances.reduce(0) { sum, inst in
            guard (inst.state ?? "").lowercased() == "running" else { return sum }
            return sum + (inst.newMessageCount ?? 0)
        }
    }
    
    /// 单一口径：会话未读 = max(基础剩余未读 + WS增量, 服务端快照)
    func conversationUnreadCount(instanceIdForApi: String, jid: String, baseUnreadHint: Int) -> Int {
        guard !instanceIdForApi.isEmpty, !jid.isEmpty else { return 0 }
        let key = "\(instanceIdForApi)_\(jid)"
        let prevConsumed = consumedBaseUnreadByConversation[key] ?? 0
        let baseUnreadRemaining = max(0, baseUnreadHint - prevConsumed)
        let deltaUnread = max(0, sessionChatUnreadDelta[key] ?? 0)
        let serverUnread = max(0, serverUnreadByConversation[key] ?? 0)
        return max(baseUnreadRemaining + deltaUnread, serverUnread)
    }
    
    private func extractInstanceIdFromConversationKey(_ key: String) -> String {
        if let range = key.range(of: "_business_") {
            var prefix = String(key[..<range.upperBound])
            if prefix.hasSuffix("_") { prefix.removeLast() }
            return prefix
        }
        if let idx = key.firstIndex(of: "_") {
            return String(key[..<idx])
        }
        return key
    }
    
    /// 应用服务端 unread_count 快照（按实例维度替换），避免旧快照导致红点漂移。
    func applyServerUnreadSnapshot(_ snapshot: [String: [String: Int]], queriedInstanceIds: Set<String>) {
        var next = serverUnreadByConversation
        if !queriedInstanceIds.isEmpty {
            for key in next.keys {
                let instanceId = extractInstanceIdFromConversationKey(key)
                if queriedInstanceIds.contains(instanceId) {
                    next.removeValue(forKey: key)
                }
            }
        }
        for (instanceId, jidMap) in snapshot {
            for (jid, count) in jidMap {
                let key = "\(instanceId)_\(jid)"
                next[key] = max(0, count)
            }
        }
        serverUnreadByConversation = next
    }
    
    /// 实例列表整体刷新时，保留历史未读的较大值，避免切页刷新把红点抹掉。
    func mergeStableUnreadIntoInstances(_ incoming: [Instance]) -> [Instance] {
        guard !accountInstances.isEmpty else { return incoming }
        var oldMap: [String: Int] = [:]
        for inst in accountInstances {
            let keys = [inst.instanceIdForApi, "\(inst.ID ?? 0)"] + inst.syncMatchKeys
            let unread = max(0, inst.newMessageCount ?? 0)
            for key in keys where !key.isEmpty {
                oldMap[key] = max(oldMap[key] ?? 0, unread)
            }
        }
        return incoming.map { inst in
            let keys = [inst.instanceIdForApi, "\(inst.ID ?? 0)"] + inst.syncMatchKeys
            var old = 0
            for key in keys where !key.isEmpty {
                old = max(old, oldMap[key] ?? 0)
            }
            let current = max(0, inst.newMessageCount ?? 0)
            return inst.with(newMessageCount: max(current, old))
        }
    }
    
    /// 以服务端未读结果回补容器红点（与 H5「取较大值，避免被旧数据覆盖」一致）
    func mergeServerUnreadTotals(_ totalsByInstance: [String: Int]) {
        guard !totalsByInstance.isEmpty else { return }
        var list = accountInstances
        var changed = false
        for i in list.indices {
            let inst = list[i]
            let key = inst.instanceIdForApi
            guard let serverTotal = totalsByInstance[key] else { continue }
            let current = inst.newMessageCount ?? 0
            // 服务端 unread_count 是快照，按快照覆盖可避免“已读后红点残留”。
            let merged = max(0, serverTotal)
            if merged != current {
                list[i] = inst.with(newMessageCount: merged)
                changed = true
            }
        }
        if changed {
            accountInstances = list
            sortAccountInstances()
            let total = totalUnreadCount
            UIApplication.shared.applicationIconBadgeNumber = total
            Task { await AppCacheStore.shared.saveInstances(selectedBoxIPs: self.accountSelectedBoxIPs, instances: self.accountInstances) }
        }
    }
    
    /// 前后台切换后的未读兜底回补：不依赖 WS 在线状态（与 H5 轮询未读策略一致）
    func refreshUnreadCountsFromServerIfNeeded() async {
        let runningInstanceIds = Array(
            Set(
                accountInstances
                    .filter { ($0.state ?? "").lowercased() == "running" }
                    .map(\.instanceIdForApi)
                    .filter { !$0.isEmpty }
            )
        )
        guard !runningInstanceIds.isEmpty else { return }
        do {
            let unreadByInstanceAndJid = try await ChatService.shared.getUnreadCounts(instanceIds: runningInstanceIds)
            var totals: [String: Int] = [:]
            for (instanceId, map) in unreadByInstanceAndJid {
                let sum = map.values.reduce(0, +)
                totals[instanceId] = max(0, sum)
            }
            await MainActor.run {
                self.applyServerUnreadSnapshot(unreadByInstanceAndJid, queriedInstanceIds: Set(runningInstanceIds))
                self.mergeServerUnreadTotals(totals)
            }
        } catch {
            // 静默失败，避免影响主流程
        }
    }
    
    /// 聊天审核实时推送（AI-REDEME.md：`scrm_task_*` + `client_hint`）
    private func applyChatReviewWebSocketMessage(_ msg: SyncWSMessage) {
        let hint = msg.auditClientHint
        debugLog("[ChatReviewWS] type=\(msg.type ?? "nil") data.status=\(msg.auditTaskDataStatus ?? "nil") kind=\(hint?.kind ?? "nil") task_id=\(hint?.taskId ?? "nil") instance=\(hint?.instanceId ?? msg.instanceId ?? "nil")")
        chatReviewListRefreshToken &+= 1
        // 与聊天新消息一致：走系统通知横幅（前台由 NewMessageNotificationDelegate 展示）
        ChatReviewNotificationHelper.notifyIfNeeded(for: msg)
        Task { await refreshChatReviewPendingCount() }
    }
    
    /// 应用同步 WebSocket 推送的容器状态/新消息（与 H5 onmessage / processNewMessage 一致）
    func applySyncWSMessage(_ msg: SyncWSMessage) {
        if msg.type == "scrm_task_created" || msg.type == "scrm_task_updated" {
            applyChatReviewWebSocketMessage(msg)
            return
        }
        guard let instanceId = msg.instanceId else {
            debugLog("[SyncWS] applySyncWSMessage skip: instanceId=nil")
            return
        }
        let idx = accountInstances.firstIndex(where: { inst in
            inst.syncMatchKeys.contains(instanceId) || inst.instanceIdForApi == instanceId || "\(inst.ID ?? 0)" == instanceId
        })
        guard let i = idx else {
            debugLog("[SyncWS] applySyncWSMessage skip: instance_id=\(instanceId) not found in accountInstances.count=\(accountInstances.count)")
            return
        }
        let inst = accountInstances[i]
        debugLog("[SyncWS] applySyncWSMessage type=\(msg.type ?? "nil") instance_id=\(instanceId) idx=\(i)")
        switch msg.type {
        case "err_changed":
            var list = accountInstances
            list[i] = inst.with(scrmWsError: msg.wsError)
            accountInstances = list
        case "sync_status_changed":
            break
        case "ws_status_detail_changed":
            var list = accountInstances
            list[i] = inst.with(scrmWsStatus: msg.value)
            accountInstances = list
        case "ws_status_changed":
            var list = accountInstances
            list[i] = inst.with(scrmWsStatus: msg.value)
            accountInstances = list
        default:
            if let messages = msg.messages, !messages.isEmpty {
                let current = inst.newMessageCount ?? 0
                var incomingCount = 0
                var delta = sessionChatUnreadDelta
                var snapshots = liveChatSnapshots
                var optimisticServerUnread = serverUnreadByConversation
                var firstBannerData: InAppMessageBannerData?
                var affectedJIDs = Set<String>()
                
                for m in messages {
                    guard let parsed = parseIncomingMessage(m, fallbackPhone: msg.phone) else { continue }
                    let normalizedKey = "\(inst.instanceIdForApi)_\(parsed.jid)"
                    affectedJIDs.insert(parsed.jid)
                    let previous = snapshots[normalizedKey]
                    let preferredDisplayName = preferredNotificationDisplayName(
                        incoming: parsed.displayName,
                        previous: previous?.displayName
                    )
                    let snapshotAvatar = parsed.avatarBase64 ?? previous?.avatarBase64
                    
                    // 会话最新摘要要更新（包括我发出的消息），但通知/未读只统计接收消息。
                    snapshots[normalizedKey] = LiveChatSnapshot(
                        displayName: preferredDisplayName,
                        avatarBase64: snapshotAvatar,
                        preview: parsed.preview,
                        timestamp: parsed.timestamp
                    )
                    if parsed.isOutgoing { continue }

                    // 仅在前台且确实停留在该会话详情页时，才抑制未读与系统通知。
                    // 锁屏/后台时不应抑制，否则会出现“来消息无提示”。
                    let shouldSuppressForActiveChat =
                        normalizedKey == activeChatConversationKey
                        && isInChatDetail
                        && UIApplication.shared.applicationState == .active
                    if shouldSuppressForActiveChat {
                        debugLog("[LockNotify] suppress incoming for active chat key=\(normalizedKey) appState=\(UIApplication.shared.applicationState.rawValue) isInChatDetail=\(isInChatDetail)")
                        playActiveChatIncomingHintIfNeeded()
                        delta[normalizedKey] = 0
                        optimisticServerUnread[normalizedKey] = 0
                        continue
                    }
                    
                    incomingCount += 1
                    delta[normalizedKey] = (delta[normalizedKey] ?? 0) + 1
                    optimisticServerUnread[normalizedKey] = max(0, (optimisticServerUnread[normalizedKey] ?? 0) + 1)
                    if firstBannerData == nil {
                        let title = notificationTitle(
                            displayName: preferredDisplayName,
                            isGroup: parsed.isGroup
                        )
                        firstBannerData = InAppMessageBannerData(
                            notificationTitle: title,
                            displayName: preferredDisplayName,
                            preview: parsed.preview,
                            instanceIdForApi: inst.instanceIdForApi,
                            jid: parsed.jid
                        )
                    }
                }
                
                let newCount = current + incomingCount
                var list = accountInstances
                list[i] = inst.with(newMessageCount: newCount)
                accountInstances = list
                sessionChatUnreadDelta = delta
                if optimisticServerUnread != serverUnreadByConversation {
                    serverUnreadByConversation = optimisticServerUnread
                }
                if snapshots != liveChatSnapshots {
                    liveChatSnapshots = snapshots
                    liveChatSnapshotVersion += 1
                }
                objectWillChange.send()
                let total = totalUnreadCount
                debugLog("[SyncWS] applySyncWSMessage new_message instance_id=\(instanceId) incoming=\(incomingCount) totalUnread=\(total)")
                if incomingCount > 0 {
                    debugLog("[LockNotify] will notify incoming=\(incomingCount) totalUnread=\(total) appState=\(UIApplication.shared.applicationState.rawValue) activeKey=\(activeChatConversationKey ?? "nil")")
                    updateAppBadgeAndNotify(totalUnread: total, count: incomingCount, bannerData: firstBannerData)
                } else {
                    DispatchQueue.main.async {
                        UIApplication.shared.applicationIconBadgeNumber = total
                    }
                }
                Task { await self.mergeWSPayloadIntoChatCache(instanceIdForApi: inst.instanceIdForApi, rawMessages: messages) }
                if !affectedJIDs.isEmpty {
                    let instanceIdForApi = inst.instanceIdForApi
                    let jids = Array(affectedJIDs)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .syncWSMessagesDidArrive,
                            object: nil,
                            userInfo: [
                                "instance_id": instanceIdForApi,
                                "jids": jids
                            ]
                        )
                    }
                }
            }
        }
        sortAccountInstances()
        Task { await AppCacheStore.shared.saveInstances(selectedBoxIPs: self.accountSelectedBoxIPs, instances: self.accountInstances) }
    }
    
    private struct ParsedIncomingMessage {
        let jid: String
        let displayName: String
        let avatarBase64: String?
        let preview: String
        let timestamp: Int64
        let isOutgoing: Bool
        let isGroup: Bool
    }
    
    private func parseIncomingMessage(_ raw: [String: Any], fallbackPhone: String?) -> ParsedIncomingMessage? {
        let chat = raw["chat"] as? [String: Any]
        let jid = stringValue(raw["jid"])
            ?? stringValue(chat?["JID"])
            ?? stringValue(chat?["jid"])
            ?? stringValue(raw["from"])
            ?? ((raw["key"] as? [String: Any]).flatMap { stringValue($0["remoteJid"]) })
        guard let resolvedJid = jid, !resolvedJid.isEmpty else { return nil }
        let isGroup = resolvedJid.hasSuffix("@g.us")
        
        let remarkNameRaw = stringValue(chat?["remark_name"])
            ?? stringValue(chat?["remark"])
            ?? stringValue(chat?["RemarkName"])
            ?? stringValue(chat?["Remark"])
            ?? stringValue(raw["remark_name"])
            ?? stringValue(raw["remark"])
        let contactDisplayNameRaw = stringValue(chat?["display_name"])
            ?? stringValue(chat?["DisplayName"])
            ?? stringValue(chat?["Name"])
        let groupDisplayNameRaw = stringValue(chat?["group_name"])
            ?? stringValue(chat?["GroupName"])
            ?? stringValue(chat?["subject"])
            ?? stringValue(chat?["Subject"])
            ?? stringValue(raw["group_name"])
            ?? stringValue(raw["GroupName"])
            ?? stringValue(raw["subject"])
            ?? stringValue(raw["Subject"])
        let displayNameRaw = contactDisplayNameRaw ?? groupDisplayNameRaw
        let phone = stringValue(chat?["phone"])
            ?? stringValue(chat?["Phone"])
            ?? stringValue(raw["phone"])
            ?? fallbackPhone
        let displayName = {
            if let remark = remarkNameRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
            if let n = displayNameRaw, !n.isEmpty { return n }
            if isGroup { return "群聊" }
            return maskPhoneOrJid(phone) ?? maskPhoneOrJid(resolvedJid) ?? "新消息"
        }()
        let avatarRaw = stringValue(chat?["avatar"]) ?? stringValue(chat?["Avatar"]) ?? stringValue(raw["avatar"])
        let avatar = avatarRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAvatar = (avatar?.isEmpty == false) ? avatar : nil
        let messageType = intValue(raw["message_type"])
        let text = stringValue(raw["text_data"]) ?? stringValue(raw["data"]) ?? ""
        let preview = messagePreview(messageType: messageType, text: text)
        let timestamp = int64Value(raw["timestamp"]) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let isOutgoing = boolFromIntLike(raw["from_me"]) || boolFromIntLike(raw["key_from_me"])
        return ParsedIncomingMessage(
            jid: resolvedJid,
            displayName: displayName,
            avatarBase64: normalizedAvatar,
            preview: preview,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isGroup: isGroup
        )
    }
    
    private func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    
    private func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }
    
    private func int64Value(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let d = value as? Double { return Int64(d) }
        if let s = value as? String, let i = Int64(s) { return i }
        return nil
    }
    
    private func boolFromIntLike(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let d = value as? Double { return Int(d) != 0 }
        if let s = value as? String, let i = Int(s) { return i != 0 }
        return false
    }
    
    private func messagePreview(messageType: Int?, text: String) -> String {
        switch messageType ?? 0 {
        case 0: return text
        case 1: return "[图片]" + text
        case 2: return "[语音]"
        case 3, 13: return "[视频]"
        case 9: return "[文件]"
        case 90: return "[通话]"
        default: return text.isEmpty ? "[消息]" : text
        }
    }
    
    private func maskPhoneOrJid(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        var phone = value
        var suffix = ""
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            phone = String(parts[0])
            suffix = "@" + (parts.count > 1 ? String(parts[1]) : "")
        }
        if phone.count <= 4 { return phone + suffix }
        let start = (phone.count - 4) / 2
        let end = start + 4
        let idxStart = phone.index(phone.startIndex, offsetBy: start)
        let idxEnd = phone.index(phone.startIndex, offsetBy: end)
        return String(phone[..<idxStart]) + "****" + String(phone[idxEnd...]) + suffix
    }
    
    private func preferredNotificationDisplayName(incoming: String, previous: String?) -> String {
        let newName = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty else { return newName.isEmpty ? "新消息" : newName }
        // 当新值退化成手机号/JID/脱敏串时，优先保留历史展示名（通常是备注名）。
        if isFallbackLikeName(newName), !isFallbackLikeName(oldName) {
            return oldName
        }
        return newName.isEmpty ? oldName : newName
    }

    private func notificationTitle(displayName: String, isGroup: Bool) -> String {
        guard isGroup else { return displayName }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = isFallbackLikeName(name) ? "群聊" : name
        return "【群组】\(normalized.isEmpty ? "群聊" : normalized)"
    }
    
    private func isFallbackLikeName(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return true }
        if clean.contains("@") || clean.contains("****") { return true }
        let digitsOnly = clean.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: " ", with: "")
        if digitsOnly.range(of: #"^\d{7,}$"#, options: .regularExpression) != nil { return true }
        return false
    }
    
    private func showInAppBannerIfNeeded(_ bannerData: InAppMessageBannerData?) {
        // 需求调整：移除 App 内自定义新消息弹窗，仅保留系统通知，避免重复提示和遮挡。
        _ = bannerData
        inAppBannerDismissWorkItem?.cancel()
        inAppBannerDismissWorkItem = nil
        inAppMessageBanner = nil
    }
    
    private func updateAppBadgeAndNotify(totalUnread: Int, count: Int, bannerData: InAppMessageBannerData?) {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalUnread
        }
        showInAppBannerIfNeeded(bannerData)
        NewMessageNotificationHelper.notify(count: count, bannerData: bannerData)
    }
    
    func dismissInAppMessageBanner() {
        inAppBannerDismissWorkItem?.cancel()
        inAppBannerDismissWorkItem = nil
        inAppMessageBanner = nil
    }
    
    func openChatFromBanner(_ banner: InAppMessageBannerData) {
        dismissInAppMessageBanner()
        selectedTab = .chat
        currentContainer = nil
        pendingOpenChatRequest = PendingOpenChatRequest(
            instanceIdForApi: banner.instanceIdForApi,
            jid: banner.jid,
            displayName: banner.displayName
        )
    }

    func presentUserFeedback(_ message: String, level: AppUserFeedback.Level = .info, duration: Double = 1.8) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let safeDuration = max(0.8, min(4.0, duration))
        userFeedbackDismissWorkItem?.cancel()
        userFeedbackDismissWorkItem = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            userFeedback = AppUserFeedback(message: clean, level: level)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                self.userFeedback = nil
            }
        }
        userFeedbackDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + safeDuration, execute: work)
    }
    
    func dismissUserFeedback() {
        userFeedbackDismissWorkItem?.cancel()
        userFeedbackDismissWorkItem = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            userFeedback = nil
        }
    }

    func requestJumpToAccountInstance(instanceKey: String) {
        let clean = instanceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        accountJumpToInstanceKey = clean
        accountJumpRequestToken &+= 1
        selectedTab = .account
    }
    
    private func playActiveChatIncomingHintIfNeeded() {
        guard isInChatDetail else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date().timeIntervalSince1970
        if now - lastActiveChatIncomingSoundAt < 0.35 { return }
        lastActiveChatIncomingSoundAt = now
        // 1007: iOS 常用短促提示音，接近 IM 新消息提示体验
        AudioServicesPlaySystemSound(1007)
    }
    
    /// 进入会话时清理未读：同时结算基础未读与 WS 增量，保证红点即时消失。
    func markConversationRead(instanceIdForApi: String, jid: String, baseUnreadHint: Int) {
        guard !instanceIdForApi.isEmpty, !jid.isEmpty else { return }
        let key = "\(instanceIdForApi)_\(jid)"
        let effectiveConversationUnread = conversationUnreadCount(instanceIdForApi: instanceIdForApi, jid: jid, baseUnreadHint: baseUnreadHint)
        let prevConsumed = consumedBaseUnreadByConversation[key] ?? 0
        let deltaUnread = max(0, sessionChatUnreadDelta[key] ?? 0)
        
        serverUnreadByConversation[key] = 0
        if baseUnreadHint > 0 {
            consumedBaseUnreadByConversation[key] = max(prevConsumed, baseUnreadHint)
        }
        
        if deltaUnread > 0 {
            sessionChatUnreadDelta[key] = 0
        }
        
        let totalToSubtract = max(0, effectiveConversationUnread)
        guard totalToSubtract > 0 else { return }
        
        if let idx = accountInstances.firstIndex(where: { inst in
            inst.instanceIdForApi == instanceIdForApi
                || inst.syncMatchKeys.contains(instanceIdForApi)
                || "\(inst.ID ?? 0)" == instanceIdForApi
        }) {
            let inst = accountInstances[idx]
            let current = inst.newMessageCount ?? 0
            var list = accountInstances
            list[idx] = inst.with(newMessageCount: max(0, current - totalToSubtract))
            accountInstances = list
        }
        sortAccountInstances()
        UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount
        objectWillChange.send()
        Task { await AppCacheStore.shared.saveInstances(selectedBoxIPs: self.accountSelectedBoxIPs, instances: self.accountInstances) }
    }
    
    /// APNS 点击打开时先更新会话预览，避免红点先到但最新预览延迟数秒。
    func applyAPNSPreviewHint(instanceIdForApi: String, jid: String, displayName: String?, preview: String?) {
        guard !instanceIdForApi.isEmpty, !jid.isEmpty else { return }
        let key = "\(instanceIdForApi)_\(jid)"
        let old = liveChatSnapshots[key]
        let cleanPreview = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        liveChatSnapshots[key] = LiveChatSnapshot(
            displayName: (displayName?.isEmpty == false ? displayName! : (old?.displayName ?? "新消息")),
            avatarBase64: old?.avatarBase64,
            preview: cleanPreview.isEmpty ? (old?.preview ?? "新消息") : cleanPreview,
            timestamp: max(now, old?.timestamp ?? 0)
        )
        liveChatSnapshotVersion += 1
    }
    
    /// APNS 到达/点击后的未读兜底：先本地+1，随后由服务端 unread_count 校正。
    /// 目的：避免「打开 App 后短时间没有红点」的竞态窗口。
    func applyAPNSUnreadHint(instanceIdForApi: String, jid: String, delta: Int = 1) {
        guard !instanceIdForApi.isEmpty, !jid.isEmpty else { return }
        let inc = max(1, delta)
        let key = "\(instanceIdForApi)_\(jid)"
        
        // 会话级先兜底
        serverUnreadByConversation[key] = max(serverUnreadByConversation[key] ?? 0, inc)
        
        // 实例级同步兜底，驱动底部 Tab 红点即时出现
        if let idx = accountInstances.firstIndex(where: { inst in
            inst.instanceIdForApi == instanceIdForApi
                || inst.syncMatchKeys.contains(instanceIdForApi)
                || "\(inst.ID ?? 0)" == instanceIdForApi
        }) {
            let current = accountInstances[idx].newMessageCount ?? 0
            var list = accountInstances
            list[idx] = accountInstances[idx].with(newMessageCount: current + inc)
            accountInstances = list
            sortAccountInstances()
            UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount
            Task { await AppCacheStore.shared.saveInstances(selectedBoxIPs: self.accountSelectedBoxIPs, instances: self.accountInstances) }
        }
    }
    
    /// 与 H5 一致：进入会话后在本地先清未读，再同步 clear_unread 到服务端。
    func syncConversationReadToServer(instanceIdForApi: String, jid: String, boxIP: String?) async {
        guard !instanceIdForApi.isEmpty, !jid.isEmpty else { return }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await ChatService.shared.clearChatUnreadCount(instanceId: instanceIdForApi, jid: jid, boxIP: boxIP)
                // 成功后再拉一次服务端快照，闭环校准容器/Tab/角标。
                await refreshUnreadCountsFromServerIfNeeded()
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    let delayNs = UInt64(200_000_000 * (attempt + 1))
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }
        }
        if let lastError {
            debugLog("[Unread] clear_unread failed instance=\(instanceIdForApi) jid=\(jid) err=\(lastError.localizedDescription)")
        }
        // 失败也回补一次，避免本地长期漂移。
        await refreshUnreadCountsFromServerIfNeeded()
    }
    
    private func mergeWSPayloadIntoChatCache(instanceIdForApi: String, rawMessages: [[String: Any]]) async {
        guard !instanceIdForApi.isEmpty, !rawMessages.isEmpty else { return }
        let existing = await AppCacheStore.shared.loadChats(instanceId: instanceIdForApi, maxAge: nil) ?? []
        var list = existing
        var byJid: [String: Int] = [:]
        var appliedIncomingByConversation: [String: Int] = [:]
        for (i, c) in list.enumerated() {
            if let jid = c.jid, !jid.isEmpty { byJid[jid] = i }
        }
        
        for raw in rawMessages {
            guard let parsed = parseIncomingMessage(raw, fallbackPhone: nil) else { continue }
            let jid = parsed.jid
            let msgType = intValue(raw["message_type"]) ?? 0
            let last = LastMessage(message_type: msgType, text_data: parsed.preview, timestamp: parsed.timestamp)
            let inc = parsed.isOutgoing ? 0 : 1
            if inc > 0 {
                let conversationKey = "\(instanceIdForApi)_\(jid)"
                appliedIncomingByConversation[conversationKey] = (appliedIncomingByConversation[conversationKey] ?? 0) + inc
            }
            
            if let idx = byJid[jid] {
                var chat = list[idx]
                chat.last_message = last
                chat.display_name = parsed.displayName
                if let avatar = parsed.avatarBase64, !avatar.isEmpty { chat.avatar = avatar }
                chat.newMessageCount = (chat.newMessageCount ?? 0) + inc
                list[idx] = chat
            } else {
                let chat = Chat(
                    chat_row_id: nil,
                    jid: jid,
                    display_name: parsed.displayName,
                    phone: nil,
                    avatar: parsed.avatarBase64,
                    newMessageCount: inc,
                    last_message: last
                )
                byJid[jid] = list.count
                list.append(chat)
            }
        }
        await AppCacheStore.shared.saveChats(instanceId: instanceIdForApi, chats: list)
        // WS 增量在会话缓存落盘后，回冲同批 delta，避免「缓存未读 + delta 未读」双计。
        if !appliedIncomingByConversation.isEmpty {
            await MainActor.run {
                var nextDelta = sessionChatUnreadDelta
                for (key, applied) in appliedIncomingByConversation {
                    let current = max(0, nextDelta[key] ?? 0)
                    let reduced = max(0, current - applied)
                    if reduced == 0 {
                        nextDelta.removeValue(forKey: key)
                    } else {
                        nextDelta[key] = reduced
                    }
                }
                sessionChatUnreadDelta = nextDelta
            }
        }
    }

    private func restoreCachedStartupData() async {
        guard isLoggedIn else { return }
        if let cachedBoxes = await AppCacheStore.shared.loadBoxes(maxAge: 6 * 3600) {
            await MainActor.run { self.accountBoxes = cachedBoxes }
        }
        guard !accountSelectedBoxIPs.isEmpty else { return }
        // IM 体验：启动优先展示本地实例缓存，不做 30 秒硬过期
        if let cachedInstances = await AppCacheStore.shared.loadInstances(selectedBoxIPs: accountSelectedBoxIPs, maxAge: nil) {
            await MainActor.run {
                self.accountInstances = cachedInstances
                self.sortAccountInstances()
            }
        }
        // 启动兜底：恢复缓存后立刻校正 unread_count，保证打开 App 红点稳定可见
        await refreshUnreadCountsFromServerIfNeeded()
    }
}

// MARK: - 聊天审核前台通知（与新消息一致：本地通知 + 前台横幅）
private enum ChatReviewNotificationHelper {
    private static var lastCreatedAt: TimeInterval = 0
    private static var lastUpdatedAt: TimeInterval = 0
    
    /// 仅当真正「需要审核」时弹前台通知：`pending_review` 或 `client_hint.kind == chat_review_pending`（正常发送的 waiting/running/success 等一律不弹，避免误导）
    private static func isPendingReviewTask(_ msg: SyncWSMessage) -> Bool {
        let kind = (msg.auditClientHint?.kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "chat_review_pending" { return true }
        let st = (msg.auditTaskDataStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return st == "pending_review"
    }
    
    static func notifyIfNeeded(for msg: SyncWSMessage) {
        guard msg.type == "scrm_task_created" || msg.type == "scrm_task_updated" else { return }
        let now = Date().timeIntervalSince1970
        if msg.type == "scrm_task_created" {
            if now - lastCreatedAt < 0.28 { return }
            lastCreatedAt = now
        } else {
            if now - lastUpdatedAt < 1.6 { return }
            lastUpdatedAt = now
        }
        guard isPendingReviewTask(msg) else { return }
        let hint = msg.auditClientHint
        let (title, subtitle, body) = buildCopy(for: msg, hint: hint)
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "chat-review"
        var info: [String: Any] = [
            "event_type": "chat_review",
            "task_type": msg.type ?? "",
            "task_status": msg.auditTaskDataStatus ?? ""
        ]
        if let tid = hint?.taskId, !tid.isEmpty { info["task_id"] = tid }
        let inst = (hint?.instanceId ?? msg.instanceId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inst, !inst.isEmpty { info["instance_id"] = inst }
        content.userInfo = info
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.08, repeats: false)
        let id = "chat-review-\(Int(now * 1000))-\(msg.type ?? "")"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard ok else {
                debugLog("[ChatReviewNotify] skip: notification not authorized")
                return
            }
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    debugLog("[ChatReviewNotify] add failed: \(error.localizedDescription)")
                } else {
                    debugLog("[ChatReviewNotify] add ok id=\(id) title=\(title)")
                }
            }
        }
    }
    
    private static func buildCopy(for msg: SyncWSMessage, hint: AuditWSClientHint?) -> (String, String, String) {
        let subtitle = "消息审核"
        if msg.type == "scrm_task_created" {
            let t = (hint?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let b = (hint?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                t.isEmpty ? "待审核发送任务" : t,
                subtitle,
                b.isEmpty ? "请前往「我的 → 消息审核」处理" : b
            )
        }
        let st = (msg.auditTaskDataStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = (hint?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (hint?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !b.isEmpty { return (t, subtitle, b) }
        if !t.isEmpty { return (t, subtitle, b.isEmpty ? statusFallbackBody(st) : b) }
        if !b.isEmpty { return (statusFallbackTitle(st), subtitle, b) }
        return (statusFallbackTitle(st), subtitle, statusFallbackBody(st))
    }
    
    private static func statusFallbackTitle(_ status: String) -> String {
        switch status {
        case "pending_review": return "待审核发送任务"
        case "waiting": return "审核已通过"
        case "rejected": return "审核已拒绝"
        case "running": return "任务执行中"
        case "success": return "发送成功"
        default: return "审核任务更新"
        }
    }
    
    private static func statusFallbackBody(_ status: String) -> String {
        switch status {
        case "pending_review": return "请前往「我的 → 消息审核」处理"
        case "waiting": return "任务将排队发送"
        case "rejected": return "该任务已被拒绝"
        case "running": return "消息正在发送"
        case "success": return "消息已成功送达"
        default: return "可在「我的 → 消息审核」查看记录"
        }
    }
}

// MARK: - 新消息本地通知（与 H5 sendNotification 一致，2 秒防抖；前台也显示横幅）
private enum NewMessageNotificationHelper {
    private static var lastNotificationTime: TimeInterval = 0
    private static let debounceInterval: TimeInterval = 2
    
    private static func currentApplicationState() -> UIApplication.State {
        if Thread.isMainThread {
            return UIApplication.shared.applicationState
        }
        var state: UIApplication.State = .inactive
        DispatchQueue.main.sync {
            state = UIApplication.shared.applicationState
        }
        return state
    }
    
    static func notify(count: Int, bannerData: InAppMessageBannerData?) {
        let appState = currentApplicationState()
        debugLog("[LockNotify] notify enter count=\(count) appState=\(appState.rawValue) hasBanner=\(bannerData != nil)")
        let now = Date().timeIntervalSince1970
        if now - lastNotificationTime < debounceInterval {
            debugLog("[LockNotify] notify skip: debounce")
            return
        }
        lastNotificationTime = now
        
        let content = UNMutableNotificationContent()
        if let banner = bannerData {
            content.title = banner.notificationTitle
            content.subtitle = count > 1 ? "等\(count)条新消息" : "新消息"
            content.body = banner.preview
            content.userInfo = [
                "instance_id_for_api": banner.instanceIdForApi,
                "jid": banner.jid,
                "display_name": banner.displayName
            ]
        } else {
            content.title = "你有\(count)条新消息"
            content.body = ""
        }
        content.sound = .default
        content.categoryIdentifier = "new-message"

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            debugLog("[LockNotify] settings auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) badge=\(settings.badgeSetting.rawValue) lockScreen=\(settings.lockScreenSetting.rawValue) notificationCenter=\(settings.notificationCenterSetting.rawValue)")
            // 锁屏/后台阶段适当拉长触发间隔，提升系统展示稳定性。
            let isBackground = currentApplicationState() != .active
            let trigger: UNNotificationTrigger? = UNTimeIntervalNotificationTrigger(
                timeInterval: isBackground ? 1.0 : 0.1,
                repeats: false
            )
            let request = UNNotificationRequest(identifier: "new-message-\(now)", content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    debugLog("[LockNotify] notify add failed: \(error.localizedDescription)")
                } else {
                    debugLog("[LockNotify] notify add ok id=\(request.identifier) trigger=\(isBackground ? "1.0s" : "0.1s")")
                }
            }
        }
    }
}

/// 前台也显示新消息横幅（默认仅后台才显示）
final class NewMessageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NewMessageNotificationDelegate()
    weak var appState: AppState?
    private var pendingRoute: (instanceIdForApi: String, jid: String, displayName: String?)?
    
    func bind(appState: AppState) {
        self.appState = appState
        if let route = pendingRoute {
            openChatRoute(route, appState: appState)
            pendingRoute = nil
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        let instanceIdForApi = (info["instance_id_for_api"] as? String) ?? (info["instance_id"] as? String) ?? ""
        if instanceIdForApi.isEmpty { return }
        
        // 兼容后端仅下发 instance_id 的 APNS：先打开到「全部对话」页
        guard let jid = info["jid"] as? String, !jid.isEmpty else {
            if let appState {
                DispatchQueue.main.async {
                    appState.selectedTab = .chat
                    appState.currentContainer = nil
                }
            }
            return
        }
        let displayName = info["display_name"] as? String
        let preview = response.notification.request.content.body
        let route = (instanceIdForApi: instanceIdForApi, jid: jid, displayName: displayName)
        if let appState {
            appState.applyAPNSUnreadHint(instanceIdForApi: instanceIdForApi, jid: jid, delta: 1)
            appState.applyAPNSPreviewHint(instanceIdForApi: instanceIdForApi, jid: jid, displayName: displayName, preview: preview)
            openChatRoute(route, appState: appState)
            Task { await appState.refreshUnreadCountsFromServerIfNeeded() }
        } else {
            pendingRoute = route
        }
    }
    
    private func openChatRoute(_ route: (instanceIdForApi: String, jid: String, displayName: String?), appState: AppState) {
        DispatchQueue.main.async {
            appState.selectedTab = .chat
            appState.currentContainer = nil
            appState.pendingOpenChatRequest = PendingOpenChatRequest(
                instanceIdForApi: route.instanceIdForApi,
                jid: route.jid,
                displayName: route.displayName
            )
        }
    }
}

/// APNS 注册与 device token 上报（按 REDEME 对接文档）
final class APNSPushManager {
    static let shared = APNSPushManager()
    private init() {}
    
    private let tokenStoreKey = "apns_device_token"
    private var lastUploadSignature: String?
    private var lastUploadAt: Date?
    private var lastUnregisterSignature: String?
    private var lastUnregisterAt: Date?
    
    /// 仅登录时激活 APNS（按需求：不在每次打开 App 时注册）
    func activateForLogin() {
        setupPush()
        uploadTokenIfPossible()
    }
    
    /// 退出登录时注销设备 token 绑定并取消远程通知注册
    func deactivateOnLogout(jwt: String?) {
        unregisterTokenIfPossible(jwt: jwt)
        DispatchQueue.main.async {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }
    
    func setupPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                debugLog("[APNS] requestAuthorization error: \(error.localizedDescription)")
            }
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
    
    func registerForRemoteNotifications() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: tokenStoreKey)
        debugLog("[APNS] didRegister token prefix=\(token.prefix(16))...")
        uploadTokenIfPossible()
        // 若 SyncWS 在 APNS token 到达前已连接，这里主动重连一次，确保 ws URL 携带 device_token。
        if let jwt = APIClient.shared.token, !jwt.isEmpty {
            DispatchQueue.main.async {
                SyncWebSocketService.shared.beginForegroundReconnectGrace(seconds: 0)
                SyncWebSocketService.shared.connect(token: jwt)
            }
        }
    }
    
    func uploadTokenIfPossible() {
        guard let deviceToken = UserDefaults.standard.string(forKey: tokenStoreKey), !deviceToken.isEmpty else { return }
        guard let jwt = APIClient.shared.token, !jwt.isEmpty else { return }
        let uid = APIClient.shared.userID ?? ""
        let signature = "\(uid)|\(deviceToken)"
        if lastUploadSignature == signature, let at = lastUploadAt, Date().timeIntervalSince(at) < 120 {
            return
        }
        lastUploadSignature = signature
        lastUploadAt = Date()
        
        Task {
            let base = APIConfig.host
            guard let url = URL(string: "\(base)/api/v1/device/register_token") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(jwt, forHTTPHeaderField: "x-token")
            let body: [String: Any] = [
                "device_token": deviceToken,
                "platform": "ios",
                "bundle_id": Bundle.main.bundleIdentifier ?? "com.wudidechat"
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                    debugLog("[APNS] register_token http=\(http.statusCode)")
                    return
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let code = obj["code"] as? Int ?? -1
                    let msg = obj["msg"] as? String ?? ""
                    debugLog("[APNS] register_token code=\(code) msg=\(msg)")
                }
            } catch {
                debugLog("[APNS] register_token error: \(error.localizedDescription)")
            }
        }
    }
    
    private func unregisterTokenIfPossible(jwt: String?) {
        guard let deviceToken = UserDefaults.standard.string(forKey: tokenStoreKey), !deviceToken.isEmpty else { return }
        guard let jwt, !jwt.isEmpty else { return }
        let signature = "\(jwt.prefix(24))|\(deviceToken)"
        if lastUnregisterSignature == signature, let at = lastUnregisterAt, Date().timeIntervalSince(at) < 30 {
            return
        }
        lastUnregisterSignature = signature
        lastUnregisterAt = Date()
        
        Task {
            let base = APIConfig.host
            guard let url = URL(string: "\(base)/api/v2/device/unregister_token") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(jwt, forHTTPHeaderField: "x-token")
            let body: [String: Any] = [
                "device_token": deviceToken
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                    debugLog("[APNS] unregister_token http=\(http.statusCode)")
                    return
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let code = obj["code"] as? Int ?? -1
                    let msg = obj["msg"] as? String ?? ""
                    debugLog("[APNS] unregister_token code=\(code) msg=\(msg)")
                }
            } catch {
                debugLog("[APNS] unregister_token error: \(error.localizedDescription)")
            }
        }
    }
}
