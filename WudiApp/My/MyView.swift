//
//  MyView.swift
//  WudiApp
//
//  参考 H5 MyPage.vue：用户卡片（头像、昵称）、菜单列表、版本号
//

import SwiftUI
import UIKit

// MARK: - 消息审核：云机名 / 用户展示（与账号页 formatInstanceName 一致）
private func chatReviewCloudDisplayName(item: ChatReviewRecord, instances: [Instance]) -> String {
    let raw = (item.containerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty {
        return formatInstanceName(raw)
    }
    let key = (item.instanceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return "-" }
    if let inst = instances.first(where: { inst in
        inst.syncMatchKeys.contains(key) || inst.instanceIdForApi == key || "\(inst.ID ?? 0)" == key
    }) {
        return formatInstanceName(inst.scrmRemark ?? inst.name)
    }
    return key
}

private func chatReviewCopyToPasteboard(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    UIPasteboard.general.string = trimmed
}

private func chatReviewUserDisplayValue(item: ChatReviewRecord) -> String {
    let submitter = (item.submitterUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !submitter.isEmpty { return submitter }
    let nick = (item.nickName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !nick.isEmpty { return nick }
    let un = (item.userName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !un.isEmpty { return un }
    if let uid = item.userID { return "\(uid)" }
    return "-"
}

// MARK: - 消息审核：固定比例缩略图 + 全屏原图（缩放）
private struct ReviewFullscreenImageViewer: View {
    let url: URL
    @Binding var isPresented: Bool
    /// 缩放手势过程中的显示倍率
    @State private var scale: CGFloat = 1
    /// 手势结束后的稳定倍率（下一手势以此为基准）
    @State private var steadyScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { magnify in
                                    scale = min(4, max(1, steadyScale * magnify))
                                }
                                .onEnded { _ in
                                    steadyScale = min(4, max(1, scale))
                                    scale = steadyScale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                if scale > 1.05 {
                                    scale = 1
                                    steadyScale = 1
                                } else {
                                    scale = 2.25
                                    steadyScale = 2.25
                                }
                            }
                        }
                case .failure:
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                        Text("图片加载失败")
                            .font(.system(size: 15))
                    }
                    .foregroundColor(.white.opacity(0.9))
                default:
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
            .padding(20)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
    }
}

/// 审核图片预览：固定 16:9 裁切，点击全屏查看原图（可缩放）
private struct ReviewChatImageThumbnailView: View {
    let url: URL
    var showTapHint: Bool = true
    /// 宽:高
    private let aspect: CGFloat = 16 / 9

    @State private var showViewer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showViewer = true
            } label: {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure:
                                ZStack {
                                    Color(white: 0.92)
                                    Image(systemName: "photo")
                                        .font(.system(size: 28))
                                        .foregroundColor(.secondary)
                                }
                            default:
                                ZStack {
                                    Color(white: 0.94)
                                    ProgressView()
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            if showTapHint {
                Text("点击查看原图 · 双指或双击缩放")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            ReviewFullscreenImageViewer(url: url, isPresented: $showViewer)
        }
    }
}

struct MyView: View {
    @ObservedObject var appState: AppState
    @State private var showChangePassword: Bool = false
    @State private var showMessageReview: Bool = false
    @State private var showUserManagement: Bool = false
    @State private var showDeviceAssignment: Bool = false
    @State private var showSettings: Bool = false
    @State private var showLogoutAlert: Bool = false
    
    private let gradientStart = Color(red: 0.09, green: 0.47, blue: 1.0)
    private let gradientEnd = Color(red: 0.25, green: 0.59, blue: 1.0)
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 用户卡片（与 H5 user-card 一致：渐变蓝底、头像、昵称、右上角消息按钮）
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 12) {
                        // 头像
                        if let urlString = appState.userHeaderImgURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    defaultAvatarView
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                        } else {
                            defaultAvatarView
                        }
                        Text(appState.userNickName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 28)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [gradientStart, gradientEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    
                    Button(action: goToService) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Circle())
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }
                
                // 菜单列表（与 H5 menu-list 一致）
                VStack(spacing: 0) {
                    MenuRow(icon: "key", title: "更改密码", isDanger: false) {
                        showChangePassword = true
                    }
                    MenuRow(icon: "headphones", title: "联系客服", isDanger: false) {
                        goToService()
                    }
                    if appState.hasChatReviewPermission {
                        MenuRow(
                            icon: "doc.text.magnifyingglass",
                            title: "消息审核",
                            isDanger: false,
                            badgeCount: appState.chatReviewPendingCount
                        ) {
                            showMessageReview = true
                        }
                    }
                    MenuRow(icon: "person.3", title: "用户管理", isDanger: false) {
                        showUserManagement = true
                    }
                    if appState.allowsAssignDeviceByMenu {
                        MenuRow(icon: "checklist.checked", title: "分配设备", isDanger: false) {
                            showDeviceAssignment = true
                        }
                    }
                    MenuRow(icon: "gearshape", title: "设置", isDanger: false) {
                        showSettings = true
                    }
                    MenuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录", isDanger: true) {
                        showLogoutAlert = true
                    }
                }
                .background(Color.white)
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                // 版本信息（与 H5 version-info 一致）
                Text("v\(appVersionText)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.6))
                    .padding(.top, 24)
                
                Spacer(minLength: 100)
            }
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
        .onAppear {
            Task { await appState.refreshChatReviewPendingCount() }
        }
        .onChange(of: showMessageReview) { opened in
            if !opened {
                Task { await appState.refreshChatReviewPendingCount() }
            }
        }
        .alert("提示", isPresented: $showLogoutAlert) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {
                Task {
                    await AuthService.shared.addTokenToBlacklist()
                    await MainActor.run { appState.logout() }
                }
            }
        } message: {
            Text("确定要退出登录吗？")
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet(isPresented: $showChangePassword) {
                Task {
                    await AuthService.shared.addTokenToBlacklist()
                    await MainActor.run { appState.logout() }
                }
            }
        }
        .sheet(isPresented: $showMessageReview) {
            MessageReviewSheet(isPresented: $showMessageReview, appState: appState)
        }
        .sheet(isPresented: $showUserManagement) {
            UserManagementSheet(isPresented: $showUserManagement, appState: appState)
        }
        .sheet(isPresented: $showDeviceAssignment) {
            DeviceAssignmentSheet(isPresented: $showDeviceAssignment, appState: appState)
        }
        .sheet(isPresented: $showSettings) {
            SettingsPlaceholderSheet(isPresented: $showSettings, appState: appState)
        }
    }
    
    private var defaultAvatarView: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 72, height: 72)
            Image(systemName: "person")
                .font(.system(size: 32))
                .foregroundColor(.white)
        }
    }
    
    private func goToService() {
        // 后续跳转客服页
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return "0.0.0"
    }
    
}

private struct MessageReviewSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState

    private enum ReviewFilter: String, CaseIterable, Identifiable {
        case pending
        case approved
        case rejected

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pending: return "待审核"
            case .approved: return "已通过"
            case .rejected: return "已拒绝"
            }
        }
    }

    private enum ReviewAction {
        case approve
        case reject

        var title: String {
            switch self {
            case .approve: return "审核通过"
            case .reject: return "审核拒绝"
            }
        }

        var tint: Color {
            switch self {
            case .approve: return .green
            case .reject: return .red
            }
        }
    }

    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var items: [ChatReviewRecord] = []
    /// 服务端 total，用于判断是否还有下一页
    @State private var listTotal: Int = 0
    @State private var currentPage: Int = 1
    @State private var selectedFilter: ReviewFilter = .pending
    @State private var actionTarget: ChatReviewRecord?
    @State private var actionType: ReviewAction?
    @State private var reviewNote: String = ""
    @State private var submitting = false

    private let reviewListPageSize = 10

    private var hasMorePages: Bool {
        listTotal > 0 && items.count < listTotal
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("审核状态", selection: $selectedFilter) {
                    ForEach(ReviewFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if loading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, !errorMessage.isEmpty {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await fetchReviewPage(reset: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text("暂无审核记录")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ReviewRecordCard(
                                item: item,
                                instances: appState.accountInstances,
                                onApprove: {
                                    actionTarget = item
                                    actionType = .approve
                                    reviewNote = ""
                                },
                                onReject: {
                                    actionTarget = item
                                    actionType = .reject
                                    reviewNote = ""
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                guard index == items.count - 1, hasMorePages, !loadingMore, !loading else { return }
                                Task { await fetchReviewPage(reset: false) }
                            }
                        }
                        if loadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.vertical, 12)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                }
            }
            .navigationTitle("消息审核")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("刷新") {
                        Task { await fetchReviewPage(reset: true) }
                    }
                    .disabled(loading || loadingMore || submitting)
                }
            }
        }
        .task {
            await fetchReviewPage(reset: true)
        }
        .onChange(of: appState.chatReviewListRefreshToken) { _ in
            Task { await fetchReviewPage(reset: true) }
        }
        .onChange(of: selectedFilter) { _ in
            Task { await fetchReviewPage(reset: true) }
        }
        .sheet(isPresented: Binding(
            get: { actionTarget != nil && actionType != nil },
            set: { showing in
                if !showing {
                    actionTarget = nil
                    actionType = nil
                    reviewNote = ""
                }
            }
        )) {
            if let actionTarget, let actionType {
                ReviewActionSheet(
                    title: actionType.title,
                    tint: actionType.tint,
                    target: actionTarget,
                    instances: appState.accountInstances,
                    note: $reviewNote,
                    submitting: submitting,
                    onCancel: {
                        self.actionTarget = nil
                        self.actionType = nil
                        self.reviewNote = ""
                    },
                    onConfirm: {
                        Task { await submitReviewAction(for: actionTarget, action: actionType) }
                    }
                )
            }
        }
    }

    private func submitReviewAction(for item: ChatReviewRecord, action: ReviewAction) async {
        await MainActor.run { submitting = true }
        defer { Task { @MainActor in submitting = false } }
        do {
            switch action {
            case .approve:
                try await AuthService.shared.approveChatReview(id: item.id, reviewNote: reviewNote.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run {
                    appState.presentUserFeedback("审核通过成功", level: .success)
                }
            case .reject:
                try await AuthService.shared.rejectChatReview(id: item.id, reviewNote: reviewNote.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run {
                    appState.presentUserFeedback("审核拒绝成功", level: .success)
                }
            }
            await MainActor.run {
                actionTarget = nil
                actionType = nil
                reviewNote = ""
            }
            await fetchReviewPage(reset: true)
        } catch {
            await MainActor.run {
                appState.presentUserFeedback(error.localizedDescription, level: .error)
            }
        }
    }

    /// `reset: true` 时从第一页重拉；`false` 时请求下一页并追加（滚动加载）。
    private func fetchReviewPage(reset: Bool) async {
        if reset {
            await MainActor.run {
                loading = true
                errorMessage = nil
            }
        } else {
            let shouldProceed = await MainActor.run { () -> Bool in
                guard hasMorePages, !loadingMore, !loading else { return false }
                loadingMore = true
                return true
            }
            guard shouldProceed else { return }
        }

        let pageToLoad = await MainActor.run { reset ? 1 : currentPage + 1 }

        defer {
            Task { @MainActor in
                loading = false
                loadingMore = false
            }
        }

        do {
            let result = try await AuthService.shared.getChatReviewList(
                page: pageToLoad,
                pageSize: reviewListPageSize,
                reviewStatus: selectedFilter.rawValue,
                userID: nil
            )
            await MainActor.run {
                if reset {
                    items = result.list
                    currentPage = pageToLoad
                    listTotal = max(0, result.total)
                } else if result.list.isEmpty {
                    // 避免 total 与分页不一致时反复请求空页
                    listTotal = items.count
                } else {
                    let existing = Set(items.map(\.id))
                    let appended = result.list.filter { !existing.contains($0.id) }
                    items.append(contentsOf: appended)
                    currentPage = pageToLoad
                    listTotal = max(0, result.total)
                }
                errorMessage = nil
                if selectedFilter == .pending {
                    appState.applyChatReviewPendingTotalFromListFetch(total: result.total)
                }
            }
        } catch {
            await MainActor.run {
                if reset {
                    items = []
                    listTotal = 0
                    currentPage = 1
                    errorMessage = error.localizedDescription
                } else {
                    appState.presentUserFeedback(error.localizedDescription, level: .error)
                }
            }
        }
    }
}

private struct ReviewRecordCard: View {
    let item: ChatReviewRecord
    let instances: [Instance]
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            reviewLabeledRow(title: "云机名称", value: chatReviewCloudDisplayName(item: item, instances: instances))
            reviewLabeledRow(title: "用户", value: chatReviewUserDisplayValue(item: item))

            if let reasons = parsedReasons, !reasons.isEmpty {
                reviewLabeledRow(title: "审核原因", value: reasons.joined(separator: "、"))
            }

            let textContent = (item.chatText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !textContent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("文本内容：")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(white: 0.32))
                        Spacer(minLength: 8)
                        Button {
                            chatReviewCopyToPasteboard(textContent)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("复制")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        }
                        .buttonStyle(.plain)
                    }
                    Text(textContent)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let imageURL = item.imageURL, !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: imageURL) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("图片内容：")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(white: 0.32))
                    ReviewChatImageThumbnailView(url: url, showTapHint: true)
                }
            }

            if textContent.isEmpty,
               (item.imageURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reviewLabeledRow(title: "文本内容", value: "（无文本与图片）")
            }

            if let note = item.reviewNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                reviewLabeledRow(title: "审核备注", value: note)
            }

            HStack {
                Text(shortTaskText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(item.createdAt ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if (item.reviewStatus ?? "") == "pending" {
                HStack(spacing: 10) {
                    Button("通过", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("拒绝", action: onReject)
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func reviewLabeledRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(title)：")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(white: 0.32))
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortTaskText: String {
        let task = (item.taskUUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if task.isEmpty { return "ID: \(item.id)" }
        return "任务ID：\(task)"
    }

    private var statusTitle: String {
        switch item.reviewStatus {
        case "approved": return "已通过"
        case "rejected": return "已拒绝"
        default: return "待审核"
        }
    }

    private var statusColor: Color {
        switch item.reviewStatus {
        case "approved": return .green
        case "rejected": return .red
        default: return .orange
        }
    }

    private var parsedReasons: [String]? {
        guard let raw = item.reviewReasons?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return decoded
    }
}

private struct ReviewActionSheet: View {
    let title: String
    let tint: Color
    let target: ChatReviewRecord
    let instances: [Instance]
    @Binding var note: String
    let submitting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    reviewFormField(title: "云机名称", value: chatReviewCloudDisplayName(item: target, instances: instances))
                    reviewFormField(title: "用户", value: chatReviewUserDisplayValue(item: target))
                    if let reasons = parsedReasons, !reasons.isEmpty {
                        reviewFormField(title: "审核原因", value: reasons.joined(separator: "、"))
                    }
                } header: {
                    Text("待审核内容")
                }
                if !textContent.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Spacer(minLength: 0)
                                Button {
                                    chatReviewCopyToPasteboard(textContent)
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                        .font(.system(size: 14, weight: .medium))
                                }
                            }
                            Text(textContent)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("文本内容")
                    }
                }
                if let imageURL = target.imageURL, !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let url = URL(string: imageURL) {
                    Section("图片内容") {
                        ReviewChatImageThumbnailView(url: url, showTapHint: true)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }
                Section("审核备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "提交中..." : "确定", action: onConfirm)
                        .disabled(submitting)
                        .tint(tint)
                }
            }
        }
    }

    private func reviewFormField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title)：")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.4))
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textContent: String {
        (target.chatText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedReasons: [String]? {
        guard let raw = target.reviewReasons?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return decoded
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    let isDanger: Bool
    var badgeCount: Int = 0
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isDanger ? Color(red: 1, green: 0.3, blue: 0.31) : Color(white: 0.4))
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(isDanger ? Color(red: 1, green: 0.3, blue: 0.31) : Color(white: 0.2))
                Spacer()
                if badgeCount > 0 {
                    Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, badgeCount > 9 ? 6 : 5)
                        .padding(.vertical, 3)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.73))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct ChangePasswordSheet: View {
    @Binding var isPresented: Bool
    let onSuccess: () -> Void
    
    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                SecureField("请输入原密码", text: $oldPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("请输入新密码（至少6位）", text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("请再次输入新密码", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                if let msg = errorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let ok = successMessage, !ok.isEmpty {
                    Text(ok)
                        .font(.caption)
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("更改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLoading ? "提交中..." : "确定") {
                        submit()
                    }
                    .disabled(isLoading)
                }
            }
        }
    }
    
    private func submit() {
        let oldPwd = oldPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPwd = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmPwd = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldPwd.isEmpty else { errorMessage = "请输入原密码"; return }
        guard newPwd.count >= 6 else { errorMessage = "新密码至少6位"; return }
        guard newPwd == confirmPwd else { errorMessage = "两次输入的新密码不一致"; return }
        isLoading = true
        errorMessage = nil
        successMessage = nil
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                try await AuthService.shared.changePassword(oldPassword: oldPwd, newPassword: newPwd)
                await MainActor.run {
                    successMessage = "密码修改成功，请重新登录"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        isPresented = false
                        onSuccess()
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct UserManagementSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState
    
    @State private var username: String = ""
    @State private var page: Int = 1
    @State private var pageSize: Int = 10
    @State private var total: Int = 0
    @State private var loading: Bool = false
    @State private var list: [UserListItem] = []
    @State private var pendingDeleteUser: UserListItem?
    @State private var showAddUserSheet: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                    Button("搜索") {
                        page = 1
                        Task { await fetchList() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                if loading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if list.isEmpty {
                    Text("暂无用户")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(list) { user in
                                userRow(user)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                
                HStack {
                    Text("共 \(total) 条")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("上一页") {
                        guard page > 1 else { return }
                        page -= 1
                        Task { await fetchList() }
                    }
                    .disabled(page <= 1 || loading)
                    Text("\(page)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("下一页") {
                        guard page * pageSize < max(total, 1) else { return }
                        page += 1
                        Task { await fetchList() }
                    }
                    .disabled(page * pageSize >= max(total, 1) || loading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .navigationTitle("用户管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加用户") { showAddUserSheet = true }
                }
            }
            .onAppear { Task { await fetchList() } }
            .sheet(isPresented: $showAddUserSheet) {
                AddUserSheet(
                    isPresented: $showAddUserSheet,
                    appState: appState,
                    onCreated: { Task { await fetchList() } }
                )
            }
            .alert("删除确认", isPresented: Binding(get: { pendingDeleteUser != nil }, set: { if !$0 { pendingDeleteUser = nil } })) {
                Button("取消", role: .cancel) { pendingDeleteUser = nil }
                Button("删除", role: .destructive) {
                    if let user = pendingDeleteUser {
                        Task { await deleteUser(user) }
                    }
                    pendingDeleteUser = nil
                }
            } message: {
                Text("确定要删除该用户吗？")
            }
        }
    }
    
    private func userRow(_ user: UserListItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(user.userName ?? "-")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text((user.enable ?? 0) == 1 ? "启用" : "禁用")
                    .font(.caption)
                    .foregroundColor((user.enable ?? 0) == 1 ? .green : .gray)
            }
            Text("角色：\(user.authority?.authorityName ?? "-")")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button((user.enable ?? 0) == 1 ? "停用" : "启用") {
                    Task { await toggleEnable(user) }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint((user.enable ?? 0) == 1 ? .orange : .blue)
                
                Button("删除", role: .destructive) {
                    pendingDeleteUser = user
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(8)
    }
    
    private func fetchList() async {
        await MainActor.run { loading = true }
        defer { Task { @MainActor in loading = false } }
        do {
            let res = try await AuthService.shared.getUserList(page: page, pageSize: pageSize, username: username.trimmingCharacters(in: .whitespacesAndNewlines))
            await MainActor.run {
                list = res.list
                total = res.total
            }
        } catch {
            await MainActor.run { showToast(error.localizedDescription) }
        }
    }
    
    private func toggleEnable(_ user: UserListItem) async {
        let target = (user.enable ?? 0) == 1 ? 2 : 1
        do {
            try await AuthService.shared.setUserEnable(user: user, enable: target)
            await MainActor.run { showToast(target == 1 ? "已启用" : "已停用") }
            await fetchList()
        } catch {
            await MainActor.run { showToast(error.localizedDescription) }
        }
    }
    
    private func deleteUser(_ user: UserListItem) async {
        do {
            try await AuthService.shared.deleteUser(id: user.userId)
            await MainActor.run { showToast("删除成功") }
            await fetchList()
        } catch {
            await MainActor.run { showToast(error.localizedDescription) }
        }
    }
    
    private func showToast(_ message: String) {
        let lower = message.lowercased()
        let isError = message.contains("失败")
            || message.contains("错误")
            || lower.contains("error")
            || lower.contains("failed")
        appState.presentUserFeedback(message, level: isError ? .error : .success)
    }
}

private struct AddUserSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState
    let onCreated: () -> Void

    private struct AuthorityOption: Identifiable {
        let id: Int
        let name: String
        let path: String
        var label: String { "\(path) (\(id))" }
    }

    @State private var loading = false
    @State private var saving = false
    @State private var authorityOptions: [AuthorityOption] = []
    @State private var userName = ""
    @State private var passWord = ""
    @State private var nickName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var selectedAuthorityId: Int?
    @State private var formError: String?

    var body: some View {
        NavigationView {
            Form {
                Section("基础信息") {
                    TextField("用户名", text: $userName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    SecureField("密码", text: $passWord)
                    TextField("昵称", text: $nickName)
                    TextField("手机号（可选）", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("邮箱（可选）", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section("角色") {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("加载角色列表中...")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("选择角色", selection: $selectedAuthorityId) {
                            Text("请选择角色").tag(nil as Int?)
                            ForEach(authorityOptions) { item in
                                Text(item.label).tag(Optional(item.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if let err = formError, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("添加用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "创建中..." : "创建") {
                        Task { await submit() }
                    }
                    .disabled(saving || loading)
                }
            }
            .task { await loadAuthorities() }
        }
    }

    private func loadAuthorities() async {
        await MainActor.run {
            loading = true
            formError = nil
        }
        defer { Task { @MainActor in loading = false } }
        do {
            let tree = try await AuthService.shared.getAuthorityList()
            let options = flattenAuthorityTree(tree)
            await MainActor.run {
                authorityOptions = options
                if selectedAuthorityId == nil {
                    selectedAuthorityId = options.first?.id
                }
            }
        } catch {
            await MainActor.run {
                formError = error.localizedDescription
            }
        }
    }

    private func flattenAuthorityTree(_ nodes: [AuthorityNode], prefix: String = "") -> [AuthorityOption] {
        var result: [AuthorityOption] = []
        for node in nodes {
            let cleanName = node.authorityName.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = prefix.isEmpty ? cleanName : "\(prefix) / \(cleanName)"
            result.append(AuthorityOption(id: node.authorityId, name: cleanName, path: current))
            let children = node.children ?? []
            if !children.isEmpty {
                result.append(contentsOf: flattenAuthorityTree(children, prefix: current))
            }
        }
        return result
    }

    private func submit() async {
        let username = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = nickName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneValue = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailValue = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty, !nickname.isEmpty else {
            await MainActor.run { formError = "请填写用户名、密码、昵称" }
            return
        }
        guard let authorityId = selectedAuthorityId else {
            await MainActor.run { formError = "请选择角色" }
            return
        }

        await MainActor.run {
            saving = true
            formError = nil
        }
        defer { Task { @MainActor in saving = false } }

        do {
            try await AuthService.shared.adminRegister(
                userName: username,
                passWord: password,
                nickName: nickname,
                authorityId: authorityId,
                phone: phoneValue,
                email: emailValue
            )
            await MainActor.run {
                appState.presentUserFeedback("用户创建成功", level: .success)
                isPresented = false
                onCreated()
            }
        } catch {
            await MainActor.run {
                formError = error.localizedDescription
                appState.presentUserFeedback(error.localizedDescription, level: .error)
            }
        }
    }
}

private struct DeviceAssignmentSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState
    
    private struct BoxNode: Identifiable {
        let box: Box
        let instances: [Instance]
        var id: String { box.boxIP }
    }
    
    @State private var loading = false
    @State private var loadingAssigned = false
    @State private var saving = false
    @State private var users: [AssignableUser] = []
    @State private var selectedUserId: Int?
    @State private var boxNodes: [BoxNode] = []
    @State private var expandedBoxIPs: Set<String> = []
    @State private var selectedInstanceIDs: Set<Int> = []
    @State private var selectedBoxIPIndexKeys: Set<String> = []
    @State private var selectedBoxIPs: Set<String> = []
    @State private var initialInstanceIDs: Set<Int> = []
    @State private var initialBoxIPIndexKeys: Set<String> = []
    @State private var initialBoxIPs: Set<String> = []
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var containerSearchText: String = ""
    
    /// 仅影响列表展示；选中状态仍基于完整 `boxNodes`，过滤不会清空已选。
    private var filteredBoxNodes: [BoxNode] {
        let q = containerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return boxNodes }
        var out: [BoxNode] = []
        for node in boxNodes {
            let boxFields = [
                node.box.name,
                node.box.boxIP,
                node.box.remark ?? "",
                node.box.deviceCode ?? "",
                node.box.area ?? ""
            ]
            if boxFields.contains(where: { queryMatches($0, query: q) }) {
                out.append(node)
                continue
            }
            let matchedInstances = node.instances.filter { inst in
                let fields: [String] = [
                    instanceDisplayName(inst),
                    instanceSecondaryText(inst, boxIP: node.box.boxIP),
                    inst.name ?? "",
                    inst.scrmRemark ?? "",
                    inst.uuid ?? "",
                    inst.boxIP ?? "",
                    "\(inst.ID ?? 0)",
                    "\(inst.index ?? 0)",
                    inst.state ?? "",
                    inst.appType ?? ""
                ]
                return fields.contains { queryMatches($0, query: q) }
            }
            if !matchedInstances.isEmpty {
                out.append(BoxNode(box: node.box, instances: matchedInstances))
            }
        }
        return out
    }
    
    private func queryMatches(_ haystack: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return haystack.localizedStandardContains(query)
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("分配给用户", selection: $selectedUserId) {
                        Text("请选择用户").tag(nil as Int?)
                        ForEach(users) { user in
                            Text(user.displayName).tag(Optional(user.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(loading || saving)
                    
                    if loadingAssigned {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取当前分配...")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.45))
                        }
                    }
                    
                    if let msg = errorMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    if let msg = successMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(Color.green)
                    }
                } header: {
                    Text("用户")
                }
                
                Section {
                    if !loading && !boxNodes.isEmpty {
                        TextField("搜索云机、IP、容器名、备注、实例ID…", text: $containerSearchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("加载云机与容器中...")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.45))
                        }
                    } else if boxNodes.isEmpty {
                        Text("暂无可分配设备")
                            .foregroundColor(Color(white: 0.55))
                    } else if filteredBoxNodes.isEmpty {
                        Text("无匹配的云机或容器")
                            .foregroundColor(Color(white: 0.55))
                    } else {
                        ForEach(filteredBoxNodes) { node in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedBoxIPs.contains(node.box.boxIP) },
                                    set: { expanded in
                                        if expanded {
                                            expandedBoxIPs.insert(node.box.boxIP)
                                        } else {
                                            expandedBoxIPs.remove(node.box.boxIP)
                                        }
                                    }
                                )
                            ) {
                                ForEach(node.instances.indices, id: \.self) { idx in
                                    let instance = node.instances[idx]
                                    Button(action: { toggleInstance(instance, boxIP: node.box.boxIP) }) {
                                        HStack(spacing: 10) {
                                            Image(systemName: isInstanceSelected(instance, boxIP: node.box.boxIP) ? "checkmark.square.fill" : "square")
                                                .foregroundColor(isInstanceSelected(instance, boxIP: node.box.boxIP) ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color(white: 0.6))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(instanceDisplayName(instance))
                                                    .font(.system(size: 14))
                                                    .foregroundColor(Color(white: 0.18))
                                                Text(instanceSecondaryText(instance, boxIP: node.box.boxIP))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(white: 0.5))
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } label: {
                                Button(action: { toggleBox(node.box.boxIP) }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedBoxIPs.contains(node.box.boxIP) ? "checkmark.square.fill" : "square")
                                            .foregroundColor(selectedBoxIPs.contains(node.box.boxIP) ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color(white: 0.6))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(node.box.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(Color(white: 0.16))
                                            Text(node.box.boxIP)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color(white: 0.5))
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("云机 / 容器")
                } footer: {
                    Text("已分配项会默认显示为 ☑️。可直接调整后保存。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("分配设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中..." : "保存") {
                        Task { await saveAssignment() }
                    }
                    .disabled(saving || selectedUserId == nil || loading)
                }
            }
            .task {
                guard users.isEmpty && boxNodes.isEmpty else { return }
                await loadInitialData()
            }
            .onChange(of: selectedUserId) { userId in
                guard let uid = userId else { return }
                Task { await loadAssignedData(userId: uid) }
            }
            .onChange(of: containerSearchText) { newText in
                let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                expandedBoxIPs.formUnion(filteredBoxNodes.map { $0.box.boxIP })
            }
        }
    }
    
    private func loadInitialData() async {
        await MainActor.run {
            loading = true
            errorMessage = nil
            successMessage = nil
        }
        defer {
            Task { @MainActor in loading = false }
        }
        do {
            async let usersTask = AccountService.shared.getAssignableUsers(isAll: true)
            async let boxesTask = AccountService.shared.getBoxList(page: 1, pageSize: 9999)
            let (fetchedUsers, boxes) = try await (usersTask, boxesTask)
            
            let nodes: [BoxNode] = await withTaskGroup(of: BoxNode?.self) { group in
                for box in boxes {
                    group.addTask {
                        let instances = (try? await AccountService.shared.getInstanceList(boxIP: box.boxIP, page: 1, pageSize: 9999)) ?? []
                        let sorted = instances.sorted {
                            let lIndex = $0.index ?? Int.max
                            let rIndex = $1.index ?? Int.max
                            if lIndex != rIndex { return lIndex < rIndex }
                            return ($0.ID ?? Int.max) < ($1.ID ?? Int.max)
                        }
                        return BoxNode(box: box, instances: sorted)
                    }
                }
                var arr: [BoxNode] = []
                for await item in group {
                    if let item { arr.append(item) }
                }
                return arr.sorted { lhs, rhs in
                    lhs.box.name.localizedCompare(rhs.box.name) == .orderedAscending
                }
            }
            
            await MainActor.run {
                users = fetchedUsers.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
                boxNodes = nodes
                expandedBoxIPs = Set(nodes.prefix(3).map { $0.box.boxIP })
                if selectedUserId == nil {
                    selectedUserId = users.first?.id
                }
            }
            if let uid = await MainActor.run(body: { selectedUserId }) {
                await loadAssignedData(userId: uid)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                successMessage = nil
            }
        }
    }
    
    private func loadAssignedData(userId: Int) async {
        await MainActor.run {
            loadingAssigned = true
            errorMessage = nil
            successMessage = nil
        }
        defer {
            Task { @MainActor in loadingAssigned = false }
        }
        do {
            let assigned = try await AccountService.shared.getAssignedInstances(userId: userId)
            var instanceIDs = Set<Int>()
            var boxIndexKeys = Set<String>()
            var boxIPs = Set<String>()
            for item in assigned {
                let instanceId = item.instanceId ?? 0
                let index = item.index ?? 0
                let ip = (item.boxIP ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if instanceId > 0 {
                    instanceIDs.insert(instanceId)
                } else if !ip.isEmpty && index > 0 {
                    boxIndexKeys.insert("\(ip):\(index)")
                } else if !ip.isEmpty {
                    boxIPs.insert(ip)
                }
            }
            await MainActor.run {
                selectedInstanceIDs = instanceIDs
                selectedBoxIPIndexKeys = boxIndexKeys
                selectedBoxIPs = boxIPs
                initialInstanceIDs = instanceIDs
                initialBoxIPIndexKeys = boxIndexKeys
                initialBoxIPs = boxIPs
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                successMessage = nil
            }
        }
    }
    
    private func saveAssignment() async {
        guard let userId = selectedUserId else { return }
        await MainActor.run {
            saving = true
            errorMessage = nil
            successMessage = nil
        }
        defer {
            Task { @MainActor in saving = false }
        }
        do {
            try await AccountService.shared.assignInstances(
                userIds: [userId],
                instanceIDs: selectedInstanceIDs,
                boxIPIndexKeys: selectedBoxIPIndexKeys,
                boxIPs: selectedBoxIPs
            )
            await MainActor.run {
                initialInstanceIDs = selectedInstanceIDs
                initialBoxIPIndexKeys = selectedBoxIPIndexKeys
                initialBoxIPs = selectedBoxIPs
                successMessage = "分配保存成功"
                appState.presentUserFeedback("分配保存成功", level: .success)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                successMessage = nil
                appState.presentUserFeedback(error.localizedDescription, level: .error)
            }
        }
    }
    
    private func toggleBox(_ boxIP: String) {
        if selectedBoxIPs.contains(boxIP) {
            selectedBoxIPs.remove(boxIP)
            return
        }
        selectedBoxIPs.insert(boxIP)
        selectedBoxIPIndexKeys = selectedBoxIPIndexKeys.filter { !$0.hasPrefix("\(boxIP):") }
        if let node = boxNodes.first(where: { $0.box.boxIP == boxIP }) {
            for instance in node.instances {
                if let id = instance.ID, id > 0 {
                    selectedInstanceIDs.remove(id)
                }
            }
        }
    }
    
    private func toggleInstance(_ instance: Instance, boxIP: String) {
        if selectedBoxIPs.contains(boxIP) {
            selectedBoxIPs.remove(boxIP)
        }
        if let id = instance.ID, id > 0 {
            if selectedInstanceIDs.contains(id) {
                selectedInstanceIDs.remove(id)
            } else {
                selectedInstanceIDs.insert(id)
            }
            return
        }
        let idx = instance.index ?? 0
        guard idx > 0 else { return }
        let key = "\(boxIP):\(idx)"
        if selectedBoxIPIndexKeys.contains(key) {
            selectedBoxIPIndexKeys.remove(key)
        } else {
            selectedBoxIPIndexKeys.insert(key)
        }
    }
    
    private func isInstanceSelected(_ instance: Instance, boxIP: String) -> Bool {
        if selectedBoxIPs.contains(boxIP) { return true }
        if let id = instance.ID, id > 0 {
            return selectedInstanceIDs.contains(id)
        }
        let idx = instance.index ?? 0
        guard idx > 0 else { return false }
        return selectedBoxIPIndexKeys.contains("\(boxIP):\(idx)")
    }
    
    private func instanceDisplayName(_ instance: Instance) -> String {
        let remark = (instance.scrmRemark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !remark.isEmpty { return remark }
        let name = (instance.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let idx = instance.index { return "容器 #\(idx)" }
        if let id = instance.ID { return "容器 \(id)" }
        return "容器"
    }
    
    private func instanceSecondaryText(_ instance: Instance, boxIP: String) -> String {
        let idxText = "索引 \(instance.index ?? 0)"
        let idText = "实例ID \(instance.ID ?? 0)"
        return "\(boxIP) · \(idxText) · \(idText)"
    }
}

// 占位：设置弹窗
private struct SettingsPlaceholderSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var appState: AppState
    
    private let onboardingKeys = [
        "guide_account_page_v1",
        "guide_all_chats_v1",
        "guide_chat_detail_v1"
    ]
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(white: 0.12))
                
                Button(action: resetOnboardingGuides) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重新查看新手引导")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Color(white: 0.12))
                            Text("下次进入账号/对话/聊天页面时会再次展示教程")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.45))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.65))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(white: 0.9), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            .padding(16)
            .background(Color(red: 0.96, green: 0.96, blue: 0.96))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }
    
    private func resetOnboardingGuides() {
        let defaults = UserDefaults.standard
        onboardingKeys.forEach { defaults.set(false, forKey: $0) }
        appState.presentUserFeedback("已重置引导，下次进入会重新展示", level: .success)
    }
}

#Preview {
    MyView(appState: AppState())
}
