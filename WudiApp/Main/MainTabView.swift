//
//  MainTabView.swift
//  WudiApp
//
//  参考 H5 MainLayout.vue：主框架 = 内容区 + 底部 TabBar，背景 #f5f5f5
//

import SwiftUI
import UserNotifications
#if canImport(OUICore)
import OUICore
#endif

#if DEBUG
private let debugLogEnabled = false
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {
    guard debugLogEnabled else { return }
    print(message())
}
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
#endif

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appState: AppState
    @ObservedObject private var syncWS = SyncWebSocketService.shared
    @State private var showAuthInvalidAlert = false
    @State private var lastChatTabReselectAt: TimeInterval = 0
    
    private var selectedTabBinding: Binding<TabItem> {
        Binding(
            get: { appState.selectedTab },
            set: { appState.selectedTab = $0 }
        )
    }
    
    private let tabs: [TabItem] = [.account, .chat, .collab, .tools, .my]
    
    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.96, green: 0.96, blue: 0.96)
                .ignoresSafeArea()
            
            // 主内容区：四个 Tab 常驻不销毁，切换时仅显隐，实现会话页等状态持久化（与账号页一致）
            ZStack {
                AccountPlaceholderView(appState: appState)
                    .opacity(appState.selectedTab == .account ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .account)
                ChatListPlaceholderView(appState: appState)
                    .opacity(appState.selectedTab == .chat ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .chat)
                CollaborationPlaceholderView(appState: appState)
                    .opacity(appState.selectedTab == .collab ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .collab)
                ToolsPlaceholderView(appState: appState)
                    .opacity(appState.selectedTab == .tools ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .tools)
                MyView(appState: appState)
                    .opacity(appState.selectedTab == .my ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .my)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let feedback = appState.userFeedback {
                HStack(spacing: 8) {
                    Image(systemName: feedbackIcon(for: feedback.level))
                        .font(.system(size: 14, weight: .semibold))
                    Text(feedback.message)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(feedbackBackground(for: feedback.level))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
                .padding(.top, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .top)
                .onTapGesture { appState.dismissUserFeedback() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1200)
            }
            
            // 网络/连接问题：中置聚焦弹层 + 全屏虚化背景（替代顶部横条）
            if syncWS.userNoticeState != .none {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 12) {
                        if syncWS.userNoticeState == .connecting {
                            ProgressView()
                                .scaleEffect(1.0)
                                .tint(Color(white: 0.3))
                            Text("正在连接网络…")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(white: 0.18))
                            Text("请稍候，系统正在尝试恢复连接")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.35))
                        } else {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(Color(red: 0.82, green: 0.25, blue: 0.22))
                            Text("网络连接异常")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(white: 0.15))
                            Text("当前网络不可用或连接中断，请检查网络后重试。")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.35))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Button(action: { syncWS.retryNow() }) {
                                Text("重试连接")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Color(red: 0.07, green: 0.52, blue: 0.36))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 292)
                    .background(Color.white.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(999)
            }
            
            // 底部 TabBar 常驻：通过透明度切换可见性，避免返回聊天列表时重建导致卡顿
            VStack {
                Spacer()
                BottomTabBar(
                    selectedTab: selectedTabBinding,
                    tabs: tabs,
                    unreadCount: appState.totalUnreadCount
                ) { tab, wasSelected in
                    guard tab == .chat, wasSelected else { return }
                    let now = Date().timeIntervalSince1970
                    if now - lastChatTabReselectAt <= 0.35 {
                        appState.chatTabScrollToTopToken &+= 1
                    }
                    lastChatTabReselectAt = now
                }
            }
            .opacity(appState.isInChatDetail ? 0 : 1)
            .offset(y: appState.isInChatDetail ? 18 : 0)
            .scaleEffect(appState.isInChatDetail ? 0.985 : 1)
            .allowsHitTesting(!appState.isInChatDetail)
            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.14), value: appState.isInChatDetail)
            
            if showAuthInvalidAlert {
                // 微信风格中置弹窗：半透明遮罩 + 白色圆角卡片 + 底部操作按钮
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                            Text("登录已失效")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Color(white: 0.12))
                            Text("登录状态已失效或账号在其他设备登录，请重新登录。")
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.35))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 20)
                        .padding(.bottom, 18)
                        
                        Rectangle()
                            .fill(Color(white: 0.9))
                            .frame(height: 0.5)
                        
                        HStack(spacing: 0) {
                            Button(action: { showAuthInvalidAlert = false }) {
                                Text("取消")
                                    .font(.system(size: 16))
                                    .foregroundColor(Color(white: 0.35))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.plain)
                            
                            Rectangle()
                                .fill(Color(white: 0.9))
                                .frame(width: 0.5, height: 48)
                            
                            Button(action: {
                                showAuthInvalidAlert = false
                                appState.logout()
                            }) {
                                Text("重新登录")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(red: 0.07, green: 0.52, blue: 0.36))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 300)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            
            // 悬浮退出按钮常驻：进入聊天详情时仅隐藏，避免频繁销毁/创建
            GeometryReader { geo in
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        FloatLogoutButton(appState: appState, containerSize: geo.size, safeAreaBottom: safeAreaBottom)
                            .padding(.trailing, 16)
                            .padding(.bottom, 80 + safeAreaBottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(appState.isInChatDetail ? 0 : 1)
            .offset(y: appState.isInChatDetail ? 20 : 0)
            .allowsHitTesting(!appState.isInChatDetail)
            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.14), value: appState.isInChatDetail)
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeInOut(duration: 0.2), value: syncWS.userNoticeState)
        .onChange(of: syncWS.connectionStatus) { status in
            debugLog("[SyncWS][UI] connectionStatus -> \(status)")
        }
        .onChange(of: syncWS.userNoticeState) { state in
            debugLog("[SyncWS][UI] userNoticeState -> \(state)")
        }
        .onAppear {
            guard appState.isLoggedIn, let token = APIClient.shared.token, !token.isEmpty else {
                debugLog("[SyncWS] MainTabView onAppear skip: not logged in or no token")
                UIApplication.shared.applicationIconBadgeNumber = 0
                return
            }
            debugLog("[SyncWS] MainTabView onAppear set callbacks and connect")
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            UIApplication.shared.applicationIconBadgeNumber = appState.totalUnreadCount
            let ws = SyncWebSocketService.shared
            ws.onSyncMessage = { [weak appState] msg in
                appState?.applySyncWSMessage(msg)
            }
            ws.onConnected = { [weak appState] in
                // 连接成功后到 MainActor 拉取实例再发订阅；无容器时也会发空列表完成注册（见 AI-REDEME.md）。
                Task { await appState?.refreshAccountInstancesForSyncIfNeeded() }
            }
            ws.onAuthInvalid = {
                DispatchQueue.main.async {
                    showAuthInvalidAlert = true
                }
            }
            debugLog("[SyncWS] MainTabView onAppear connect() begin")
            ws.beginForegroundReconnectGrace(seconds: 3)
            ws.connect(token: token)
            Task { await appState.refreshUnreadCountsFromServerIfNeeded() }
        }
        .onChange(of: scenePhase) { phase in
            debugLog("[LockNotify] MainTabView scenePhase -> \(phase) wsStatus=\(SyncWebSocketService.shared.connectionStatus)")
            guard phase == .active,
                  appState.isLoggedIn,
                  let token = APIClient.shared.token,
                  !token.isEmpty else { return }
            let ws = SyncWebSocketService.shared
            ws.beginForegroundReconnectGrace(seconds: 3)
            if ws.connectionStatus != .connected && ws.connectionStatus != .connecting {
                debugLog("[SyncWS] MainTabView scenePhase=\(phase) connect() begin status=\(ws.connectionStatus)")
                ws.connect(token: token)
            } else {
                debugLog("[SyncWS] MainTabView scenePhase=\(phase) skip connect status=\(ws.connectionStatus)")
            }
            Task { await appState.refreshUnreadCountsFromServerIfNeeded() }
        }
        .onChange(of: appState.selectedTab) { tab in
            guard tab == .my else { return }
            Task { await appState.refreshChatReviewPendingCount() }
        }
    }
    
    private var safeAreaBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .flatMap { $0.windows.first?.safeAreaInsets.bottom } ?? 0
    }
    
    private func feedbackIcon(for level: AppUserFeedback.Level) -> String {
        switch level {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    private func feedbackBackground(for level: AppUserFeedback.Level) -> Color {
        switch level {
        case .success:
            return Color(red: 0.10, green: 0.56, blue: 0.32).opacity(0.96)
        case .error:
            return Color(red: 0.80, green: 0.22, blue: 0.20).opacity(0.96)
        case .info:
            return Color.black.opacity(0.82)
        }
    }
    
}

enum TabItem: String, CaseIterable {
    case account = "账号"
    case chat = "对话"
    case collab = "协作"
    case tools = "工具"
    case my = "我的"
    
    var iconName: String {
        switch self {
        case .account: return "person.crop.rectangle"
        case .chat: return "bubble.left.and.bubble.right"
        case .collab: return "person.2"
        case .tools: return "wrench.and.screwdriver"
        case .my: return "person"
        }
    }
}

private struct CollaborationPlaceholderView: View {
    @ObservedObject var appState: AppState
    @State private var conversations: [CollabConversation] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var didAutoLoad = false
    @State private var selectedFilter: CollabConversationFilter = .all
    
    var body: some View {
        NavigationStack {
            Group {
                if !appState.imEnabled {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(Color(white: 0.62))
                        Text("IM 尚未开通，请联系管理员")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(white: 0.22))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                } else if !appState.isIMReady {
                    VStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 36))
                            .foregroundColor(Color(white: 0.62))
                        Text(appState.isIMTokenExpired ? "IM Token 已过期，请重新登录" : "IM 登录信息不完整，请重新登录")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(white: 0.30))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                } else if loading && conversations.isEmpty {
                    ProgressView("加载会话中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                } else {
                    VStack(spacing: 0) {
                        Picker("分类", selection: $selectedFilter) {
                            ForEach(CollabConversationFilter.allCases, id: \.self) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        
                        List {
                            if let loadError, !loadError.isEmpty {
                                Text("同步失败：\(loadError)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            if filteredConversations.isEmpty {
                                Text("暂无会话")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(white: 0.45))
                            } else {
                                ForEach(filteredConversations) { item in
                                    NavigationLink(value: item) {
                                        CollabConversationRow(item: item)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                    }
                    .refreshable { await loadConversations(forceRelogin: false) }
                }
            }
            .navigationTitle("内部协作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        avatarView
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(white: 0.2))
                    }
                }
            }
            .navigationDestination(for: CollabConversation.self) { item in
                CollabChatDetailView(appState: appState, conversation: item)
            }
            .onAppear {
                guard appState.isIMReady else { return }
                guard !didAutoLoad else { return }
                didAutoLoad = true
                Task { await loadConversations(forceRelogin: true) }
            }
            .onChange(of: appState.imToken) { _ in
                didAutoLoad = false
                conversations = []
            }
        }
    }
    
    private var filteredConversations: [CollabConversation] {
        switch selectedFilter {
        case .all:
            return conversations
        case .group:
            return conversations.filter { $0.isGroup }
        case .focus:
            return conversations.filter { $0.unreadCount > 0 }
        }
    }
    
    private var displayName: String {
        let name = (appState.userNickName.isEmpty ? (appState.userLoginName ?? "") : appState.userNickName)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return name.isEmpty ? "当前用户" : name
    }
    
    @ViewBuilder
    private var avatarView: some View {
        if let urlString = appState.userHeaderImgURL?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !urlString.isEmpty,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color(white: 0.88))
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color(white: 0.86))
                .frame(width: 24, height: 24)
                .overlay(
                    Text(displayName.prefix(1))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.25))
                )
        }
    }
    
    private func loadConversations(forceRelogin: Bool) async {
        guard appState.isIMReady else { return }
        guard let uid = appState.imUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
              let token = appState.imToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            await MainActor.run { loadError = "IM 登录参数不完整" }
            return
        }
        let apiAddr = UserDefaults.standard.string(forKey: "openim_api_addr")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wsAddr = UserDefaults.standard.string(forKey: "openim_ws_addr")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAPI = (apiAddr?.isEmpty == false ? apiAddr! : "http://47.76.110.134:80/api")
        let resolvedWS = (wsAddr?.isEmpty == false ? wsAddr! : "ws://47.76.110.134:80/msg_gateway")
        
        await MainActor.run {
            loading = true
            loadError = nil
        }
        do {
            try await CollabIMService.shared.prepareAndLogin(
                apiAddr: resolvedAPI,
                wsAddr: resolvedWS,
                uid: uid,
                token: token,
                forceRelogin: forceRelogin
            )
            let items = try await CollabIMService.shared.fetchConversations()
            await MainActor.run {
                conversations = items
                loading = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                loading = false
            }
        }
    }
}

private struct CollabConversationRow: View {
    let item: CollabConversation
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(red: 0.90, green: 0.94, blue: 1.0))
                Text(item.title.prefix(1).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(white: 0.12))
                    .lineLimit(1)
                Text(item.preview.isEmpty ? "[暂无消息]" : item.preview)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.45))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.timeText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.55))
                if item.unreadCount > 0 {
                    Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CollabChatDetailView: View {
    @ObservedObject var appState: AppState
    let conversation: CollabConversation
    @State private var messages: [CollabMessage] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var inputText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            HStack {
                                if msg.isMe { Spacer(minLength: 36) }
                                VStack(alignment: msg.isMe ? .trailing : .leading, spacing: 4) {
                                    Text(msg.text)
                                        .font(.system(size: 14))
                                        .foregroundColor(msg.isMe ? .white : Color(white: 0.12))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(msg.isMe ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    Text(msg.timeText)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.55))
                                }
                                if !msg.isMe { Spacer(minLength: 36) }
                            }
                            .id(msg.id)
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                .onChange(of: messages.count) { _ in
                    if let last = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("输入消息", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("发送") {
                    Task { await sendText() }
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
            }
            .padding(10)
            .background(Color(red: 0.94, green: 0.94, blue: 0.95))
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reloadMessages()
        }
    }
    
    private func reloadMessages() async {
        await MainActor.run {
            loading = true
            errorText = nil
        }
        do {
            let list = try await CollabIMService.shared.fetchMessages(conversation: conversation)
            await MainActor.run {
                messages = list
                loading = false
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                loading = false
            }
        }
    }
    
    private func sendText() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await MainActor.run {
            loading = true
            errorText = nil
        }
        do {
            try await CollabIMService.shared.sendText(text, conversation: conversation)
            await MainActor.run { inputText = "" }
            await reloadMessages()
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                loading = false
            }
        }
    }
}

private struct CollabConversation: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let unreadCount: Int
    let timeText: String
    let sourceID: String
    let conversationTypeRaw: Int
    let isGroup: Bool
}

private struct CollabMessage: Identifiable, Hashable {
    let id: String
    let text: String
    let isMe: Bool
    let sendTimestamp: TimeInterval
    let timeText: String
}

private enum CollabConversationFilter: String, CaseIterable {
    case all = "全部对话"
    case group = "群组"
    case focus = "特别关注"
}

private actor CollabIMService {
    static let shared = CollabIMService()
    private var didSetup = false
    private var setupKey = ""
    
    private init() {}
    
    func prepareAndLogin(apiAddr: String, wsAddr: String, uid: String, token: String, forceRelogin: Bool) async throws {
#if canImport(OUICore)
        let cleanUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUID.isEmpty, !cleanToken.isEmpty else {
            throw NSError(domain: "CollabIM", code: -1, userInfo: [NSLocalizedDescriptionKey: "IM 用户信息为空"])
        }
        let key = "\(apiAddr)|\(wsAddr)"
        if !didSetup || setupKey != key || IMController.shared.imManager == nil {
            IMController.shared.setup(sdkAPIAdrr: apiAddr, sdkWSAddr: wsAddr, onKickedOffline: nil, onUserTokenInvalid: nil)
            didSetup = true
            setupKey = key
        }
        let currentUID = IMController.shared.getLoginUserID().trimmingCharacters(in: .whitespacesAndNewlines)
        if !forceRelogin, currentUID == cleanUID {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            IMController.shared.login(uid: cleanUID, token: cleanToken) { _ in
                continuation.resume(returning: ())
            } onFail: { code, msg in
                continuation.resume(throwing: NSError(
                    domain: "CollabIM",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: msg ?? "OpenIM 登录失败(\(code))"]
                ))
            }
        }
#else
        throw NSError(domain: "CollabIM", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenIM SDK 未集成"])
#endif
    }
    
    func fetchConversations() async throws -> [CollabConversation] {
#if canImport(OUICore)
        let list = await IMController.shared.getAllConversations()
        let sorted = list.sorted { $0.latestMsgSendTime > $1.latestMsgSendTime }
        return sorted.compactMap { c in
            let sourceID: String
            if c.conversationType == .superGroup {
                sourceID = (c.groupID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                sourceID = (c.userID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !sourceID.isEmpty else { return nil }
            let title = (c.showName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sourceID : (c.showName ?? sourceID)
            let ts = normalizeTime(c.latestMsgSendTime)
            return CollabConversation(
                id: c.conversationID,
                title: title,
                preview: messagePreview(c.latestMsg),
                unreadCount: max(0, c.unreadCount),
                timeText: formatTime(ts),
                sourceID: sourceID,
                conversationTypeRaw: c.conversationType.rawValue,
                isGroup: c.conversationType != .c2c
            )
        }
#else
        throw NSError(domain: "CollabIM", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenIM SDK 未集成"])
#endif
    }
    
    func fetchMessages(conversation: CollabConversation) async throws -> [CollabMessage] {
#if canImport(OUICore)
        let cType = conversationType(from: conversation.conversationTypeRaw)
        let raw: [MessageInfo] = await withCheckedContinuation { continuation in
            IMController.shared.getHistoryMessageListReverse(
                conversationID: conversation.id,
                conversationType: cType,
                startCliendMsgId: nil,
                count: 80
            ) { _, arr in
                continuation.resume(returning: arr)
            }
        }
        let myUID = IMController.shared.uid
        let mapped = raw.map { msg -> CollabMessage in
            let content = messageText(msg)
            let ts = normalizeTime(msg.sendTime)
            return CollabMessage(
                id: msg.clientMsgID,
                text: content.isEmpty ? "[暂不支持该消息类型]" : content,
                isMe: msg.sendID == myUID,
                sendTimestamp: ts,
                timeText: formatTime(ts)
            )
        }
        return mapped.sorted {
            if $0.sendTimestamp == $1.sendTimestamp { return $0.id < $1.id }
            return $0.sendTimestamp < $1.sendTimestamp
        }
#else
        throw NSError(domain: "CollabIM", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenIM SDK 未集成"])
#endif
    }
    
    func sendText(_ text: String, conversation: CollabConversation) async throws {
#if canImport(OUICore)
        let cType = conversationType(from: conversation.conversationTypeRaw)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            IMController.shared.sendTextMessage(
                text: text,
                quoteMessage: nil,
                to: conversation.sourceID,
                conversationType: cType,
                sending: { _ in },
                onComplete: { msg in
                    if msg.status == .sendFailure {
                        continuation.resume(throwing: NSError(domain: "CollabIM", code: -3, userInfo: [NSLocalizedDescriptionKey: "消息发送失败"]))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
#else
        throw NSError(domain: "CollabIM", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenIM SDK 未集成"])
#endif
    }
    
    private func normalizeTime(_ raw: Int) -> TimeInterval {
        if raw > 1_000_000_000_000 { return TimeInterval(raw) / 1000.0 }
        return TimeInterval(raw)
    }
    
    private func normalizeTime(_ raw: TimeInterval) -> TimeInterval {
        if raw > 1_000_000_000_000 { return raw / 1000.0 }
        return raw
    }
    
    private func formatTime(_ ts: TimeInterval) -> String {
        guard ts > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
    
#if canImport(OUICore)
    private func messagePreview(_ msg: MessageInfo?) -> String {
        guard let msg else { return "" }
        return messageText(msg)
    }
    
    private func messageText(_ msg: MessageInfo) -> String {
        if let text = msg.textElem?.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        switch msg.contentType {
        case .text:
            return msg.content ?? ""
        case .image:
            return "[图片]"
        case .video:
            return "[视频]"
        case .audio:
            return "[语音]"
        case .file:
            return "[文件]"
        default:
            return msg.content ?? ""
        }
    }
    
    private func conversationType(from raw: Int) -> ConversationType {
        ConversationType(rawValue: raw) ?? .c2c
    }
#endif
}

#Preview {
    struct PreviewWrapper: View {
        @StateObject private var state = AppState()
        var body: some View {
            MainTabView(appState: state)
                .onAppear { state.didLogin(token: "preview", userName: "Preview", userID: nil, headerImg: nil) }
        }
    }
    return PreviewWrapper()
}
