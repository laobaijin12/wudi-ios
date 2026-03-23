//
//  ChatListPlaceholderView.swift
//  WudiApp
//
//  与 H5 对话页逻辑一致：
//  - 无 currentContainer 时：显示「全部对话」(ChatPage)，聚合所有运行中容器的会话列表，搜索、刷新，点击进入 ChatDetailView；
//  - 有 currentContainer 时：显示 SessionView（当前容器的对话列表 + 联系人），与 H5 从账号页「进入会话」一致。
//

import SwiftUI

@MainActor
private final class ChatAvatarImageCache {
    static let shared = ChatAvatarImageCache()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 260
    }
    
    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    
    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct ChatListPlaceholderView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        if let container = appState.currentContainer {
            SessionView(appState: appState, container: container)
        } else {
            AllChatsPageView(appState: appState)
        }
    }
}

/// iOS 16+ 导航栏背景色，避免白条
private struct ToolbarBgModifier: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(color, for: .navigationBar)
        } else {
            content
        }
    }
}

// MARK: - 全部对话（与 H5 ChatPage.vue 一致：聚合多容器会话、搜索、刷新、点击进入聊天）
private struct AllChatsPageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appState: AppState
    @State private var aggregatedItems: [AggregatedChatItem] = []
    @State private var loading = false
    @State private var searchText = ""
    @State private var selectedConversationFilter: ConversationQuickFilter = .all
    @State private var errorMessage: String?
    @State private var lastLoadedSignature: String = ""
    @State private var pendingNavItem: AggregatedChatItem?
    @State private var pendingNavActive: Bool = false
    @State private var pendingNavInitialMessages: [Message] = []
    @State private var containerRemarkEditTarget: Instance?
    @State private var containerRemarkEditText: String = ""
    @State private var containerRemarkSaving = false
    @State private var containerRemarkErrorMessage: String?
    @State private var pinnedConversationKeys: Set<String> = []
    @State private var focusedConversationKeys: Set<String> = []
    @State private var remarkByConversation: [String: String] = [:]
    @State private var contactRemarkByConversation: [String: String] = [:]
    @State private var remarkEditTargetKey: String?
    @State private var remarkEditText: String = ""
    @State private var avatarPreviewImage: UIImage?
    @State private var avatarPreviewName: String = ""
    @State private var avatarPreviewPresented = false
    @State private var remoteSearchConversationKeys: Set<String> = []
    @State private var remoteSearchInstanceKeys: Set<String> = []
    @State private var localSearchConversationKeys: Set<String> = []
    @State private var localSearchSnippetsByConversation: [String: [ConversationSearchHitSnippet]] = [:]
    @State private var groupedSearchResults: [SearchConversationGroup] = []
    @State private var remoteSearchLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchRequestID: Int = 0
    @State private var preloadingInstances = false
    @State private var unreadPollingTask: Task<Void, Never>?
    @State private var lastFullRefreshAt: Date?
    @State private var stalePreviewInstanceIDs: Set<String> = []
    @State private var suppressNextRowTapKey: String?
    @State private var avatarRefreshingConversationKeys: Set<String> = []
    @State private var lastRealtimeSortAt: TimeInterval = 0
    @State private var pendingSortTask: Task<Void, Never>?
    @State private var pinReorderTask: Task<Void, Never>?
    @State private var pinLiftResetTask: Task<Void, Never>?
    @State private var pinAnimationLockUntil: TimeInterval = 0
    @State private var pinAnimatingConversationKey: String?
    @State private var pendingNavTargetMessageID: String?
    @State private var chatsGuideStep: ChatsGuideStep?
    @State private var guideLeftSwipeAnimating = false
    @State private var guideRightSwipeAnimating = false
    private let allChatsGuideShownKey = "guide_all_chats_v1"
    
    private let pinnedStoreKey = "all_chats_pinned_conversations_v1"
    private let focusedStoreKey = "all_chats_focused_conversations_v1"
    private let fullRefreshMinInterval: TimeInterval = 120
    private let fullBatchSize = 8
    private let fullFetchTimeout: TimeInterval = 8

    private struct SearchSnippetLine: Identifiable {
        let messageKey: String
        let messageID: Int?
        let text: String
        let timestamp: Int64
        var id: String { messageKey }
    }

    private struct SearchConversationGroup: Identifiable {
        let conversationKey: String
        let item: AggregatedChatItem
        let hitCount: Int
        let snippets: [SearchSnippetLine]
        var id: String { conversationKey }
    }
    
    private var containersToLoad: [Instance] {
        appState.accountInstances.filter { ($0.state ?? "").lowercased() == "running" }
    }

    /// 全部对话分阶段加载优先级：先拉「已登录」容器，再后台补齐其余容器。
    private func isContainerLoggedIn(_ container: Instance) -> Bool {
        let status = (container.scrmWsStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "已登录" { return true }
        if status.caseInsensitiveCompare("ok") == .orderedSame { return true }
        return false
    }
    
    private var baseFilteredItems: [AggregatedChatItem] {
        aggregatedItems.filter { item in
            matchesConversationFilter(item)
        }
    }

    private var filteredItems: [AggregatedChatItem] {
        let q = normalizedSearchKeyword(searchText)
        if q.isEmpty { return baseFilteredItems }
        return baseFilteredItems.filter { item in
            let key = conversationKey(for: item)
            let sqliteHit = localSearchConversationKeys.contains(key)
            if sqliteHit { return true }
            let contactRemark = contactRemarkByConversation[key] ?? ""
            let localRemark = remarkByConversation[key] ?? ""
            let preview = appState.liveChatSnapshots[key]?.preview ?? (item.chat.last_message.map { lastMessagePreview($0) } ?? "")
            let searchableFields = [
                displayName(item.chat, container: item.container),
                item.chat.remark_name ?? "",
                item.chat.display_name ?? "",
                contactRemark,
                localRemark,
                item.chat.jid ?? "",
                item.chat.phone ?? "",
                formatInstanceName(item.container.name ?? ""),
                preview
            ]
            let localHit = searchableFields.contains { quickContains($0, keyword: q) }
            if localHit { return true }
            if remoteSearchConversationKeys.contains(key) { return true }
            if remoteSearchInstanceKeys.contains(item.container.instanceIdForApi) { return true }
            return false
        }
    }

    private var visibleGroupedSearchResults: [SearchConversationGroup] {
        groupedSearchResults.filter { group in
            matchesConversationFilter(group.item)
        }
    }

    private func matchesConversationFilter(_ item: AggregatedChatItem) -> Bool {
        switch selectedConversationFilter {
        case .all:
            return true
        case .unread:
            let unread = appState.conversationUnreadCount(
                instanceIdForApi: item.container.instanceIdForApi,
                jid: item.chat.jid ?? "",
                baseUnreadHint: item.chat.newMessageCount ?? 0
            )
            return unread > 0
        case .focused:
            return focusedConversationKeys.contains(conversationKey(for: item))
        case .group:
            return (item.chat.jid ?? "").hasSuffix("@g.us")
        }
    }

    /// 搜索输入高频触发时，优先轻量 contains，避免正则归一化在主线程造成键盘卡顿。
    private func quickContains(_ source: String, keyword: String) -> Bool {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !key.isEmpty else { return false }
        let srcLower = src.lowercased()
        let keyLower = key.lowercased()
        return srcLower.contains(keyLower)
    }

    private func normalizedSearchKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    /// 仅以“运行中容器集合”作为自动重拉签名：账号页勾选云机增减会反映到这里
    private var runningContainersSignature: String {
        containersToLoad
            .compactMap(\.ID)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }
    
    private var containerIdentitySignature: String {
        appState.accountInstances
            .map {
                let id = instanceUniqueKey($0)
                let remark = ($0.scrmRemark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(id)|\(remark)|\(name)"
            }
            .sorted()
            .joined(separator: ";")
    }

    private var normalizedSearchText: String {
        normalizedSearchKeyword(searchText)
    }
    
    /// 页面背景：与账号页一致 #F5F5F5，避免过灰
    private static let pageBg = Color(red: 0.96, green: 0.96, blue: 0.96)
    private static let wechatDivider = Color(white: 0.9)
    private static let wechatRed = Color(red: 0.98, green: 0.23, blue: 0.23)
    
    private enum ChatsGuideStep: Int, CaseIterable {
        case search
        case swipeLeftActions
        case swipeRightContainerRemark
        
        var title: String {
            switch self {
            case .search: return "搜索功能说明"
            case .swipeLeftActions: return "左滑可用功能"
            case .swipeRightContainerRemark: return "右滑可用功能"
            }
        }
        
        var detail: String {
            switch self {
            case .search:
                return "搜索框支持：备注、手机号、聊天记录内容。"
            case .swipeLeftActions:
                return "对话行向左滑，可看到“备注”和“置顶”按钮。"
            case .swipeRightContainerRemark:
                return "对话行向右滑，可看到“容器备注”按钮。"
            }
        }
        
        var next: ChatsGuideStep? {
            ChatsGuideStep(rawValue: rawValue + 1)
        }
    }

    private enum ConversationQuickFilter: String, CaseIterable {
        case all = "全部"
        case unread = "未读"
        case focused = "特别关注"
        case group = "群组"
    }
    
    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    pageContent
                }
            } else {
                NavigationView {
                    pageContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }
    
    private var pageContent: some View {
        VStack(spacing: 0) {
            header
            if appState.canFetchInstanceChatLists {
                searchBar
                quickFilterBar
            }
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red).padding(8)
            }
            listContent
                .id(appState.chatTabScrollToTopToken)
        }
        .background(Self.pageBg.ignoresSafeArea(edges: .top))
        .navigationBarHidden(true)
        .modifier(ToolbarBgModifier(color: Self.pageBg))
        .task { await autoLoadAllChats(force: false) }
        .refreshable { await performLightweightPullToRefresh() }
        .onAppear {
            restorePinnedAndRemarks()
            Task { await refreshRemarksFromMeta(aggregatedItems) }
            Task { await refreshContactRemarksForCurrentConversations() }
            restartUnreadPollingIfNeeded()
            startChatsGuideIfNeeded()
        }
        .onChange(of: runningContainersSignature) { _ in
            // 云机勾选增减导致运行中容器变化时：在对话页内自动重拉
            if appState.selectedTab == .chat, appState.canFetchInstanceChatLists {
                Task { await autoLoadAllChats(force: true) }
            }
        }
        .onChange(of: appState.accountInstanceButtonAuth) { _ in
            if appState.canFetchInstanceChatLists {
                Task { await autoLoadAllChats(force: true) }
            } else {
                unreadPollingTask?.cancel()
                unreadPollingTask = nil
                aggregatedItems = []
                lastLoadedSignature = ""
                triggerRemoteSearch("")
            }
            appState.notifyAccountInstancesDidUpdate()
        }
        .onChange(of: appState.selectedTab) { tab in
            if tab == .chat {
                Task { await refreshOnChatPageResumed() }
            }
            restartUnreadPollingIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && appState.selectedTab == .chat {
                Task { await refreshOnChatPageResumed() }
            }
            restartUnreadPollingIfNeeded()
        }
        .onChange(of: appState.currentContainer?.instanceKey) { key in
            // 从 SessionView 返回全部对话时，优先轻量刷新（红点/预览），避免每次全量重拉
            if key == nil && appState.selectedTab == .chat {
                Task { await refreshOnChatPageResumed() }
            }
        }
        .onChange(of: appState.isInChatDetail) { inDetail in
            // 从 ChatDetail 返回全部对话：先本地即时重排，再异步刷新未读/预览，避免排序“慢半拍”。
            guard !inDetail, appState.selectedTab == .chat, appState.currentContainer == nil else { return }
            sortAggregatedItemsByRealtime()
            Task { await refreshOnChatPageResumed() }
        }
        .onChange(of: containerIdentitySignature) { _ in
            syncContainerMetaIntoAggregatedItems()
        }
        .onChange(of: appState.liveChatSnapshotVersion) { _ in
            sortAggregatedItemsByRealtime()
        }
        .onChange(of: searchText) { value in
            scheduleSearch(value)
        }
        .onChange(of: aggregatedItems.count) { _ in
            let keyword = normalizedSearchKeyword(searchText)
            guard !keyword.isEmpty else { return }
            rebuildGroupedSearchResults(keyword: keyword)
        }
        .onChange(of: appState.pendingOpenChatRequest) { req in
            guard let req = req else { return }
            Task { await openChatFromPendingRequest(req) }
        }
        .background(programmaticNavigationLink)
        .alert(
            "设置备注",
            isPresented: Binding(
                get: { remarkEditTargetKey != nil },
                set: { if !$0 { remarkEditTargetKey = nil } }
            )
        ) {
            TextField("请输入备注", text: $remarkEditText)
            Button("保存") {
                guard let key = remarkEditTargetKey else { return }
                let value = remarkEditText.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { remarkByConversation.removeValue(forKey: key) } else { remarkByConversation[key] = value }
                sortAggregatedItemsByRealtime()
                appState.presentUserFeedback("备注已保存", level: .success)
                remarkEditTargetKey = nil
                remarkEditText = ""
                Task {
                    if let ctx = customerSyncContextByConversationKey(key) {
                        await CustomerMetaStore.shared.setRemark(value, context: ctx)
                    }
                    await refreshRemarksFromMeta(aggregatedItems)
                }
            }
            Button("取消", role: .cancel) {
                remarkEditTargetKey = nil
                remarkEditText = ""
            }
        }
        .fullScreenCover(isPresented: $avatarPreviewPresented) {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Spacer()
                    if let image = avatarPreviewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 460)
                    } else {
                        Circle()
                            .fill(Color(white: 0.2))
                            .frame(width: 120, height: 120)
                            .overlay(Image(systemName: "person.fill").foregroundColor(.white))
                    }
                    Text(avatarPreviewName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(white: 0.9))
                        .lineLimit(1)
                    Spacer()
                    Button("关闭") { avatarPreviewPresented = false }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Capsule())
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { containerRemarkEditTarget != nil },
                set: { show in
                    if !show {
                        containerRemarkEditTarget = nil
                        containerRemarkEditText = ""
                        containerRemarkSaving = false
                        containerRemarkErrorMessage = nil
                    }
                }
            )
        ) {
            containerRemarkSheet
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
            searchTask?.cancel()
            searchTask = nil
            unreadPollingTask?.cancel()
            unreadPollingTask = nil
            pendingSortTask?.cancel()
            pendingSortTask = nil
            guideLeftSwipeAnimating = false
            guideRightSwipeAnimating = false
        }
        .overlay { chatsGuideOverlay }
    }
    
    @ViewBuilder
    private var programmaticNavigationLink: some View {
        NavigationLink(isActive: $pendingNavActive) {
            if let item = pendingNavItem {
                ChatDetailView(
                    appState: appState,
                    container: item.container,
                    chat: chatForDetail(item),
                    contacts: [],
                    forceLatestOnInitialEntry: appState.conversationUnreadCount(
                        instanceIdForApi: item.container.instanceIdForApi,
                        jid: item.chat.jid ?? "",
                        baseUnreadHint: item.chat.newMessageCount ?? 0
                    ) > 0,
                    initialMessages: pendingNavInitialMessages,
                    initialScrollToMessageID: pendingNavTargetMessageID
                )
                .id("\(item.container.instanceIdForApi)_\((item.chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                EmptyView()
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }
    
    private func autoLoadAllChats(force: Bool) async {
        guard appState.canFetchInstanceChatLists else {
            await MainActor.run {
                loading = false
                aggregatedItems = []
                lastLoadedSignature = ""
                errorMessage = nil
            }
            return
        }
        await preloadInstancesForChatIfNeeded()
        let sig = runningContainersSignature
        if !force && !shouldDoFullRefresh(signature: sig) {
            await refreshUnreadCountsForAggregatedIfNeeded(containers: containersToLoad)
            return
        }
        lastLoadedSignature = sig
        await loadAllChats()
    }
    
    private func shouldDoFullRefresh(signature: String) -> Bool {
        if signature != lastLoadedSignature { return true }
        guard let last = lastFullRefreshAt else { return true }
        return Date().timeIntervalSince(last) >= fullRefreshMinInterval
    }

    private func loadInitialMessagesForNavigation(item: AggregatedChatItem) async -> [Message] {
        let instanceId = item.container.instanceIdForApi
        guard !instanceId.isEmpty else { return [] }
        guard let chatRowId = item.chat.chat_row_id, chatRowId > 0 else { return [] }
        return await AppCacheStore.shared.loadMessages(instanceId: instanceId, chatRowId: chatRowId, maxAge: nil) ?? []
    }
    
    private func refreshOnChatPageResumed() async {
        guard appState.canFetchInstanceChatLists else { return }
        await preloadInstancesForChatIfNeeded()
        await refreshUnreadCountsForAggregatedIfNeeded(containers: containersToLoad)
        if aggregatedItems.isEmpty {
            await autoLoadAllChats(force: false)
            return
        }
        // 红点更新后，静默补拉会话摘要（last_message），修复“红点已变但预览仍旧”
        let stale = Array(stalePreviewInstanceIDs)
        await refreshChatPreviewsIncrementalSilently(prioritizedInstanceIDs: stale, fallbackAllRunningWhenEmpty: false)
        // 刚从聊天页返回不做重型全量刷新，超过阈值再后台拉新
        if shouldDoFullRefresh(signature: runningContainersSignature) {
            await autoLoadAllChats(force: false)
        } else {
            await MainActor.run { sortAggregatedItemsByRealtime() }
        }
    }

    /// 下拉刷新：仅做轻量同步（未读 + 预览），不触发全量会话同步，保证秒级返回。
    private func performLightweightPullToRefresh() async {
        guard appState.canFetchInstanceChatLists else { return }
        await preloadInstancesForChatIfNeeded()
        let containers = containersToLoad
        guard !containers.isEmpty else { return }

        // 第一阶段：仅等待未读纠偏，确保下拉手势快速结束。
        await refreshUnreadCountsForAggregatedIfNeeded(containers: containers)

        // 第二阶段：预览后台静默补拉，不阻塞 refreshable 的加载动画。
        let prioritizedInstanceIDs: [String] = await MainActor.run {
            var ids = Array(stalePreviewInstanceIDs)
            var seen = Set(ids)
            // 追加当前列表靠前会话对应实例，限制数量，避免全量拉取拖慢体验。
            for item in aggregatedItems {
                let id = item.container.instanceIdForApi
                guard !id.isEmpty, !seen.contains(id) else { continue }
                ids.append(id)
                seen.insert(id)
                if ids.count >= 10 { break }
            }
            return ids
        }
        Task {
            await refreshChatPreviewsIncrementalSilently(
                prioritizedInstanceIDs: prioritizedInstanceIDs,
                fallbackAllRunningWhenEmpty: false
            )
        }
    }
    
    /// 顶部：仅保留居中标题（刷新由自动策略与下拉刷新承担）
    private var header: some View {
        ZStack {
            Text("全部对话")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
            HStack {
                Spacer()
                Button(action: {
                    appState.presentUserFeedback("新建对话功能开发中", level: .info)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color.white)
    }
    
    private func startChatsGuideIfNeeded() {
        guard appState.canFetchInstanceChatLists else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: allChatsGuideShownKey) else {
            chatsGuideStep = nil
            return
        }
        defaults.set(true, forKey: allChatsGuideShownKey)
        chatsGuideStep = .search
    }
    
    private func nextChatsGuideStep() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chatsGuideStep = chatsGuideStep?.next
        }
    }
    
    private func endChatsGuide() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chatsGuideStep = nil
        }
    }
    
    @ViewBuilder
    private var chatsGuideOverlay: some View {
        if let step = chatsGuideStep {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let cardTop: CGFloat = step == .search ? 88 : 146
                ZStack(alignment: .top) {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    
                    if step == .search {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .position(x: width * 0.5, y: 74)
                            .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
                    }
                    
                    if step == .swipeLeftActions {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.point.right.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Image(systemName: "arrow.left")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(white: 0.86), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                        .offset(x: guideLeftSwipeAnimating ? -30 : 0, y: 248)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 22)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                guideLeftSwipeAnimating = true
                            }
                        }
                        .onDisappear {
                            guideLeftSwipeAnimating = false
                        }
                    }
                    
                    if step == .swipeRightContainerRemark {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 15, weight: .bold))
                            Image(systemName: "hand.point.left.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(white: 0.86), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                        .offset(x: guideRightSwipeAnimating ? 30 : 0, y: 248)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 22)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                guideRightSwipeAnimating = true
                            }
                        }
                        .onDisappear {
                            guideRightSwipeAnimating = false
                        }
                    }
                    
                    VStack(spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.74, blue: 0.18))
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(white: 0.12))
                                Text(step.detail)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(white: 0.28))
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 10) {
                            Button("结束引导") { endChatsGuide() }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: 0.35))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.94))
                                .clipShape(Capsule())
                            Button(step.next == nil ? "完成" : "下一步") {
                                nextChatsGuideStep()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(white: 0.9), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 6)
                    .padding(.horizontal, 14)
                    .padding(.top, cardTop)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(30)
        }
    }
    
    /// 搜索框：与账号页筛选框一致
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Color(white: 0.55))
            TextField("搜索", text: $searchText)
                .font(.system(size: 16))
                .textFieldStyle(PlainTextFieldStyle())
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.55))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Self.pageBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.93), lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white)
    }

    private var quickFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ConversationQuickFilter.allCases, id: \.self) { filter in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedConversationFilter = filter
                        }
                    }) {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: selectedConversationFilter == filter ? .semibold : .regular))
                            .foregroundColor(selectedConversationFilter == filter ? .white : Color(white: 0.35))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selectedConversationFilter == filter ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color(white: 0.93))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color.white)
    }

    @ViewBuilder
    private func groupedSearchRow(group: SearchConversationGroup, keyword: String) -> some View {
        let title = displayName(group.item.chat, container: group.item.container)
        let titleText = title.isEmpty ? (maskPhoneOrJid(group.item.chat.jid) ?? "未知联系人") : title
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(white: 0.16))
                    .lineLimit(1)
                Text("(\(group.hitCount)条相关记录)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.5))
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    let initialMessages = await loadInitialMessagesForNavigation(item: group.item)
                    await MainActor.run {
                        pendingNavTargetMessageID = nil
                        pendingNavInitialMessages = initialMessages
                        pendingNavItem = group.item
                        pendingNavActive = true
                        appState.isInChatDetail = true
                    }
                }
            }

            ForEach(group.snippets.prefix(3)) { snippet in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    highlightedText(snippet.text, keyword: keyword)
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.35))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(wechatFormatTime(snippet.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.56))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    Task {
                        let initialMessages = await loadInitialMessagesForNavigation(item: group.item)
                        await MainActor.run {
                            pendingNavTargetMessageID = snippet.messageKey.isEmpty ? (snippet.messageID.map { "\($0)" }) : snippet.messageKey
                            pendingNavInitialMessages = initialMessages
                            pendingNavItem = group.item
                            pendingNavActive = true
                            appState.isInChatDetail = true
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Self.wechatDivider)
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
    }

    private func highlightedText(_ source: String, keyword: String) -> Text {
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !key.isEmpty else { return Text(raw) }
        let lower = raw.lowercased()
        let keyLower = key.lowercased()
        guard let range = lower.range(of: keyLower) else { return Text(raw) }
        let start = raw.distance(from: raw.startIndex, to: range.lowerBound)
        let end = raw.distance(from: raw.startIndex, to: range.upperBound)
        let prefix = String(raw.prefix(start))
        let match = String(raw[raw.index(raw.startIndex, offsetBy: start)..<raw.index(raw.startIndex, offsetBy: end)])
        let suffix = String(raw.suffix(max(0, raw.count - end)))
        return Text(prefix)
            + Text(match).foregroundColor(Color(red: 0.1, green: 0.53, blue: 0.93)).fontWeight(.semibold)
            + Text(suffix)
    }
    
    /// 无「全部对话」拉取权限时：菜单未返回显示加载；已返回且无 key 显示说明
    @ViewBuilder
    private var allChatsPermissionGateContent: some View {
        Group {
            if appState.accountInstanceButtonAuth == nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("加载权限中…")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.55))
                    Spacer()
                }
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color(white: 0.72))
                    Text("当前账号无查看全部对话的权限")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(white: 0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private var listContent: some View {
        Group {
            if !appState.canFetchInstanceChatLists {
                allChatsPermissionGateContent
            } else if loading && aggregatedItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("加载中...")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.55))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if containersToLoad.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundColor(Color(white: 0.7))
                    Text("请在账号页选择云机并进入会话\n或在此查看全部对话")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if !normalizedSearchText.isEmpty && normalizedSearchText.count >= 2 {
                if visibleGroupedSearchResults.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        if remoteSearchLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 46))
                                .foregroundColor(Color(white: 0.72))
                        }
                        Text(remoteSearchLoading ? "搜索中..." : "未找到匹配记录")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.55))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(visibleGroupedSearchResults) { group in
                            groupedSearchRow(group: group, keyword: normalizedSearchText)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.white)
                        }
                    }
                    .listStyle(.plain)
                    .transaction { tx in
                        tx.animation = nil
                    }
                    .overlay(alignment: .topTrailing) {
                        if remoteSearchLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 12)
                                .padding(.top, 6)
                        }
                    }
                }
            } else if filteredItems.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(Color(white: 0.7))
                    Text(searchText.isEmpty ? "暂无对话" : "未找到匹配的对话")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.55))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(filteredItems) { item in
                        let key = conversationKey(for: item)
                        let pinned = pinnedConversationKeys.contains(key)
                        aggregatedChatRow(item, isPinned: pinned) {
                            Task {
                                let initialMessages = await loadInitialMessagesForNavigation(item: item)
                                await MainActor.run {
                                    pendingNavTargetMessageID = nil
                                    pendingNavInitialMessages = initialMessages
                                    pendingNavItem = item
                                    pendingNavActive = true
                                    appState.isInChatDetail = true
                                }
                            }
                        } onTapAvatar: { rowItem, name, currentImage in
                            Task {
                                let latest = await refreshLatestAvatarOnAllChats(for: rowItem)
                                await MainActor.run {
                                    avatarPreviewImage = latest ?? currentImage
                                    avatarPreviewName = name
                                    avatarPreviewPresented = true
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(pinned ? Color(white: 0.94) : Color.white)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                toggleFocusedConversation(key)
                            } label: {
                                Text(focusedConversationKeys.contains(key) ? "取消关注" : "特别关注")
                            }
                            .tint(Color(red: 0.95, green: 0.48, blue: 0.18))

                            Button {
                                togglePinnedConversation(key)
                            } label: {
                                Text(pinned ? "取消置顶" : "置顶")
                            }
                            .tint(Color(red: 0.93, green: 0.56, blue: 0.16))
                            
                            Button {
                                remarkEditTargetKey = key
                                remarkEditText = remarkByConversation[key] ?? ""
                            } label: {
                                Text("备注")
                            }
                            .tint(Color(red: 0.17, green: 0.52, blue: 0.95))
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                appState.requestJumpToAccountInstance(instanceKey: item.container.instanceKey)
                            } label: {
                                Text("跳转云机")
                            }
                            .tint(Color(red: 0.45, green: 0.47, blue: 0.95))

                            Button {
                                containerRemarkEditTarget = item.container
                                containerRemarkEditText = (item.container.scrmRemark ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                containerRemarkErrorMessage = nil
                            } label: {
                                Text("容器备注")
                            }
                            .tint(Color(red: 0.2, green: 0.56, blue: 0.96))
                        }
                        .zIndex(pinAnimatingConversationKey == key ? 999 : 0)
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if remoteSearchLoading && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.trailing, 12)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .background(Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    /// 微信风格会话行：头像 48pt、名称+时间、预览+云机名+未读，分割线左侧缩进
    private func aggregatedChatRow(_ item: AggregatedChatItem, isPinned: Bool, onTapRow: @escaping () -> Void, onTapAvatar: @escaping (AggregatedChatItem, String, UIImage?) -> Void) -> some View {
        let chat = item.chat
        let container = item.container
        let instanceId = container.instanceIdForApi
        let live = liveSnapshot(for: item)
        let jid = chat.jid ?? ""
        let key = "\(instanceId)_\(jid)"
        let isAvatarRefreshing = avatarRefreshingConversationKeys.contains(key)
        let unread = appState.conversationUnreadCount(
            instanceIdForApi: instanceId,
            jid: jid,
            baseUnreadHint: chat.newMessageCount ?? 0
        )
        let draft = appState.chatDraftByConversation[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = draft.isEmpty ? (live?.preview ?? (chat.last_message.map { lastMessagePreview($0) } ?? "")) : "草稿：\(draft)"
        let containerRemark = (container.scrmRemark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawContainerName = formatInstanceName(container.name ?? "")
        let displayContainerName = containerRemark.isEmpty ? rawContainerName : containerRemark
        let fullContainerName = displayContainerName.isEmpty ? "未命名容器" : displayContainerName
        let customRemark = remarkByConversation[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contactRemark = contactRemarkByConversation[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverRemark = chat.remark_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFocused = focusedConversationKeys.contains(key)
        let titleName = {
            if let r = customRemark, !r.isEmpty { return r }
            if let r = contactRemark, !r.isEmpty { return r }
            if let r = serverRemark, !r.isEmpty { return r }
            let baseName = displayName(chat, container: container).trimmingCharacters(in: .whitespacesAndNewlines)
            if !baseName.isEmpty { return baseName }
            return maskPhoneOrJid(chat.phone) ?? maskPhoneOrJid(chat.jid) ?? ""
        }()
        let isGroupConversation = (chat.jid ?? "").hasSuffix("@g.us")
        return HStack(alignment: .top, spacing: 12) {
            Button(action: {
                suppressNextRowTapKey = key
                onTapAvatar(item, titleName, base64ToImage(live?.avatarBase64 ?? chat.avatar))
            }) {
                avatarView(chat: chat, container: container, overrideAvatarBase64: live?.avatarBase64, refreshing: isAvatarRefreshing)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        if isFocused {
                            Text("特别关注")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.95, green: 0.48, blue: 0.18))
                                .clipShape(Capsule())
                        }
                        if isGroupConversation {
                            Text("群组")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.2, green: 0.56, blue: 0.96))
                                .clipShape(Capsule())
                        }
                        Text(titleName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(wechatFormatTime(live?.timestamp ?? chat.last_message?.timestamp))
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.53))
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 0) {
                    Text(fullContainerName)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .center, spacing: 6) {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundColor(draft.isEmpty ? Color(white: 0.53) : Color(red: 0.89, green: 0.35, blue: 0.24))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if unread > 0 {
                        Text(unread > 99 ? "99" : "\(unread)")
                            .font(.system(size: unread > 9 ? 10 : 11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Self.wechatRed)
                            .clipShape(Circle())
                    }
                }
                .frame(height: 20, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .background(isPinned ? Color(white: 0.94) : Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Self.wechatDivider)
                .frame(height: 0.5)
                .padding(.leading, 76)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if suppressNextRowTapKey == key {
                suppressNextRowTapKey = nil
                return
            }
            onTapRow()
        }
    }
    
    /// 微信风格时间：今天 HH:mm，昨天 昨天，本周 周X，更早 月/日
    private func wechatFormatTime(_ ts: Int64?) -> String {
        guard let t = ts, t > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(t) / 1000)
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天"
        }
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
        if date >= weekAgo {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEE"  // 周一、周二
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(date, equalTo: now, toGranularity: .year) ? "M/d" : "yyyy/M/d"
        return f.string(from: date)
    }
    
    /// 微信风格头像 48pt
    private func avatarView(chat: Chat, container: Instance, overrideAvatarBase64: String? = nil, refreshing: Bool = false) -> some View {
        let base64 = overrideAvatarBase64 ?? chat.avatar
        let image = base64ToImage(base64)
        return Group {
            if let ui = image {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(white: 0.88))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 20)).foregroundColor(Color(white: 0.5)))
            }
        }
        .frame(width: 48, height: 48)
        .overlay(alignment: .bottomTrailing) {
            if refreshing {
                ProgressView()
                    .scaleEffect(0.58)
                    .padding(2)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
            }
        }
    }

    @ViewBuilder
    private var containerRemarkSheet: some View {
        NavigationView {
            if let target = containerRemarkEditTarget {
                let originalName = formatInstanceName(target.name ?? "")
                let containerName = originalName.isEmpty ? "未命名容器" : originalName
                VStack(alignment: .leading, spacing: 14) {
                    TextField("请输入容器备注", text: $containerRemarkEditText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(containerRemarkSaving)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("容器名称")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.45))
                        Text(containerName)
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.2))
                            .lineLimit(2)
                    }
                    if let err = containerRemarkErrorMessage, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(white: 0.97))
                .navigationTitle("容器备注")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            containerRemarkEditTarget = nil
                            containerRemarkEditText = ""
                            containerRemarkSaving = false
                            containerRemarkErrorMessage = nil
                        }
                        .disabled(containerRemarkSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(containerRemarkSaving ? "保存中..." : "保存") {
                            saveContainerRemark()
                        }
                        .disabled(containerRemarkSaving)
                    }
                }
            } else {
                Color.clear
            }
        }
    }
    
    private func displayName(_ chat: Chat, container: Instance) -> String {
        let key = "\(container.instanceIdForApi)_\(chat.jid ?? "")"
        let localRemark = (remarkByConversation[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !localRemark.isEmpty { return localRemark }
        let contactRemark = (contactRemarkByConversation[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !contactRemark.isEmpty { return contactRemark }
        if let remark = chat.remark_name, !remark.isEmpty { return remark }
        if let name = chat.display_name, !name.isEmpty { return name }
        return maskPhoneOrJid(chat.phone) ?? maskPhoneOrJid(chat.jid) ?? ""
    }
    
    /// 进入聊天详情前将“备注优先显示名”写入 chat，避免详情页退化成手机号。
    private func chatForDetail(_ item: AggregatedChatItem) -> Chat {
        var chat = item.chat
        let key = conversationKey(for: item)
        let localRemark = (remarkByConversation[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contactRemark = (contactRemarkByConversation[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let serverRemark = (chat.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !localRemark.isEmpty {
            chat.remark_name = localRemark
        } else if !contactRemark.isEmpty {
            chat.remark_name = contactRemark
        } else if !serverRemark.isEmpty {
            chat.remark_name = serverRemark
        }
        let currentDisplay = (chat.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if currentDisplay.isEmpty {
            chat.display_name = displayName(chat, container: item.container)
        }
        return chat
    }
    
    private func lastMessagePreview(_ last: LastMessage) -> String {
        switch last.message_type {
        case 0: return last.text_data ?? ""
        case 1: return "[图片]" + (last.text_data ?? "")
        case 2: return "[语音]"
        case 3, 13: return "[视频]"
        case 9: return "[文件]"
        case 90: return "[通话]"
        default: return last.text_data ?? "[消息]"
        }
    }
    
    private func formatTime(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f.string(from: date)
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
    
    private func base64ToImage(_ base64: String?) -> UIImage? {
        guard let raw = base64, !raw.isEmpty else { return nil }
        let normalized: String = {
            if let comma = raw.firstIndex(of: ","), raw.lowercased().hasPrefix("data:image") {
                return String(raw[raw.index(after: comma)...])
            }
            return raw
        }()
        let cleaned = normalized.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        let cacheKey = avatarCacheKey(from: cleaned)
        if let cached = ChatAvatarImageCache.shared.image(for: cacheKey) {
            return cached
        }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        ChatAvatarImageCache.shared.store(image, for: cacheKey)
        return image
    }
    
    private func avatarCacheKey(from cleanedBase64: String) -> String {
        let prefix = String(cleanedBase64.prefix(32))
        let suffix = String(cleanedBase64.suffix(32))
        return "\(cleanedBase64.count)|\(prefix)|\(suffix)"
    }
    
    /// 将“点击头像拉最新头像”下沉到全部对话页，成功后覆盖内存快照与本地会话缓存。
    private func refreshLatestAvatarOnAllChats(for item: AggregatedChatItem) async -> UIImage? {
        let instanceId = item.container.instanceIdForApi
        guard let ip = item.container.boxIP, !ip.isEmpty else { return nil }
        let jid = (item.chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return nil }
        let key = "\(instanceId)_\(jid)"
        
        let alreadyRefreshing = await MainActor.run { avatarRefreshingConversationKeys.contains(key) }
        if alreadyRefreshing { return nil }
        await MainActor.run { avatarRefreshingConversationKeys.insert(key) }
        defer {
            Task { @MainActor in
                avatarRefreshingConversationKeys.remove(key)
            }
        }
        
        do {
            let contacts = try await ChatService.shared.getContacts(instanceId: instanceId, boxIP: ip)
            let latest = contacts.first(where: { ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == jid })
            guard let avatar = latest?.avatar, !avatar.isEmpty else { return nil }
            
            await MainActor.run {
                let old = appState.liveChatSnapshots[key]
                let previewFromRow = item.chat.last_message.map { lastMessagePreview($0) } ?? ""
                let timestampFromRow = item.chat.last_message?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
                appState.liveChatSnapshots[key] = LiveChatSnapshot(
                    displayName: old?.displayName ?? displayName(item.chat, container: item.container),
                    avatarBase64: avatar,
                    preview: old?.preview ?? previewFromRow,
                    timestamp: old?.timestamp ?? timestampFromRow
                )
                if let idx = aggregatedItems.firstIndex(where: { conversationKey(for: $0) == key }) {
                    aggregatedItems[idx].chat.avatar = avatar
                }
                appState.liveChatSnapshotVersion += 1
            }
            
            var cached = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
            if let idx = cached.firstIndex(where: { ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == jid }) {
                cached[idx].avatar = avatar
                await AppCacheStore.shared.saveChats(instanceId: instanceId, chats: cached)
            }
            return base64ToImage(avatar)
        } catch {
            return nil
        }
    }
    
    private func liveSnapshot(for item: AggregatedChatItem) -> LiveChatSnapshot? {
        let key = "\(item.container.instanceIdForApi)_\(item.chat.jid ?? "")"
        return appState.liveChatSnapshots[key]
    }
    
    private func sortAggregatedItemsByRealtime(
        forceImmediate: Bool = false,
        animation: Animation = .interactiveSpring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.12)
    ) {
        let now = Date().timeIntervalSince1970
        if !forceImmediate, now < pinAnimationLockUntil {
            return
        }
        let minInterval: TimeInterval = 0.24
        let elapsed = now - lastRealtimeSortAt
        if !forceImmediate && elapsed < minInterval {
            pendingSortTask?.cancel()
            let wait = minInterval - elapsed
            pendingSortTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                await MainActor.run {
                    self.sortAggregatedItemsByRealtime(forceImmediate: true)
                }
            }
            return
        }
        pendingSortTask?.cancel()
        pendingSortTask = nil
        lastRealtimeSortAt = now
        let sorted = aggregatedItems.sorted { a, b in
            let aKey = "\(a.container.instanceIdForApi)_\(a.chat.jid ?? "")"
            let bKey = "\(b.container.instanceIdForApi)_\(b.chat.jid ?? "")"
            let ap = pinnedConversationKeys.contains(aKey)
            let bp = pinnedConversationKeys.contains(bKey)
            if ap != bp { return ap && !bp }
            let ta = appState.liveChatSnapshots[aKey]?.timestamp ?? a.chat.last_message?.timestamp ?? 0
            let tb = appState.liveChatSnapshots[bKey]?.timestamp ?? b.chat.last_message?.timestamp ?? 0
            return ta > tb
        }
        let oldIDs = aggregatedItems.map(\.id)
        let newIDs = sorted.map(\.id)
        guard oldIDs != newIDs else { return }
        if oldIDs.isEmpty {
            aggregatedItems = sorted
            return
        }
        withAnimation(animation) {
            aggregatedItems = sorted
        }
    }

    private func togglePinnedConversation(_ key: String) {
        pinAnimatingConversationKey = key
        if pinnedConversationKeys.contains(key) {
            pinnedConversationKeys.remove(key)
        } else {
            pinnedConversationKeys.insert(key)
        }
        savePinned()
        // 避免在 swipe 动作仍在收起时立即重排导致“空白+二次卡顿”。
        pinReorderTask?.cancel()
        pinReorderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            pinAnimationLockUntil = Date().timeIntervalSince1970 + 0.30
            sortAggregatedItemsByRealtime(
                forceImmediate: true,
                animation: .linear(duration: 0.26)
            )
            pinLiftResetTask?.cancel()
            pinLiftResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                if pinAnimatingConversationKey == key {
                    pinAnimatingConversationKey = nil
                }
            }
        }
    }

    private func toggleFocusedConversation(_ key: String) {
        if focusedConversationKeys.contains(key) {
            focusedConversationKeys.remove(key)
        } else {
            focusedConversationKeys.insert(key)
        }
        saveFocused()
        sortAggregatedItemsByRealtime(forceImmediate: true)
    }
    
    private func openChatFromPendingRequest(_ req: PendingOpenChatRequest) async {
        guard appState.canFetchInstanceChatLists else {
            await MainActor.run {
                appState.pendingOpenChatRequest = nil
                appState.presentUserFeedback("当前账号无查看对话权限", level: .info)
            }
            return
        }
        if let item = findAggregatedItem(for: req) {
            let initialMessages = await loadInitialMessagesForNavigation(item: item)
            await presentPendingChat(item: item, initialMessages: initialMessages, targetMessageID: nil)
            return
        }
        if let cachedItem = await buildAggregatedItemFromCache(for: req) {
            let initialMessages = await loadInitialMessagesForNavigation(item: cachedItem)
            await MainActor.run {
                if !aggregatedItems.contains(where: {
                    $0.container.instanceIdForApi == cachedItem.container.instanceIdForApi &&
                    ($0.chat.jid ?? "") == (cachedItem.chat.jid ?? "")
                }) {
                    aggregatedItems.insert(cachedItem, at: 0)
                }
                // 先把会话插到列表，后面统一走强制重建导航，避免当前已在详情页时只更新部分 UI。
                aggregatedItems.insert(cachedItem, at: 0)
            }
            await presentPendingChat(item: cachedItem, initialMessages: initialMessages, targetMessageID: nil)
            return
        }
        if aggregatedItems.isEmpty {
            await loadAllChatsFromCache(containers: containersToLoad)
            if let item = findAggregatedItem(for: req) {
                let initialMessages = await loadInitialMessagesForNavigation(item: item)
                await presentPendingChat(item: item, initialMessages: initialMessages, targetMessageID: nil)
                return
            }
        }
        await loadAllChats()
        if let item = findAggregatedItem(for: req) {
            let initialMessages = await loadInitialMessagesForNavigation(item: item)
            await presentPendingChat(item: item, initialMessages: initialMessages, targetMessageID: nil)
        } else {
            await MainActor.run {
                appState.pendingOpenChatRequest = nil
            }
        }
    }

    @MainActor
    private func presentPendingChat(item: AggregatedChatItem, initialMessages: [Message], targetMessageID: String?) async {
        let activate = {
            pendingNavTargetMessageID = targetMessageID
            pendingNavInitialMessages = initialMessages
            pendingNavItem = item
            pendingNavActive = true
            appState.isInChatDetail = true
            appState.pendingOpenChatRequest = nil
        }

        if pendingNavActive {
            pendingNavActive = false
            appState.isInChatDetail = false
            pendingNavItem = nil
            pendingNavInitialMessages = []
            pendingNavTargetMessageID = nil
            DispatchQueue.main.async {
                activate()
            }
        } else {
            activate()
        }
    }

    private func buildAggregatedItemFromCache(for req: PendingOpenChatRequest) async -> AggregatedChatItem? {
        guard let container = appState.accountInstances.first(where: { $0.instanceIdForApi == req.instanceIdForApi }) else {
            return nil
        }
        let targetJid = req.jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetJid.isEmpty else { return nil }
        let cached = await AppCacheStore.shared.loadChats(instanceId: req.instanceIdForApi, maxAge: nil) ?? []
        let pending = await AppCacheStore.shared.loadPendingConversations(instanceId: req.instanceIdForApi, maxAge: nil)
        let merged = mergedChatsByJid(primary: cached, overlay: pending)
        guard let chat = merged.first(where: {
            ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == targetJid
        }) else {
            return nil
        }
        return AggregatedChatItem(container: container, chat: chat)
    }
    
    private func findAggregatedItem(for req: PendingOpenChatRequest) -> AggregatedChatItem? {
        aggregatedItems.first { item in
            item.container.instanceIdForApi == req.instanceIdForApi && (item.chat.jid ?? "") == req.jid
        }
    }
    
    private func loadAllChats() async {
        guard appState.canFetchInstanceChatLists else { return }
        let containers = containersToLoad
        guard !containers.isEmpty else {
            // 容器列表瞬时为空时保留现有会话，避免返回页面时出现“列表清空再卡加载”
            await MainActor.run { errorMessage = nil }
            return
        }
        if loading { return }
        if aggregatedItems.isEmpty {
            await loadAllChatsFromCache(containers: containers)
        }
        // 与 H5 一致：即便 WS 断连，也先用 unread_count 兜底回补红点，不等全量 chats 拉完
        await refreshUnreadCountsForAggregatedIfNeeded(containers: containers)
        await MainActor.run { loading = true; errorMessage = nil }
        defer {
            Task { @MainActor in
                loading = false
            }
        }
        
        var remarksFromContacts: [String: String] = contactRemarkByConversation
        var failureCount = 0
        let oldByInstance: [String: [AggregatedChatItem]] = Dictionary(
            grouping: aggregatedItems,
            by: { $0.container.instanceIdForApi }
        )
        let containerMap = containers.reduce(into: [String: Instance]()) { acc, c in
            let key = c.instanceIdForApi
            if acc[key] == nil { acc[key] = c }
        }
        var mergedByConversation: [String: AggregatedChatItem] = [:]
        func mergeKey(_ item: AggregatedChatItem) -> String {
            "\(item.container.instanceIdForApi)_\(item.chat.jid ?? "")"
        }
        func upsert(_ item: AggregatedChatItem) {
            mergedByConversation[mergeKey(item)] = item
        }
        func sortMerged(_ items: [AggregatedChatItem]) -> [AggregatedChatItem] {
            items.sorted { a, b in
            let aKey = "\(a.container.instanceIdForApi)_\(a.chat.jid ?? "")"
            let bKey = "\(b.container.instanceIdForApi)_\(b.chat.jid ?? "")"
            let ap = pinnedConversationKeys.contains(aKey)
            let bp = pinnedConversationKeys.contains(bKey)
            if ap != bp { return ap && !bp }
            let ta = appState.liveChatSnapshots[aKey]?.timestamp ?? a.chat.last_message?.timestamp ?? 0
            let tb = appState.liveChatSnapshots[bKey]?.timestamp ?? b.chat.last_message?.timestamp ?? 0
            return ta > tb
        }
        }

        func processContainers(_ phaseContainers: [Instance], publishAfterPhase: Bool) async {
            var start = 0
            while start < phaseContainers.count {
                let end = min(start + fullBatchSize, phaseContainers.count)
                let batch = Array(phaseContainers[start..<end])
                start = end
                
                let batchResults: [(instanceId: String, chats: [Chat]?, failed: Bool)] = await withTaskGroup(of: (String, [Chat]?, Bool).self) { group in
                    for container in batch {
                        group.addTask {
                            let instanceId = container.instanceIdForApi
                            guard let boxIP = container.boxIP, !boxIP.isEmpty else {
                                return (instanceId, nil, true)
                            }
                            do {
                                let chats = try await fetchChatsWithTimeout(instanceId: instanceId, boxIP: boxIP, timeout: fullFetchTimeout)
                                let withLocalAvatar = await mergeServerChatsPreservingLocalAvatar(instanceId: instanceId, serverChats: chats)
                                let mergedChats = await mergeServerChatsWithPending(instanceId: instanceId, serverChats: withLocalAvatar)
                                await AppCacheStore.shared.saveChats(instanceId: instanceId, chats: mergedChats)
                                Task.detached(priority: .utility) {
                                    await AllChatsMessageWarmupService.shared.warmup(instanceId: instanceId, boxIP: boxIP, chats: mergedChats)
                                }
                                return (instanceId, mergedChats, false)
                            } catch {
                                return (instanceId, nil, true)
                            }
                        }
                    }
                    var arr: [(String, [Chat]?, Bool)] = []
                    for await item in group {
                        arr.append(item)
                    }
                    return arr
                }
                
                for result in batchResults {
                    if let chats = result.chats, let container = containerMap[result.instanceId] {
                        for chat in chats {
                            upsert(AggregatedChatItem(container: container, chat: chat))
                        }
                        stalePreviewInstanceIDs.remove(result.instanceId)
                    } else {
                        if let oldItems = oldByInstance[result.instanceId], !oldItems.isEmpty {
                            for item in oldItems {
                                upsert(item)
                            }
                        }
                        if result.failed { failureCount += 1 }
                    }
                }
            }

            if publishAfterPhase {
                let stageMerged = sortMerged(Array(mergedByConversation.values))
                if !stageMerged.isEmpty {
                    await MainActor.run {
                        aggregatedItems = stageMerged
                        errorMessage = nil
                    }
                }
            }
        }

        let loggedInContainers = containers.filter { isContainerLoggedIn($0) }
        let otherContainers = containers.filter { !isContainerLoggedIn($0) }
        if !loggedInContainers.isEmpty {
            await processContainers(loggedInContainers, publishAfterPhase: true)
            if !otherContainers.isEmpty {
                await processContainers(otherContainers, publishAfterPhase: false)
            }
        } else {
            await processContainers(containers, publishAfterPhase: false)
        }

        let merged = sortMerged(Array(mergedByConversation.values))
        await MainActor.run {
            aggregatedItems = merged
            contactRemarkByConversation = remarksFromContacts
            if merged.isEmpty && failureCount > 0 {
                errorMessage = "加载对话失败，请稍后重试"
            } else {
                errorMessage = nil
            }
        }
        await MainActor.run { lastFullRefreshAt = Date() }
        await refreshUnreadCountsForAggregatedIfNeeded(containers: containers)
        await refreshContactRemarksForCurrentConversations()
        await refreshRemarksFromMeta(merged)
    }
    
    private func loadAllChatsFromCache(containers: [Instance]) async {
        guard appState.canFetchInstanceChatLists else { return }
        var merged: [AggregatedChatItem] = []
        for container in containers {
            let instanceId = container.instanceIdForApi
            let cached = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
            let pending = await AppCacheStore.shared.loadPendingConversations(instanceId: instanceId, maxAge: nil)
            let chats = mergedChatsByJid(primary: cached, overlay: pending)
            for chat in chats {
                merged.append(AggregatedChatItem(container: container, chat: chat))
            }
        }
        guard !merged.isEmpty else { return }
        merged.sort { a, b in
            let aKey = "\(a.container.instanceIdForApi)_\(a.chat.jid ?? "")"
            let bKey = "\(b.container.instanceIdForApi)_\(b.chat.jid ?? "")"
            let ap = pinnedConversationKeys.contains(aKey)
            let bp = pinnedConversationKeys.contains(bKey)
            if ap != bp { return ap && !bp }
            let ta = appState.liveChatSnapshots[aKey]?.timestamp ?? a.chat.last_message?.timestamp ?? 0
            let tb = appState.liveChatSnapshots[bKey]?.timestamp ?? b.chat.last_message?.timestamp ?? 0
            return ta > tb
        }
        await MainActor.run { aggregatedItems = merged }
        await refreshContactRemarksForCurrentConversations()
        await refreshRemarksFromMeta(merged)
    }
    
    private func conversationKey(for item: AggregatedChatItem) -> String {
        "\(item.container.instanceIdForApi)_\(item.chat.jid ?? "")"
    }
    
    private func restorePinnedAndRemarks() {
        if let arr = UserDefaults.standard.array(forKey: pinnedStoreKey) as? [String] {
            pinnedConversationKeys = Set(arr)
        }
        if let arr = UserDefaults.standard.array(forKey: focusedStoreKey) as? [String] {
            focusedConversationKeys = Set(arr)
        }
    }
    
    private func savePinned() {
        UserDefaults.standard.set(Array(pinnedConversationKeys), forKey: pinnedStoreKey)
    }

    private func saveFocused() {
        UserDefaults.standard.set(Array(focusedConversationKeys), forKey: focusedStoreKey)
    }

    private func instanceUniqueKey(_ inst: Instance) -> String {
        let id = "\(inst.ID ?? 0)"
        let box = (inst.boxIP ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let app = (inst.appType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(id)|\(box)|\(app)"
    }

    private func saveContainerRemark() {
        guard let target = containerRemarkEditTarget else { return }
        guard let instanceID = target.ID else {
            containerRemarkErrorMessage = "容器ID缺失，无法保存备注"
            return
        }
        let targetKey = instanceUniqueKey(target)
        let trimmed = containerRemarkEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        containerRemarkSaving = true
        containerRemarkErrorMessage = nil
        Task {
            do {
                try await AccountService.shared.updateInstanceRemark(instanceId: instanceID, remark: trimmed)
                await MainActor.run {
                    if let idx = appState.accountInstances.firstIndex(where: { instanceUniqueKey($0) == targetKey }) {
                        appState.accountInstances[idx] = appState.accountInstances[idx].with(scrmRemark: trimmed)
                    }
                    for i in aggregatedItems.indices where instanceUniqueKey(aggregatedItems[i].container) == targetKey {
                        aggregatedItems[i] = AggregatedChatItem(
                            container: aggregatedItems[i].container.with(scrmRemark: trimmed),
                            chat: aggregatedItems[i].chat
                        )
                    }
                    appState.notifyAccountInstancesDidUpdate()
                    sortAggregatedItemsByRealtime()
                    containerRemarkSaving = false
                    containerRemarkEditTarget = nil
                    containerRemarkEditText = ""
                    containerRemarkErrorMessage = nil
                    appState.presentUserFeedback("容器备注已保存", level: .success)
                }
                await AppCacheStore.shared.saveInstances(selectedBoxIPs: appState.accountSelectedBoxIPs, instances: appState.accountInstances)
            } catch {
                await MainActor.run {
                    containerRemarkSaving = false
                    containerRemarkErrorMessage = error.localizedDescription
                    appState.presentUserFeedback(error.localizedDescription, level: .error)
                }
            }
        }
    }
    
    private func conversationPhone(for item: AggregatedChatItem) -> String? {
        if let p = item.chat.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
        guard let jid = item.chat.jid else { return nil }
        let raw = jid.split(separator: "@").first.map(String.init) ?? jid
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    
    private func refreshRemarksFromMeta(_ items: [AggregatedChatItem]) async {
        guard !items.isEmpty else { return }
        var map: [String: String] = [:]
        for item in items {
            let key = conversationKey(for: item)
            let meta = await CustomerMetaStore.shared.load(conversationKey: key)
            let remark = meta.remark.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remark.isEmpty { map[key] = remark }
        }
        await MainActor.run { remarkByConversation = map }
    }
    
    private func customerSyncContextByConversationKey(_ key: String) -> CustomerSyncContext? {
        guard let item = aggregatedItems.first(where: { conversationKey(for: $0) == key }) else { return nil }
        return CustomerSyncContext(
            conversationKey: key,
            boxIP: item.container.boxIP,
            instanceId: item.container.instanceIdForApi,
            jid: item.chat.jid,
            phone: conversationPhone(for: item)
        )
    }
    
    private func triggerRemoteSearch(_ raw: String) {
        let keyword = normalizedSearchKeyword(raw)
        searchTask?.cancel()
        searchTask = nil
        searchRequestID += 1
        let requestID = searchRequestID
        if keyword.isEmpty || keyword.count < 2 {
            localSearchConversationKeys = []
            localSearchSnippetsByConversation = [:]
            remoteSearchConversationKeys = []
            remoteSearchInstanceKeys = []
            groupedSearchResults = []
            remoteSearchLoading = false
            return
        }
        guard appState.canFetchInstanceChatLists else { return }
        searchTask = Task {
            await MainActor.run {
                guard requestID == searchRequestID else { return }
                remoteSearchLoading = true
            }
            defer {
                Task { @MainActor in
                    guard requestID == searchRequestID else { return }
                    remoteSearchLoading = false
                }
            }

            let instanceIds = containersToLoad.map(\.instanceIdForApi).filter { !$0.isEmpty }
            let localHits = await AppCacheStore.shared.searchConversationKeys(
                keyword: keyword,
                instanceIds: instanceIds,
                limit: 1500
            )
            let snippetHits = await AppCacheStore.shared.searchConversationSnippets(
                keyword: keyword,
                instanceIds: instanceIds,
                perConversation: 50,
                limit: 3200
            )
            if Task.isCancelled { return }
            await MainActor.run {
                guard requestID == searchRequestID else { return }
                guard normalizedSearchKeyword(searchText) == keyword else { return }
                localSearchConversationKeys = localHits
                localSearchSnippetsByConversation = snippetHits
                rebuildGroupedSearchResults(keyword: keyword)
            }

            var convKeys = Set<String>()
            var instKeys = Set<String>()
            let selectedBoxIPs = Array(appState.accountSelectedBoxIPs)
            await withTaskGroup(of: [[String: Any]].self) { group in
                for boxIP in selectedBoxIPs {
                    group.addTask {
                        (try? await ChatService.shared.searchBoxChats(keyword: keyword, boxIP: boxIP)) ?? []
                    }
                }
                for await rows in group {
                    if Task.isCancelled { break }
                    for row in rows {
                        let instanceAny = row["app_type_key"] ?? row["instance_id"] ?? row["instanceId"]
                        let instanceId = "\(instanceAny ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
                        let jid = "\(row["jid"] ?? row["chat_jid"] ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
                        if !instanceId.isEmpty {
                            instKeys.insert(instanceId)
                            if !jid.isEmpty {
                                convKeys.insert("\(instanceId)_\(jid)")
                            }
                        }
                    }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard requestID == searchRequestID else { return }
                guard normalizedSearchKeyword(searchText) == keyword else { return }
                remoteSearchConversationKeys = convKeys
                remoteSearchInstanceKeys = instKeys
                rebuildGroupedSearchResults(keyword: keyword)
            }
        }
    }

    /// 输入防抖：减少每击键触发 SQLite/远端搜索，保证键盘输入流畅。
    private func scheduleSearch(_ raw: String) {
        searchDebounceTask?.cancel()
        let keyword = normalizedSearchKeyword(raw)
        if keyword.isEmpty {
            triggerRemoteSearch("")
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                triggerRemoteSearch(keyword)
            }
        }
    }

    private func rebuildGroupedSearchResults(keyword: String) {
        guard !keyword.isEmpty else {
            groupedSearchResults = []
            return
        }
        var results: [SearchConversationGroup] = []
        for item in aggregatedItems {
            let key = conversationKey(for: item)
            let snippetRows = (localSearchSnippetsByConversation[key] ?? []).sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.messageKey > $1.messageKey
            }
            let sqliteHit = localSearchConversationKeys.contains(key)
            let remoteHit = remoteSearchConversationKeys.contains(key) || remoteSearchInstanceKeys.contains(item.container.instanceIdForApi)
            let fallbackHit = {
                let preview = appState.liveChatSnapshots[key]?.preview ?? (item.chat.last_message.map { lastMessagePreview($0) } ?? "")
                let searchable = [
                    displayName(item.chat, container: item.container),
                    item.chat.remark_name ?? "",
                    item.chat.display_name ?? "",
                    item.chat.phone ?? "",
                    item.chat.jid ?? "",
                    preview
                ]
                return searchable.contains { quickContains($0, keyword: keyword) }
            }()
            guard sqliteHit || remoteHit || fallbackHit || !snippetRows.isEmpty else { continue }

            let snippets: [SearchSnippetLine]
            if snippetRows.isEmpty {
                let preview = appState.liveChatSnapshots[key]?.preview ?? (item.chat.last_message.map { lastMessagePreview($0) } ?? "")
                let fallback = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                if fallback.isEmpty {
                    snippets = []
                } else {
                    snippets = [SearchSnippetLine(
                        messageKey: "",
                        messageID: nil,
                        text: fallback,
                        timestamp: appState.liveChatSnapshots[key]?.timestamp ?? (item.chat.last_message?.timestamp ?? 0)
                    )]
                }
            } else {
                snippets = snippetRows.prefix(3).map {
                    SearchSnippetLine(
                        messageKey: $0.messageKey,
                        messageID: $0.messageID,
                        text: $0.text,
                        timestamp: $0.timestamp
                    )
                }
            }
            let hitCount = max(snippetRows.count, snippets.count, (sqliteHit || remoteHit || fallbackHit) ? 1 : 0)
            results.append(
                SearchConversationGroup(
                    conversationKey: key,
                    item: item,
                    hitCount: hitCount,
                    snippets: snippets
                )
            )
        }
        results.sort { lhs, rhs in
            let lt = lhs.snippets.first?.timestamp ?? (lhs.item.chat.last_message?.timestamp ?? 0)
            let rt = rhs.snippets.first?.timestamp ?? (rhs.item.chat.last_message?.timestamp ?? 0)
            return lt > rt
        }
        groupedSearchResults = results
    }
    
    private func preloadInstancesForChatIfNeeded() async {
        guard appState.canFetchInstanceChatLists else { return }
        if preloadingInstances { return }
        if !appState.accountInstances.isEmpty { return }
        if appState.accountSelectedBoxIPs.isEmpty { return }
        preloadingInstances = true
        defer { preloadingInstances = false }
        
        // 先用本地缓存秒开
        if let cached = await AppCacheStore.shared.loadInstances(selectedBoxIPs: appState.accountSelectedBoxIPs, maxAge: nil),
           !cached.isEmpty {
            await MainActor.run {
                appState.accountInstances = appState.mergeStableUnreadIntoInstances(cached)
                appState.sortAccountInstances()
            }
        }
        
        // 再后台拉新覆盖（stale-while-revalidate）
        do {
            var all: [Instance] = []
            for boxIP in appState.accountSelectedBoxIPs {
                let list = try await AccountService.shared.getInstanceList(boxIP: boxIP)
                all.append(contentsOf: list)
            }
            await MainActor.run {
                appState.accountInstances = appState.mergeStableUnreadIntoInstances(all)
                appState.sortAccountInstances()
                appState.notifyAccountInstancesDidUpdate()
            }
            await AppCacheStore.shared.saveInstances(selectedBoxIPs: appState.accountSelectedBoxIPs, instances: appState.accountInstances)
        } catch {
            // 不阻塞页面展示，保持缓存数据可读
        }
    }
    
    private func restartUnreadPollingIfNeeded() {
        unreadPollingTask?.cancel()
        unreadPollingTask = nil
        guard appState.canFetchInstanceChatLists, appState.selectedTab == .chat, scenePhase == .active else { return }
        unreadPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await refreshUnreadCountsForAggregatedIfNeeded(containers: containersToLoad)
            }
        }
    }
    
    /// 通过 unread_count 接口快速回补会话/容器红点，避免后台期间 WS 断连导致未读丢失
    private func refreshUnreadCountsForAggregatedIfNeeded(containers: [Instance]) async {
        guard appState.canFetchInstanceChatLists else { return }
        let instanceIds = Array(Set(containers.map(\.instanceIdForApi).filter { !$0.isEmpty }))
        guard !instanceIds.isEmpty else { return }
        do {
            let unreadByInstance = try await ChatService.shared.getUnreadCounts(instanceIds: instanceIds)
            var totals: [String: Int] = [:]
            for (instanceId, map) in unreadByInstance {
                totals[instanceId] = max(0, map.values.reduce(0, +))
            }
            var staleInstances = Set<String>()
            let existingCountsByConv: [String: Int] = aggregatedItems.reduce(into: [String: Int]()) { acc, item in
                let key = "\(item.container.instanceIdForApi)_\(item.chat.jid ?? "")"
                let count = item.chat.newMessageCount ?? 0
                acc[key] = max(acc[key] ?? 0, count)
            }
            await MainActor.run {
                appState.applyServerUnreadSnapshot(unreadByInstance, queriedInstanceIds: Set(instanceIds))
                appState.mergeServerUnreadTotals(totals)
                guard !aggregatedItems.isEmpty else { return }
                var updated = aggregatedItems
                for i in updated.indices {
                    let instId = updated[i].container.instanceIdForApi
                    let jid = updated[i].chat.jid ?? ""
                    let serverCount = unreadByInstance[instId]?[jid] ?? 0
                    let current = updated[i].chat.newMessageCount ?? 0
                    if serverCount > current {
                        updated[i].chat.newMessageCount = serverCount
                        staleInstances.insert(instId)
                    }
                }
                // 服务端出现了本地尚未存在的未读会话，也需要补拉预览
                for (instId, map) in unreadByInstance {
                    if map.contains(where: { (jid, count) in
                        guard count > 0 else { return false }
                        return existingCountsByConv["\(instId)_\(jid)"] == nil
                    }) {
                        staleInstances.insert(instId)
                    }
                    // 后台 APNS 回前台场景：即使计数未变，只要该实例存在未读，也需要补拉最新预览。
                    if map.values.contains(where: { $0 > 0 }) {
                        staleInstances.insert(instId)
                    }
                }
                aggregatedItems = updated
                stalePreviewInstanceIDs.formUnion(staleInstances)
                sortAggregatedItemsByRealtime()
            }
        } catch {
            // 静默失败：不影响列表展示
        }
    }
    
    /// 静默增量刷新预览：仅更新成功实例的会话摘要，不阻塞页面，不打断当前列表
    private func refreshChatPreviewsIncrementalSilently(prioritizedInstanceIDs: [String], fallbackAllRunningWhenEmpty: Bool) async {
        guard appState.canFetchInstanceChatLists else { return }
        var targets = Array(Set(prioritizedInstanceIDs.filter { !$0.isEmpty }))
        if targets.isEmpty && fallbackAllRunningWhenEmpty {
            targets = containersToLoad.map(\.instanceIdForApi)
        }
        guard !targets.isEmpty else { return }
        
        let containerById = containersToLoad.reduce(into: [String: Instance]()) { acc, c in
            let key = c.instanceIdForApi
            if acc[key] == nil { acc[key] = c }
        }
        var successMap: [String: [Chat]] = [:]
        
        var start = 0
        while start < targets.count {
            let end = min(start + fullBatchSize, targets.count)
            let batch = Array(targets[start..<end])
            start = end
            
            let batchResults: [(instanceId: String, chats: [Chat]?)] = await withTaskGroup(of: (String, [Chat]?).self) { group in
                for instanceId in batch {
                    group.addTask {
                        guard let c = containerById[instanceId], let boxIP = c.boxIP, !boxIP.isEmpty else {
                            return (instanceId, nil)
                        }
                        do {
                            let chats = try await fetchChatsWithTimeout(instanceId: instanceId, boxIP: boxIP, timeout: fullFetchTimeout)
                            let withLocalAvatar = await mergeServerChatsPreservingLocalAvatar(instanceId: instanceId, serverChats: chats)
                            let mergedChats = await mergeServerChatsWithPending(instanceId: instanceId, serverChats: withLocalAvatar)
                            await AppCacheStore.shared.saveChats(instanceId: instanceId, chats: mergedChats)
                            Task.detached(priority: .utility) {
                                await AllChatsMessageWarmupService.shared.warmup(instanceId: instanceId, boxIP: boxIP, chats: mergedChats)
                            }
                            return (instanceId, mergedChats)
                        } catch {
                            return (instanceId, nil)
                        }
                    }
                }
                var arr: [(String, [Chat]?)] = []
                for await item in group { arr.append(item) }
                return arr
            }
            
            for r in batchResults {
                if let chats = r.chats {
                    successMap[r.instanceId] = chats
                }
            }
        }
        
        guard !successMap.isEmpty else { return }
        await MainActor.run {
            var map: [String: AggregatedChatItem] = [:]
            for item in aggregatedItems {
                map[conversationKey(for: item)] = item
            }
            for (instanceId, chats) in successMap {
                guard let container = containerById[instanceId] else { continue }
                for chat in chats {
                    let key = "\(instanceId)_\(chat.jid ?? "")"
                    map[key] = AggregatedChatItem(container: container, chat: chat)
                }
                stalePreviewInstanceIDs.remove(instanceId)
            }
            aggregatedItems = Array(map.values)
            sortAggregatedItemsByRealtime()
        }
    }
    
    /// 从联系人接口回填 remark_name（按 instance+jid 建 key），保证全部对话与聊天页昵称优先级一致
    private func refreshContactRemarksForCurrentConversations() async {
        let items = aggregatedItems
        guard !items.isEmpty else { return }
        
        let containers = Array(Dictionary(grouping: items, by: { $0.container.instanceIdForApi }).values.compactMap { $0.first?.container })
        var next: [String: String] = [:]
        
        await withTaskGroup(of: [String: String].self) { group in
            for container in containers {
                group.addTask {
                    guard let boxIP = container.boxIP, !boxIP.isEmpty else { return [:] }
                    let instanceId = container.instanceIdForApi
                    do {
                        let contacts = try await ChatService.shared.getContacts(instanceId: instanceId, boxIP: boxIP)
                        var local: [String: String] = [:]
                        for c in contacts {
                            let jid = (c.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let remark = (c.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !jid.isEmpty, !remark.isEmpty {
                                local["\(instanceId)_\(jid)"] = remark
                            }
                        }
                        return local
                    } catch {
                        return [:]
                    }
                }
            }
            for await m in group {
                next.merge(m, uniquingKeysWith: { _, new in new })
            }
        }
        
        await MainActor.run {
            contactRemarkByConversation = next
        }
    }
    
    private func syncContainerMetaIntoAggregatedItems() {
        guard !aggregatedItems.isEmpty else { return }
        let latestByInstance = appState.accountInstances.reduce(into: [String: Instance]()) { acc, inst in
            let key = instanceUniqueKey(inst)
            if !key.isEmpty { acc[key] = inst }
        }
        guard !latestByInstance.isEmpty else { return }
        var changed = false
        var next = aggregatedItems
        for i in next.indices {
            let key = instanceUniqueKey(next[i].container)
            guard let latest = latestByInstance[key] else { continue }
            if latest.scrmRemark != next[i].container.scrmRemark || latest.name != next[i].container.name {
                next[i] = AggregatedChatItem(container: latest, chat: next[i].chat)
                changed = true
            }
        }
        if changed {
            aggregatedItems = next
            sortAggregatedItemsByRealtime()
        }
    }
    
    private enum ChatFetchTimeoutError: Error { case timeout }
    
    private func mergeServerChatsWithPending(instanceId: String, serverChats: [Chat]) async -> [Chat] {
        let pending = await AppCacheStore.shared.loadPendingConversations(instanceId: instanceId, maxAge: nil)
        guard !pending.isEmpty else { return serverChats }
        var merged = serverChats
        for p in pending {
            let jid = (p.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty else { continue }
            if merged.contains(where: { ($0.jid ?? "") == jid }) {
                await AppCacheStore.shared.removePendingConversation(instanceId: instanceId, jid: jid)
            } else {
                merged.insert(p, at: 0)
            }
        }
        return merged
    }
    
    /// 全量/增量拉取会话时保留本地展示字段，避免“备注闪回手机号”和头像回滚。
    private func mergeServerChatsPreservingLocalAvatar(instanceId: String, serverChats: [Chat]) async -> [Chat] {
        let local = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
        guard !local.isEmpty else { return serverChats }
        
        let localByJid: [String: Chat] = local.reduce(into: [:]) { acc, item in
            let jid = (item.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !jid.isEmpty { acc[jid] = item }
        }
        if localByJid.isEmpty { return serverChats }
        
        var merged = serverChats
        for i in merged.indices {
            let jid = (merged[i].jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty, let localChat = localByJid[jid] else { continue }
            let localAvatar = (localChat.avatar ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteAvatar = (merged[i].avatar ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if remoteAvatar.isEmpty, !localAvatar.isEmpty {
                merged[i].avatar = localChat.avatar
            } else if !localAvatar.isEmpty {
                // 用户手动刷头像后，本地可能比服务端列表更新更快，优先本地展示。
                merged[i].avatar = localChat.avatar
            }
            let remoteRemark = (merged[i].remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localRemark = (localChat.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if remoteRemark.isEmpty, !localRemark.isEmpty {
                merged[i].remark_name = localChat.remark_name
            }
            let remoteName = (merged[i].display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localName = (localChat.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if remoteName.isEmpty, !localName.isEmpty {
                merged[i].display_name = localChat.display_name
            }
            let remotePhone = (merged[i].phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localPhone = (localChat.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if remotePhone.isEmpty, !localPhone.isEmpty {
                merged[i].phone = localChat.phone
            }
        }
        return merged
    }
    
    private func mergedChatsByJid(primary: [Chat], overlay: [Chat]) -> [Chat] {
        guard !overlay.isEmpty else { return primary }
        var result = primary
        for item in overlay {
            let jid = (item.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty else { continue }
            if !result.contains(where: { ($0.jid ?? "") == jid }) {
                result.insert(item, at: 0)
            }
        }
        return result
    }
    
    private func fetchChatsWithTimeout(instanceId: String, boxIP: String, timeout: TimeInterval) async throws -> [Chat] {
        try await withThrowingTaskGroup(of: [Chat].self) { group in
            group.addTask {
                try await ChatService.shared.getChats(instanceId: instanceId, boxIP: boxIP)
            }
            group.addTask {
                let ns = UInt64(max(1, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw ChatFetchTimeoutError.timeout
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()
            return first
        }
    }

}

private struct AggregatedChatItem: Identifiable {
    let container: Instance
    var chat: Chat
    var id: String { "\(container.instanceIdForApi)_\(chat.jid ?? "")" }
}

private actor AllChatsMessageWarmupService {
    static let shared = AllChatsMessageWarmupService()

    private var inFlightThreads: Set<String> = []
    private var warmedAtByThread: [String: TimeInterval] = [:]
    private var nextSortIdByThread: [String: Int] = [:]
    private var noMoreHistoryThreads: Set<String> = []
    private let warmupCooldown: TimeInterval = 30 * 60
    private let cursorWarmupCooldown: TimeInterval = 120
    private let maxChatsPerInstance = 40
    private let maxConcurrentFetch = 4
    private let pageSize = 40
    private let maxPagesPerRun = 2

    func warmup(instanceId: String, boxIP: String, chats: [Chat]) async {
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBoxIP = boxIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty, !cleanBoxIP.isEmpty else { return }

        let sorted = chats
            .sorted { ($0.last_message?.timestamp ?? 0) > ($1.last_message?.timestamp ?? 0) }
            .prefix(maxChatsPerInstance)

        var targets: [Int] = []
        let now = Date().timeIntervalSince1970
        for chat in sorted {
            let rowID = chat.chat_row_id ?? 0
            guard rowID > 0 else { continue }
            let threadKey = "\(cleanInstanceId)|\(rowID)"
            if inFlightThreads.contains(threadKey) { continue }
            let cooldown = nextSortIdByThread[threadKey] != nil ? cursorWarmupCooldown : warmupCooldown
            if let last = warmedAtByThread[threadKey], now - last < cooldown { continue }
            inFlightThreads.insert(threadKey)
            targets.append(rowID)
        }
        guard !targets.isEmpty else { return }

        var start = 0
        while start < targets.count {
            let end = min(start + maxConcurrentFetch, targets.count)
            let batch = Array(targets[start..<end])
            start = end

            await withTaskGroup(of: (Int, Bool).self) { group in
                for rowID in batch {
                    group.addTask {
                        return await self.warmupThread(
                            instanceId: cleanInstanceId,
                            boxIP: cleanBoxIP,
                            chatRowId: rowID
                        )
                    }
                }

                for await (rowID, ok) in group {
                    let threadKey = "\(cleanInstanceId)|\(rowID)"
                    inFlightThreads.remove(threadKey)
                    if ok {
                        warmedAtByThread[threadKey] = Date().timeIntervalSince1970
                    }
                }
            }
        }
    }

    private func warmupThread(instanceId: String, boxIP: String, chatRowId: Int) async -> (Int, Bool) {
        let threadKey = "\(instanceId)|\(chatRowId)"
        var merged = (await AppCacheStore.shared.loadMessages(instanceId: instanceId, chatRowId: chatRowId, maxAge: nil) ?? [])
        var changed = false
        var success = true
        var pagesFetched = 0

        // 首次会话未落库：先拉最新一页（sort_id=0）
        if merged.isEmpty {
            do {
                let latest = try await ChatService.shared.getMessages(
                    chatRowId: chatRowId,
                    instanceId: instanceId,
                    boxIP: boxIP,
                    page: 1,
                    pageSize: pageSize,
                    sortId: 0
                )
                if !latest.isEmpty {
                    merged = mergeMessages(existing: merged, incoming: latest)
                    changed = true
                    pagesFetched += 1
                }
                if latest.count < pageSize {
                    noMoreHistoryThreads.insert(threadKey)
                    nextSortIdByThread.removeValue(forKey: threadKey)
                }
            } catch {
                success = false
            }
        }

        if success, !merged.isEmpty {
            var cursor = nextSortIdByThread[threadKey] ?? oldestMessageID(in: merged)
            while pagesFetched < maxPagesPerRun,
                  cursor > 0,
                  !noMoreHistoryThreads.contains(threadKey) {
                do {
                    let older = try await ChatService.shared.getMessages(
                        chatRowId: chatRowId,
                        instanceId: instanceId,
                        boxIP: boxIP,
                        page: 1,
                        pageSize: pageSize,
                        sortId: cursor
                    )
                    if older.isEmpty {
                        noMoreHistoryThreads.insert(threadKey)
                        nextSortIdByThread.removeValue(forKey: threadKey)
                        break
                    }
                    let beforeOldest = oldestMessageID(in: merged)
                    merged = mergeMessages(existing: merged, incoming: older)
                    let afterOldest = oldestMessageID(in: merged)
                    changed = true
                    pagesFetched += 1

                    let progressed = afterOldest > 0 && (beforeOldest == 0 || afterOldest < beforeOldest)
                    if older.count < pageSize || !progressed {
                        noMoreHistoryThreads.insert(threadKey)
                        nextSortIdByThread.removeValue(forKey: threadKey)
                        break
                    }
                    cursor = afterOldest
                    nextSortIdByThread[threadKey] = cursor
                } catch {
                    success = false
                    break
                }
            }
        }

        if changed {
            await AppCacheStore.shared.saveMessages(instanceId: instanceId, chatRowId: chatRowId, messages: merged)
        }

        if noMoreHistoryThreads.contains(threadKey) {
            nextSortIdByThread.removeValue(forKey: threadKey)
        } else {
            let oldest = oldestMessageID(in: merged)
            if oldest > 0 {
            nextSortIdByThread[threadKey] = oldest
            }
        }

        return (chatRowId, success)
    }

    private func oldestMessageID(in messages: [Message]) -> Int {
        messages.compactMap(\.message_id).filter { $0 > 0 }.min() ?? 0
    }

    private func mergeMessages(existing: [Message], incoming: [Message], keepLast: Int = 1200) -> [Message] {
        var map: [String: Message] = [:]
        for msg in existing {
            map[messageIdentity(msg)] = msg
        }
        for msg in incoming {
            map[messageIdentity(msg)] = msg
        }
        let sorted = map.values.sorted { lhs, rhs in
            let lts = lhs.timestamp ?? 0
            let rts = rhs.timestamp ?? 0
            if lts != rts { return lts < rts }
            return (lhs.message_id ?? Int.max) < (rhs.message_id ?? Int.max)
        }
        if sorted.count > keepLast {
            return Array(sorted.suffix(keepLast))
        }
        return sorted
    }

    private func messageIdentity(_ msg: Message) -> String {
        if let key = msg.key_id?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return "k:\(key)" }
        if let id = msg.message_id, id > 0 { return "m:\(id)" }
        let ts = msg.timestamp ?? 0
        let text = (msg.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "f:\(ts)|\(text)"
    }
}

#Preview {
    ChatListPlaceholderView(appState: AppState())
}
