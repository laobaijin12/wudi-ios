//
//  AccountPlaceholderView.swift
//  WudiApp
//
//  与 H5 一致：下拉筛选云机，容器行名称去前缀、状态与功能按钮一比一还原；功能全部实现。
//

import SwiftUI
import WebKit

private let accountPageStatusTraceEnabled = false
@inline(__always) private func accountPageStatusTrace(_ message: @autoclosure () -> String) {
    guard accountPageStatusTraceEnabled else { return }
    print("[AccountStatus] \(message())")
}

// MARK: - 与 H5 formatInstanceName 一致：去除 MYTSDK 等前缀（前两段）
func formatInstanceName(_ name: String?) -> String {
    guard let name = name, !name.isEmpty else { return "" }
    let parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
    return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "_") : name
}

extension Instance {
    var instanceKey: String { "\(ID ?? 0)" }
    /// 与 H5 app_type_key 一致，用于 /api/v2/chats、messages 等接口的 instance_id 参数
    var instanceIdForApi: String {
        guard let id = ID else { return "0" }
        if appType == "business" { return "\(id)_business" }
        return "\(id)"
    }
}

/// 投屏模态框所需参数（与 H5 streamDialogs 项一致：name、streamUrl、token）
private struct ScreenModalContext: Identifiable {
    var id: String { "\(instance.ID ?? 0)" }
    let instance: Instance
    let streamURL: String
    let token: String
    var displayName: String { formatInstanceName(instance.name) }
}

private struct WebToolModalContext: Identifiable {
    let id = UUID()
    let title: String
    let url: String
}

private struct VpcLocalConfig: Codable {
    let ip: String
    let port: String
    let user: String
    let pwd: String
}

private struct VpcCountryOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

struct AccountPlaceholderView: View {
    @ObservedObject var appState: AppState
    @FocusState private var cloudSearchFocused: Bool
    @State private var boxLoading = false
    @State private var instanceLoading = false
    @State private var errorMessage: String?
    @State private var cloudSearchText: String = ""
    @State private var containerSearchText: String = ""
    @State private var showBoxPicker = false
    @State private var rebootingBoxIPs: Set<String> = []
    @State private var connectedInstanceIDs: Set<Int> = []
    @State private var connectingInstanceIDs: Set<Int> = []
    @State private var editingRemarkInstanceID: Int?
    @State private var editingRemarkValue: String = ""
    /// 备注写入后服务端可能短暂延迟，这里先本地覆盖，待服务端追平后自动清理。
    @State private var pendingRemarkOverrideByID: [Int: String] = [:]
    @State private var toastMessage: String?
    @State private var toastDismissWorkItem: DispatchWorkItem?
    @State private var jumpHighlightInstanceKey: String?
    @State private var jumpHighlightVisible: Bool = false
    @State private var showRebuildConfirm: Instance?
    @State private var showDeleteConfirm: Instance?
    @State private var showRenameSheet: Instance?
    @State private var renameNewName: String = ""
    @State private var showVpcSheet: Instance?
    @State private var vpcIp: String = ""
    @State private var vpcPort: String = ""
    @State private var vpcUser: String = ""
    @State private var vpcPwd: String = ""
    @State private var vpcLoading: Bool = false
    @State private var vpcCurrentLoading: Bool = false
    @State private var vpcSelectedCountryCode: String? = nil
    @State private var vpcCustomCountryCode: String = ""
    @State private var showVpcFilterSheet: Bool = false
    @State private var vpcFilterInput: String = ""
    @State private var vpcCurrentQueryTask: Task<Void, Never>?
    @State private var showCloseVpcConfirm: Bool = false
    
    private let vpcLocalCacheKey = "account_vpc_local_cache_v1"
    @State private var showImageSheet: Instance?
    @State private var imageList: [AccountService.InstanceImage] = []
    @State private var selectedImageId: Int?
    @State private var showMoveAlert: Instance?
    @State private var moveIndexText: String = ""
    @State private var showCopySheet: Instance?
    @State private var copyDstName: String = ""
    @State private var copyDstIndex: String = ""
    @State private var copyCount: String = "1"
    @State private var stateLoadingInstanceIDs: Set<Int> = []
    @State private var toggleStateConfirm: Instance?
    /// 投屏模态框：连接成功后打开，用 WebView 加载投屏页（与 H5 弹窗一致）
    @State private var screenModalContext: ScreenModalContext?
    @State private var webToolModalContext: WebToolModalContext?
    /// 当前投屏 modal 对应的实例 ID，用于 onDismiss 时清除「已连接」状态（滑掉 modal 时也会触发）
    @State private var screenModalInstanceID: Int?
    @State private var wsErrorDetailText: String?
    @State private var accountGuideStep: AccountGuideStep?
    @State private var accountGuideAutoAdvanceTask: Task<Void, Never>?
    @State private var didAutoLoadAfterLogin: Bool = false
    private let accountGuideShownKey = "guide_account_page_v1"
    private let vpcCountryOptions: [VpcCountryOption] = [
        VpcCountryOption(code: "US", name: "美国"),
        VpcCountryOption(code: "GB", name: "英国"),
        VpcCountryOption(code: "DE", name: "德国"),
        VpcCountryOption(code: "FR", name: "法国"),
        VpcCountryOption(code: "NL", name: "荷兰"),
        VpcCountryOption(code: "CA", name: "加拿大"),
        VpcCountryOption(code: "AU", name: "澳大利亚"),
        VpcCountryOption(code: "JP", name: "日本"),
        VpcCountryOption(code: "IN", name: "印度"),
        VpcCountryOption(code: "BR", name: "巴西"),
        VpcCountryOption(code: "IT", name: "意大利"),
        VpcCountryOption(code: "ES", name: "西班牙"),
        VpcCountryOption(code: "PL", name: "波兰"),
        VpcCountryOption(code: "RU", name: "俄罗斯"),
        VpcCountryOption(code: "KR", name: "韩国"),
        VpcCountryOption(code: "SG", name: "新加坡"),
        VpcCountryOption(code: "HK", name: "香港"),
        VpcCountryOption(code: "TW", name: "台湾"),
        VpcCountryOption(code: "MY", name: "马来西亚"),
        VpcCountryOption(code: "ID", name: "印尼"),
        VpcCountryOption(code: "TH", name: "泰国"),
        VpcCountryOption(code: "VN", name: "越南"),
        VpcCountryOption(code: "PH", name: "菲律宾"),
        VpcCountryOption(code: "TR", name: "土耳其"),
        VpcCountryOption(code: "MX", name: "墨西哥"),
        VpcCountryOption(code: "AR", name: "阿根廷")
    ]
    
    private let strongTextColor = Color(white: 0.12)
    private let secondaryTextColor = Color(white: 0.42)

    private enum AccountGuideStep: Int, CaseIterable {
        case rowButtons
        case statusAndLogout
        case openDropdown
        case rebootHint
        
        var title: String {
            switch self {
            case .rowButtons: return "先认识容器行按钮"
            case .statusAndLogout: return "这里看 WhatsApp 状态与一键退出"
            case .openDropdown: return "请先点击顶部下拉按钮"
            case .rebootHint: return "重启按钮的使用场景"
            }
        }
        
        var detail: String {
            switch self {
            case .rowButtons:
                return "连接=投屏；任务=养号；更多操作=容器高级操作。"
            case .statusAndLogout:
                return "右侧区域可看 WhatsApp 登录状态；箭头位置是一键退出账号按钮。3 秒后自动下一步。"
            case .openDropdown:
                return "请点击顶部筛选框右侧的下拉按钮，展开云机列表。"
            case .rebootHint:
                return "当投屏打不开、发送失败、无网络等异常时，可点云机行右侧重启按钮恢复。这里只做说明，不要求点击。"
            }
        }
        
        var next: AccountGuideStep? { AccountGuideStep(rawValue: rawValue + 1) }
    }
    
    private var filteredBoxes: [Box] {
        let key = cloudSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return appState.accountBoxes }
        return appState.accountBoxes.filter {
            $0.name.lowercased().contains(key) ||
            $0.boxIP.lowercased().contains(key) ||
            ($0.area ?? "").lowercased().contains(key)
        }
    }
    
    private var selectedBoxes: [Box] {
        appState.accountBoxes.filter { appState.accountSelectedBoxIPs.contains($0.boxIP) }
    }

    private var filteredContainerInstances: [Instance] {
        let key = containerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return appState.accountInstances }
        return appState.accountInstances.filter { inst in
            let rawName = (inst.name ?? "").lowercased()
            let displayName = formatInstanceName(inst.name).lowercased()
            let remark = (inst.scrmRemark ?? "").lowercased()
            let ip = (inst.boxIP ?? "").lowercased()
            return rawName.contains(key)
                || displayName.contains(key)
                || remark.contains(key)
                || ip.contains(key)
        }
    }
    
    private var loggedInInstanceCount: Int {
        appState.accountInstances.reduce(0) { partial, inst in
            partial + (((inst.scrmWsStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "已登录") ? 1 : 0)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            filterSection
            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            containerSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
        .task { await fetchBoxList() }
        .onAppear {
            /// 打开 app 时，若已有选中的云机，自动拉取容器列表（含 WhatsApp 状态）
            if !appState.accountSelectedBoxIPs.isEmpty && appState.accountInstances.isEmpty {
                Task { await fetchInstanceList() }
            }
            if appState.isLoggedIn, appState.selectedTab == .account, !didAutoLoadAfterLogin {
                didAutoLoadAfterLogin = true
                Task { await triggerAutoLoadAfterLoginIfNeeded() }
            }
        }
        .onChange(of: appState.selectedTab) { newTab in
            /// 仅在账号页容器列表为空时自动拉取，避免每次切换 Tab 都触发请求
            if newTab == .account,
               !appState.accountSelectedBoxIPs.isEmpty,
               appState.accountInstances.isEmpty {
                Task { await fetchInstanceList() }
            }
            if newTab == .account, appState.isLoggedIn, !didAutoLoadAfterLogin {
                didAutoLoadAfterLogin = true
                Task { await triggerAutoLoadAfterLoginIfNeeded() }
            }
        }
        .onChange(of: appState.isLoggedIn) { loggedIn in
            if !loggedIn {
                didAutoLoadAfterLogin = false
            } else if appState.selectedTab == .account {
                didAutoLoadAfterLogin = true
                Task { await triggerAutoLoadAfterLoginIfNeeded() }
            }
        }
        .onAppear {
            startAccountGuideIfNeeded()
        }
        .onDisappear {
            accountGuideAutoAdvanceTask?.cancel()
            accountGuideAutoAdvanceTask = nil
        }
        .onChange(of: showBoxPicker) { expanded in
            guard accountGuideStep == .openDropdown, expanded else { return }
            advanceAccountGuide()
        }
        .overlay { accountGuideOverlay }
        .onChange(of: toastMessage) { msg in
            toastDismissWorkItem?.cancel()
            toastDismissWorkItem = nil
            guard let msg = msg, !msg.isEmpty else { return }
            let lower = msg.lowercased()
            let isError = msg.contains("失败")
                || msg.contains("错误")
                || msg.contains("异常")
                || lower.contains("error")
                || lower.contains("failed")
            appState.presentUserFeedback(msg, level: isError ? .error : .success)
            let work = DispatchWorkItem { self.toastMessage = nil }
            toastDismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
        .confirmationDialog("重建聊天数据", isPresented: Binding(get: { showRebuildConfirm != nil }, set: { if !$0 { showRebuildConfirm = nil } }), titleVisibility: .visible) {
            Button("确定重建", role: .destructive) {
                if let inst = showRebuildConfirm { Task { await handleRebuildChat(inst) } }
                showRebuildConfirm = nil
            }
            Button("取消", role: .cancel) { showRebuildConfirm = nil }
        } message: { Text("确认重建聊天数据吗？重建将删除所有聊天记录、对话以及联系人，删除后将自动同步云机内最新聊天数据。") }
        .confirmationDialog("删除云机", isPresented: Binding(get: { showDeleteConfirm != nil }, set: { if !$0 { showDeleteConfirm = nil } }), titleVisibility: .visible) {
            Button("确定删除", role: .destructive) {
                if let inst = showDeleteConfirm { Task { await handleDelete(inst) } }
                showDeleteConfirm = nil
            }
            Button("取消", role: .cancel) { showDeleteConfirm = nil }
        } message: { Text("确定删除该云机吗？此操作不可恢复。") }
        .sheet(isPresented: Binding(get: { showRenameSheet != nil }, set: { if !$0 { showRenameSheet = nil } })) {
            if let inst = showRenameSheet { renameSheet(inst) }
        }
        .sheet(isPresented: Binding(get: { showVpcSheet != nil }, set: { if !$0 { showVpcSheet = nil } })) {
            if let inst = showVpcSheet { vpcSheet(inst) }
        }
        .sheet(isPresented: $showVpcFilterSheet) {
            vpcFilterSheet
        }
        .sheet(isPresented: Binding(get: { showImageSheet != nil }, set: { if !$0 { showImageSheet = nil } })) {
            if let inst = showImageSheet { imageSheet(inst) }
        }
        .sheet(isPresented: Binding(get: { showCopySheet != nil }, set: { if !$0 { showCopySheet = nil } })) {
            if let inst = showCopySheet { copySheet(inst) }
        }
        .confirmationDialog("确认操作", isPresented: Binding(get: { toggleStateConfirm != nil }, set: { if !$0 { toggleStateConfirm = nil } }), titleVisibility: .visible) {
            if let inst = toggleStateConfirm {
                let isRunning = (inst.state ?? "").lowercased() == "running"
                Button(isRunning ? "确定停止" : "确定启动", role: isRunning ? .destructive : nil) {
                    let target = inst
                    toggleStateConfirm = nil
                    Task { await doToggleState(target) }
                }
                Button("取消", role: .cancel) { toggleStateConfirm = nil }
            }
        } message: {
            if let inst = toggleStateConfirm {
                let isRunning = (inst.state ?? "").lowercased() == "running"
                Text("确定要\(isRunning ? "停止" : "启动")实例 \(formatInstanceName(inst.name)) 吗？")
            }
        }
        .alert("移动实例", isPresented: Binding(get: { showMoveAlert != nil }, set: { if !$0 { showMoveAlert = nil } })) {
            TextField("目标坑位索引(1-12)", text: $moveIndexText).keyboardType(.numberPad)
            Button("确定") {
                if let inst = showMoveAlert, let idx = Int(moveIndexText), (1...12).contains(idx) {
                    Task { await handleMove(inst, index: idx) }
                } else { toastMessage = "请输入 1-12 的索引" }
                showMoveAlert = nil
                moveIndexText = ""
            }
            Button("取消", role: .cancel) { showMoveAlert = nil; moveIndexText = "" }
        } message: { Text("请输入目标坑位索引") }
        .fullScreenCover(item: $screenModalContext, onDismiss: {
            connectedInstanceIDs.remove(screenModalInstanceID ?? 0)
            toastMessage = nil
            screenModalInstanceID = nil
        }) { ctx in
            screenModalView(ctx) {
                connectedInstanceIDs.remove(ctx.instance.ID ?? 0)
                toastMessage = nil
                screenModalContext = nil
            }
        }
        .sheet(item: $webToolModalContext) { ctx in
            WebToolView(title: ctx.title, urlString: ctx.url)
        }
        .alert(
            "同步异常详情",
            isPresented: Binding(
                get: { wsErrorDetailText != nil },
                set: { if !$0 { wsErrorDetailText = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { wsErrorDetailText = nil }
        } message: {
            Text(wsErrorDetailText ?? "")
        }
    }
    
    /// 投屏模态框：原生 WebSocket 连接 scrcpy 流，H.264 解码后显示
    @ViewBuilder private func screenModalView(_ ctx: ScreenModalContext, onClose: @escaping () -> Void) -> some View {
        ScrcpyStreamView(streamURL: ctx.streamURL, onClose: onClose)
    }
    
    private func startAccountGuideIfNeeded() {
        accountGuideAutoAdvanceTask?.cancel()
        accountGuideAutoAdvanceTask = nil
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: accountGuideShownKey) else {
            accountGuideStep = nil
            return
        }
        defaults.set(true, forKey: accountGuideShownKey)
        accountGuideStep = .rowButtons
    }
    
    private func advanceAccountGuide() {
        guard let step = accountGuideStep else { return }
        accountGuideAutoAdvanceTask?.cancel()
        accountGuideAutoAdvanceTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            accountGuideStep = step.next
        }
        if let next = step.next {
            scheduleAutoAdvanceIfNeeded(for: next)
        }
    }
    
    private func endAccountGuide() {
        accountGuideAutoAdvanceTask?.cancel()
        accountGuideAutoAdvanceTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            accountGuideStep = nil
        }
    }
    
    private func scheduleAutoAdvanceIfNeeded(for step: AccountGuideStep) {
        guard step == .statusAndLogout || step == .rebootHint else { return }
        let seconds: UInt64 = (step == .statusAndLogout) ? 3 : 4
        accountGuideAutoAdvanceTask?.cancel()
        accountGuideAutoAdvanceTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if accountGuideStep == step {
                    advanceAccountGuide()
                }
            }
        }
    }
    
    @ViewBuilder
    private var accountGuideOverlay: some View {
        if let step = accountGuideStep {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let cardTop: CGFloat = (step == .statusAndLogout) ? 170 : 88
                ZStack(alignment: .top) {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    
                    if step == .openDropdown {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .position(x: width - 70, y: 66)
                            .shadow(color: Color.black.opacity(0.16), radius: 3, x: 0, y: 1)
                    }
                    
                    if step == .rowButtons {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .position(x: 208, y: 212)
                            .shadow(color: Color.black.opacity(0.16), radius: 3, x: 0, y: 1)
                    }
                    
                    if step == .statusAndLogout {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .position(x: width - 30, y: 220)
                            .shadow(color: Color.black.opacity(0.16), radius: 3, x: 0, y: 1)
                    }
                    
                    if step == .rebootHint, showBoxPicker {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.96, green: 0.45, blue: 0.12))
                            .position(x: width - 28, y: 168)
                            .shadow(color: Color.black.opacity(0.16), radius: 3, x: 0, y: 1)
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
                                    .foregroundColor(strongTextColor)
                                Text(step.detail)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(white: 0.28))
                            }
                            Spacer(minLength: 0)
                        }
                        
                        HStack(spacing: 10) {
                            Button("结束引导") { endAccountGuide() }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: 0.35))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.94))
                                .clipShape(Capsule())
                            
                            if step == .rowButtons {
                                Button("下一步") { advanceAccountGuide() }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(red: 0.09, green: 0.47, blue: 1.0))
                                    .clipShape(Capsule())
                            }
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
            .onAppear {
                scheduleAutoAdvanceIfNeeded(for: step)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(30)
        }
    }
    
    // MARK: - 下拉筛选云机（全选在输入框右侧）
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
                TextField("输入IP或云机名称筛选", text: $cloudSearchText)
                    .font(.subheadline)
                    .foregroundColor(strongTextColor)
                    .textFieldStyle(.plain)
                    .focused($cloudSearchFocused)
                    .onTapGesture { showBoxPicker = true }
                if showBoxPicker {
                    Button(action: { showBoxPicker = false }) {
                        Image(systemName: "chevron.up")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                    }
                } else {
                    Button(action: { showBoxPicker = true }) {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                    }
                }
                Button(action: selectAllBoxes) {
                    Text("全选")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                }
                .buttonStyle(.plain)
                .disabled(boxLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { showBoxPicker = true }
            .padding(.horizontal, 12)
            .onChange(of: cloudSearchFocused) { focused in
                if focused { showBoxPicker = true }
            }
            
            if !appState.accountSelectedBoxIPs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedBoxes, id: \.boxIP) { box in
                            HStack(spacing: 4) {
                                Text("\(box.name) (\(box.boxIP))")
                                    .font(.caption)
                                Button(action: {
                                    appState.removeAccountBoxSelection(box.boxIP)
                                    if !appState.accountSelectedBoxIPs.isEmpty {
                                        Task { await fetchInstanceList() }
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.09, green: 0.47, blue: 1.0).opacity(0.15))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 4)
            }
            
            if showBoxPicker {
                VStack(spacing: 0) {
                    if boxLoading && appState.accountBoxes.isEmpty {
                        ProgressView()
                            .padding(.vertical, 12)
                    } else if filteredBoxes.isEmpty {
                        Text(appState.accountBoxes.isEmpty ? "暂无云机" : "未找到匹配的云机")
                            .font(.caption)
                            .foregroundColor(secondaryTextColor)
                            .padding(.vertical, 12)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredBoxes, id: \.ID) { box in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(box.name)
                                                .font(.subheadline)
                                                .foregroundColor(strongTextColor)
                                            Text(box.boxIP)
                                                .font(.caption)
                                                .foregroundColor(secondaryTextColor)
                                        }
                                        Spacer()
                                        Button(action: { Task { await rebootBox(box) } }) {
                                            if rebootingBoxIPs.contains(box.boxIP) {
                                                ProgressView()
                                                    .scaleEffect(0.75)
                                                    .frame(width: 18, height: 18)
                                            } else {
                                                Image(systemName: "arrow.clockwise.circle")
                                                    .font(.system(size: 18, weight: .medium))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.12))
                                        .disabled(rebootingBoxIPs.contains(box.boxIP))
                                        
                                        if appState.accountSelectedBoxIPs.contains(box.boxIP) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showBoxPicker = false
                                        appState.toggleAccountBoxSelection(box.boxIP)
                                        if appState.accountSelectedBoxIPs.contains(box.boxIP) {
                                            Task { await fetchInstanceList() }
                                        } else {
                                            if appState.accountSelectedBoxIPs.isEmpty {
                                                appState.accountInstances = []
                                            } else {
                                                Task { await fetchInstanceList() }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .background(Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
    }
    
    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("容器列表")
                    .font(.headline)
                    .foregroundColor(strongTextColor)
                Spacer()
                if !appState.accountSelectedBoxIPs.isEmpty {
                    Text("已选 \(appState.accountSelectedBoxIPs.count) 台 · 容器 \(appState.accountInstances.count) 个 · 已登录 \(loggedInInstanceCount) 个")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                    Button(action: { Task { await fetchInstanceList() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                            .foregroundColor(strongTextColor)
                    }
                    .disabled(instanceLoading)
                } else {
                    Text("请先在上方选择云机")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
            }
            .padding(.horizontal, 12)
            
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(secondaryTextColor)
                TextField("搜索容器名称/备注/IP", text: $containerSearchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
                if !containerSearchText.isEmpty {
                    Button(action: { containerSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.96))
            .cornerRadius(8)
            .padding(.horizontal, 12)

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if appState.accountSelectedBoxIPs.isEmpty {
                        HStack {
                            Spacer()
                            Text("请选择云机")
                                .font(.subheadline)
                                .foregroundColor(secondaryTextColor)
                                .padding(.vertical, 32)
                            Spacer()
                        }
                    } else if instanceLoading && appState.accountInstances.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("加载容器列表中...")
                                    .font(.caption)
                                    .foregroundColor(secondaryTextColor)
                            }
                            .padding(.vertical, 24)
                            Spacer()
                        }
                    } else if appState.accountInstances.isEmpty {
                        HStack {
                            Spacer()
                            Text("该云机下暂无容器")
                                .font(.subheadline)
                                .foregroundColor(secondaryTextColor)
                                .padding(.vertical, 24)
                            Spacer()
                        }
                    } else if filteredContainerInstances.isEmpty {
                        HStack {
                            Spacer()
                            Text("无匹配容器")
                                .font(.subheadline)
                                .foregroundColor(secondaryTextColor)
                                .padding(.vertical, 24)
                            Spacer()
                        }
                    } else {
                        ForEach(filteredContainerInstances, id: \.instanceKey) { inst in
                            let highlight = (jumpHighlightInstanceKey == inst.instanceKey) && jumpHighlightVisible
                            ContainerRowView(
                                instance: inst,
                                buttonAuth: appState.accountInstanceButtonAuth,
                                showEnterSessionButton: appState.allowsEnterSessionByMenu,
                                isCurrentContainer: appState.currentContainer?.ID == inst.ID,
                                isConnecting: connectingInstanceIDs.contains(inst.ID ?? 0),
                                isConnected: connectedInstanceIDs.contains(inst.ID ?? 0),
                                isStateLoading: stateLoadingInstanceIDs.contains(inst.ID ?? 0),
                                isEditingRemark: editingRemarkInstanceID == inst.ID,
                                editingRemarkValue: editingRemarkValue,
                                onEditingRemarkChange: { editingRemarkValue = $0 },
                                onStartEditRemark: {
                                    editingRemarkInstanceID = inst.ID
                                    editingRemarkValue = inst.scrmRemark ?? ""
                                },
                                onSaveRemark: { newValue in
                                    Task { await saveRemark(instance: inst, value: newValue) }
                                },
                                onCancelRemark: {
                                    editingRemarkInstanceID = nil
                                    editingRemarkValue = ""
                                },
                                onConnect: { Task { await handleConnect(inst) } },
                                onToggleState: { toggleStateConfirm = inst },
                                onTask: { cmd in Task { await handleTask(inst, command: cmd) } },
                                onMore: { cmd in Task { await handleMore(inst, command: cmd) } },
                                onEnterSession: { appState.enterSession(container: inst) },
                                onTapWsError: {
                                    let detail = (inst.scrmWsError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !detail.isEmpty { wsErrorDetailText = detail }
                                }
                            )
                            .overlay {
                                if highlight {
                                    Rectangle()
                                        .fill(Color(red: 1.0, green: 0.93, blue: 0.46).opacity(0.75))
                                }
                            }
                            .animation(.easeInOut(duration: 0.18), value: highlight)
                            .id(inst.instanceKey)
                        }
                    }
                }
            }
            .refreshable {
                if appState.accountSelectedBoxIPs.isEmpty {
                    await fetchBoxList()
                } else {
                    await fetchInstanceList()
                }
            }
            .task(id: appState.accountJumpRequestToken) {
                await handleAccountJumpRequest(proxy: proxy)
            }
            }
        }
        .background(Color.white)
    }
    
    private func handleAccountJumpRequest(proxy: ScrollViewProxy) async {
        let targetKey = (appState.accountJumpToInstanceKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetKey.isEmpty else { return }

        await MainActor.run {
            if !containerSearchText.isEmpty {
                containerSearchText = ""
            }
        }

        if appState.accountInstances.isEmpty, !appState.accountSelectedBoxIPs.isEmpty {
            await fetchInstanceList()
        }

        guard appState.accountInstances.contains(where: { $0.instanceKey == targetKey }) else { return }

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(targetKey, anchor: .center)
            }
        }

        await MainActor.run {
            jumpHighlightInstanceKey = targetKey
            withAnimation(.easeInOut(duration: 0.18)) {
                jumpHighlightVisible = true
            }
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.22)) {
                jumpHighlightVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                jumpHighlightInstanceKey = nil
            }
        }
    }

    private func fetchBoxList() async {
        boxLoading = true
        errorMessage = nil
        defer { boxLoading = false }
        if appState.accountBoxes.isEmpty, let cached = await AppCacheStore.shared.loadBoxes(maxAge: 6 * 3600) {
            await MainActor.run { appState.accountBoxes = cached }
        }
        do {
            let list = try await AccountService.shared.getBoxList()
            let selectedAfterFetch = await MainActor.run { () -> Set<String> in
                appState.accountBoxes = list
                errorMessage = nil
                if !appState.isAdminUser,
                   appState.accountSelectedBoxIPs.isEmpty,
                   !list.isEmpty {
                    appState.setAccountSelectedBoxIPs(Set(list.map(\.boxIP)))
                }
                return appState.accountSelectedBoxIPs
            }
            await AppCacheStore.shared.saveBoxes(list)
            if !selectedAfterFetch.isEmpty {
                await fetchInstanceList(selectedBoxIPs: selectedAfterFetch)
            }
        } catch is CancellationError {
            // 下拉刷新被中断属于正常行为，不提示错误
            await MainActor.run { errorMessage = nil }
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession 主动取消（如刷新重入/视图切换）时不提示
            await MainActor.run { errorMessage = nil }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
    
    private func fetchInstanceList(selectedBoxIPs: Set<String>? = nil) async {
        let targetIPs = selectedBoxIPs ?? appState.accountSelectedBoxIPs
        guard !targetIPs.isEmpty else { return }
        accountPageStatusTrace("fetchInstanceList start targetIPs=\(targetIPs.count) ips=\(targetIPs.sorted().joined(separator: ","))")
        instanceLoading = true
        errorMessage = nil
        defer { instanceLoading = false }
        if appState.accountInstances.isEmpty,
           let cached = await AppCacheStore.shared.loadInstances(selectedBoxIPs: targetIPs, maxAge: nil) {
            await MainActor.run {
                appState.accountInstances = appState.mergeStableUnreadIntoInstances(cached)
                appState.sortAccountInstances()
            }
        }
        do {
            let visibleAll = try await AccountService.shared.getAllVisibleInstances(pageSize: 200)
            let all = visibleAll.filter { inst in
                guard let boxIP = inst.boxIP else { return false }
                return targetIPs.contains(boxIP)
            }
            await MainActor.run {
                // 备注最终一致性保护：在服务端还未返回新备注前，优先使用本地最近成功写入的值。
                let overridden = all.map { inst -> Instance in
                    guard let id = inst.ID, let pending = pendingRemarkOverrideByID[id] else { return inst }
                    let remote = (inst.scrmRemark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if remote == pending {
                        pendingRemarkOverrideByID.removeValue(forKey: id)
                        return inst
                    }
                    return inst.with(scrmRemark: pending)
                }
                appState.accountInstances = appState.mergeStableUnreadIntoInstances(overridden)
                errorMessage = nil
                appState.sortAccountInstances()
                appState.notifyAccountInstancesDidUpdate()
            }
            await AppCacheStore.shared.saveInstances(selectedBoxIPs: targetIPs, instances: appState.accountInstances)
            await mergeSyncStatusIntoInstances()
            accountPageStatusTrace("fetchInstanceList done mergedCount=\(all.count)")
        } catch is CancellationError {
            // 下拉刷新被中断属于正常行为，不提示错误
            await MainActor.run { errorMessage = nil }
            accountPageStatusTrace("fetchInstanceList cancelled")
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession 主动取消（如刷新重入/视图切换）时不提示
            await MainActor.run { errorMessage = nil }
            accountPageStatusTrace("fetchInstanceList url_cancelled")
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
            accountPageStatusTrace("fetchInstanceList failed err=\(error.localizedDescription)")
        }
    }
    
    private func triggerAutoLoadAfterLoginIfNeeded() async {
        if appState.accountBoxes.isEmpty {
            await fetchBoxList()
            return
        }
        if !appState.accountSelectedBoxIPs.isEmpty, appState.accountInstances.isEmpty {
            await fetchInstanceList()
        }
    }
    
    /// 与 H5 一致：拉取运行中容器的 WhatsApp 状态（已登录/未登录/需升级）并合并到列表
    private func mergeSyncStatusIntoInstances() async {
        let runningKeys = appState.accountInstances
            .filter { ($0.state ?? "").lowercased() == "running" }
            .compactMap { inst -> String? in
                guard let id = inst.ID else { return nil }
                return "\(id)"
            }
        guard !runningKeys.isEmpty else { return }
        do {
            let statusMap = try await AccountService.shared.getSyncStatus(instanceIds: runningKeys)
            accountPageStatusTrace("mergeSyncStatusIntoInstances running=\(runningKeys.count) statusMap=\(statusMap.count)")
            await MainActor.run {
                appState.accountInstances = appState.accountInstances.map { inst in
                    let key = "\(inst.ID ?? 0)"
                    guard let s = statusMap[key] else { return inst }
                    var wsStatus = s.scrmWsStatus ?? ""
                    if let detail = s.scrmWsStatusDetail, !detail.isEmpty, detail != "登录" {
                        wsStatus = detail
                    }
                    accountPageStatusTrace("instance=\(key) ws=\(s.scrmWsStatus ?? "-") detail=\(s.scrmWsStatusDetail ?? "-") final=\(wsStatus.isEmpty ? "-" : wsStatus)")
                    return inst.with(scrmWsStatus: wsStatus.isEmpty ? nil : wsStatus, scrmWsError: s.scrmWsError)
                }
                appState.sortAccountInstances()
            }
            await AppCacheStore.shared.saveInstances(selectedBoxIPs: appState.accountSelectedBoxIPs, instances: appState.accountInstances)
        } catch {
            // 状态拉取失败不阻塞列表展示，仅不显示 WhatsApp 状态角标
        }
    }
    
    private func selectAllBoxes() {
        appState.setAccountSelectedBoxIPs(Set(filteredBoxes.map(\.boxIP)))
        if !appState.accountSelectedBoxIPs.isEmpty {
            Task { await fetchInstanceList() }
        }
    }
    
    // MARK: - 备注
    private func saveRemark(instance: Instance, value: String) async {
        guard let id = instance.ID else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await AccountService.shared.updateInstanceRemark(instanceId: id, remark: trimmed)
            await MainActor.run {
                pendingRemarkOverrideByID[id] = trimmed
                if let idx = appState.accountInstances.firstIndex(where: { $0.ID == id }) {
                    appState.accountInstances[idx] = appState.accountInstances[idx].with(scrmRemark: trimmed)
                }
                editingRemarkInstanceID = nil
                editingRemarkValue = ""
                toastMessage = "备注更新成功"
                Task {
                    await AppCacheStore.shared.saveInstances(selectedBoxIPs: appState.accountSelectedBoxIPs, instances: appState.accountInstances)
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await fetchInstanceList()
                }
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }

    private func rebootBox(_ box: Box) async {
        guard !rebootingBoxIPs.contains(box.boxIP) else { return }
        await MainActor.run { rebootingBoxIPs.insert(box.boxIP) }
        defer { Task { @MainActor in rebootingBoxIPs.remove(box.boxIP) } }
        do {
            try await AccountService.shared.rebootBox(boxIP: box.boxIP)
            await MainActor.run {
                toastMessage = "重启指令已发送"
            }
        } catch {
            await MainActor.run {
                toastMessage = error.localizedDescription
            }
        }
    }
    
    // MARK: - 连接
    /// 连接 = 连接投屏（与 H5 handleConnect 一致：调用 startScrcpy，成功后打开投屏模态框）
    private func handleConnect(_ inst: Instance) async {
        guard let id = inst.ID, let boxIP = inst.boxIP else { return }
        if connectingInstanceIDs.contains(id) { return }
        await MainActor.run { connectingInstanceIDs.insert(id) }
        defer { Task { @MainActor in connectingInstanceIDs.remove(id) } }
        do {
            // 与 H5 一致：先 GET start-scrcpy，拿到 apiUrl、screenURL 等；固定走公网代理，不用 apiUrl 的 host 直连
            let (authorization, _, fullData) = try await AccountService.shared.startScrcpy(boxIP: boxIP, instanceId: id, type: "screen")
            if let d = fullData {
                print("[Scrcpy] handleConnect: got apiUrl=\(d.apiUrl ?? "") screenURL=\(d.screenURL?.prefix(80) ?? "")...")
            }
            let streamURL: String
            if let apiUrl = fullData?.apiUrl, let adb = fullData?.adbAddr, !adb.isEmpty, var raw = fullData?.screenURL, !raw.isEmpty {
                if raw.contains("#") { raw = String(raw.split(separator: "#").first ?? "") }
                var fullBackend = raw.contains("?") ? String(raw.split(separator: "?").first ?? "") : raw
                if !fullBackend.hasSuffix("/") { fullBackend += "/" }
                fullBackend += "?action=proxy-adb&remote=tcp:8886&udid=\(adb)"
                let nodeName = nodeNameFromApiUrl(apiUrl)
                streamURL = buildStreamURLViaProxy(nodeName: nodeName, fullBackendURL: fullBackend)
            } else {
                streamURL = buildStreamURLFallback(boxIP: boxIP, index: inst.index ?? 1, token: authorization)
            }
            await MainActor.run {
                connectedInstanceIDs.insert(id)
                screenModalInstanceID = id
                screenModalContext = ScreenModalContext(instance: inst, streamURL: streamURL, token: authorization)
            }
            toastMessage = "投屏连接成功"
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    /// 从 apiUrl（如 http://192.168.87.11:8003）取出网段 192.168.87 作为 path 的 nodeName
    private func nodeNameFromApiUrl(_ apiUrl: String) -> String {
        guard let u = URL(string: apiUrl), let host = u.host else {
            return "192.168.87"
        }
        return host.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// 传未编码的 url 参数：?url= + 原始后端 URL 字符串（保留 &、= 不编码），不做 addingPercentEncoding
    private func buildStreamURLViaProxy(nodeName: String, fullBackendURL: String) -> String {
        let host = APIConfig.host
        let hostOnly = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").split(separator: "/").first.map(String.init) ?? host
        let scheme = host.lowercased().hasPrefix("https") ? "https" : "http"
        let base = "\(scheme)://\(hostOnly):8081"
        return "\(base)/\(nodeName)/proxy?url=\(fullBackendURL)"
    }

    /// 无 screenURL 时的回退：拼整段后端 URL（不编码）进 url=
    private func buildStreamURLFallback(boxIP: String, index: Int, token: String) -> String {
        let port = index < 10 ? "50" + "0\(index)" : "50" + "\(index)"
        let udid = "\(boxIP):\(port)"
        let fullBackend = "http://\(boxIP):8003/proxy-screen/\(token)/\(port)/?action=proxy-adb&remote=tcp:8886&udid=\(udid)"
        return buildStreamURLViaProxy(nodeName: boxIP.split(separator: ".").prefix(3).joined(separator: "."), fullBackendURL: fullBackend)
    }
    
    /// 开关机：启动/停止实例（与 H5 handleToggleState 一致）
    private func doToggleState(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        if stateLoadingInstanceIDs.contains(id) { return }
        await MainActor.run { stateLoadingInstanceIDs.insert(id) }
        defer { Task { @MainActor in stateLoadingInstanceIDs.remove(id) } }
        let isRunning = (inst.state ?? "").lowercased() == "running"
        do {
            if isRunning {
                try await AccountService.shared.stopInstance(instanceId: id)
            } else {
                try await AccountService.shared.startInstance(instanceId: id)
            }
            await MainActor.run {
                toastMessage = isRunning ? "停止成功" : "启动成功"
                Task { await fetchInstanceList() }
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    // MARK: - 任务
    private func handleTask(_ inst: Instance, command: String) async {
        guard let boxIP = inst.boxIP else { return }
        do {
            let params = ChatService.CallSCRMFuncParams(
                instanceID: inst.instanceIdForApi,
                method: command,
                name: inst.name ?? "",
                ip: boxIP,
                index: inst.index ?? 1,
                jid: nil,
                message: nil,
                contactName: nil,
                emoji: nil,
                quotedIndex: nil,
                quotedText: nil,
                quotedType: nil,
                quotedTimestamp: nil,
                appType: inst.appType,
                cloneID: nil,
                targetLang: nil,
                imageData: nil,
                imageFileName: nil
            )
            let res = try await ChatService.shared.callSCRMFunc(params)
            await MainActor.run {
                toastMessage = (res.code == 1) ? "任务请求已发送" : (res.msg ?? "任务请求失败")
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    // MARK: - 更多操作
    private func handleMore(_ inst: Instance, command: String) async {
        switch command {
        case "set_vpc":
            await prepareVpcSheet(inst)
        case "reboot":
            await handleReboot(inst)
        case "update_name":
            await MainActor.run { showRenameSheet = inst; renameNewName = formatInstanceName(inst.name) }
        case "random_device_info":
            await handleRandomDeviceInfo(inst)
        case "switch_image":
            await MainActor.run { showImageSheet = inst; selectedImageId = nil }
            if let id = inst.ID {
                do {
                    let list = try await AccountService.shared.getInstanceImages(instanceId: id)
                    await MainActor.run { imageList = list }
                } catch { await MainActor.run { toastMessage = error.localizedDescription } }
            }
        case "move":
            await MainActor.run { showMoveAlert = inst; moveIndexText = "" }
        case "reset":
            await handleReset(inst)
        case "copy":
            await MainActor.run { showCopySheet = inst; copyDstName = ""; copyDstIndex = ""; copyCount = "1" }
        case "delete":
            await MainActor.run { showDeleteConfirm = inst }
        case "shell":
            await openWebTool(inst, type: "shell", title: "终端窗口", streamReplace: "shell")
        case "files":
            await openWebTool(inst, type: "screen", title: "文件上传", streamReplace: "list-files")
        case "paste_upload":
            await openWebTool(inst, type: "screen", title: "粘贴上传", streamReplace: "paste-upload")
        case "rebuild_chat":
            await MainActor.run { showRebuildConfirm = inst }
        case "update_ws":
            await updateWS(inst)
        case "restart_ws":
            await restartWS(inst)
        case "enable_sync":
            await setSyncEnabled(inst, enabled: true)
        case "disable_sync":
            await setSyncEnabled(inst, enabled: false)
        default: break
        }
    }

    private func openWebTool(_ inst: Instance, type: String, title: String, streamReplace: String) async {
        guard let id = inst.ID, let boxIP = inst.boxIP else { return }
        do {
            let (_, screenURL, _) = try await AccountService.shared.startScrcpy(boxIP: boxIP, instanceId: id, type: type)
            guard let raw = screenURL, !raw.isEmpty else {
                await MainActor.run { toastMessage = "工具地址为空" }
                return
            }
            let finalURL = raw.replacingOccurrences(of: "stream", with: streamReplace)
            await MainActor.run {
                webToolModalContext = WebToolModalContext(title: title, url: finalURL)
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    private func restartWS(_ inst: Instance) async {
        guard let boxIP = inst.boxIP else { return }
        do {
            let params = ChatService.CallSCRMFuncParams(
                instanceID: inst.instanceIdForApi,
                method: "start_ws",
                name: inst.name ?? "",
                ip: boxIP,
                index: inst.index ?? 1,
                jid: nil,
                message: nil,
                contactName: nil,
                emoji: nil,
                quotedIndex: nil,
                quotedText: nil,
                quotedType: nil,
                quotedTimestamp: nil,
                appType: inst.appType,
                cloneID: nil,
                targetLang: nil,
                imageData: nil,
                imageFileName: nil
            )
            let res = try await ChatService.shared.callSCRMFunc(params)
            await MainActor.run {
                toastMessage = (res.code == 1) ? "重启 WS 成功" : (res.msg ?? "重启 WS 失败")
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }

    private func updateWS(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        do {
            let msg = try await AccountService.shared.updateInstanceWS(instanceId: id)
            await MainActor.run { toastMessage = msg }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    private func setSyncEnabled(_ inst: Instance, enabled: Bool) async {
        guard let boxIP = inst.boxIP, let index = inst.index else { return }
        do {
            if enabled {
                try await AccountService.shared.enableSync(instanceId: inst.instanceIdForApi, boxIP: boxIP, index: index)
                await MainActor.run { toastMessage = "已开启同步" }
            } else {
                try await AccountService.shared.disableSync(instanceId: inst.instanceIdForApi, boxIP: boxIP, index: index)
                await MainActor.run { toastMessage = "已关闭同步" }
            }
        } catch {
            await MainActor.run { toastMessage = error.localizedDescription }
        }
    }
    
    private func prepareVpcSheet(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        await MainActor.run {
            vpcIp = ""
            vpcPort = ""
            vpcUser = ""
            vpcPwd = ""
            vpcFilterInput = ""
            vpcSelectedCountryCode = nil
            vpcCustomCountryCode = ""
            showCloseVpcConfirm = false
            vpcLoading = false
            vpcCurrentLoading = true
            vpcCurrentQueryTask?.cancel()
            showVpcSheet = inst
        }
        
        if let cached = loadVpcLocalConfig(instanceId: id) {
            await MainActor.run {
                vpcIp = cached.ip
                vpcPort = cached.port
                vpcUser = cached.user
                vpcPwd = cached.pwd
            }
        }
        
        vpcCurrentQueryTask = Task {
            do {
                if let raw = try await AccountService.shared.queryInstanceS5(instanceId: id), !raw.isEmpty {
                    if let m = raw.range(of: #"^socks5://([^:]+):([^@]+)@([^:]+):(\d+)$"#, options: .regularExpression) {
                        let s = String(raw[m])
                        let g = s.replacingOccurrences(of: "socks5://", with: "").split(separator: "@")
                        if g.count == 2 {
                            let up = g[0].split(separator: ":")
                            let hp = g[1].split(separator: ":")
                            if up.count >= 2, hp.count >= 2 {
                                await MainActor.run {
                                    vpcUser = String(up[0])
                                    vpcPwd = String(up[1])
                                    vpcIp = String(hp[0])
                                    vpcPort = String(hp[1])
                                    saveVpcLocalConfig(
                                        instanceId: id,
                                        config: VpcLocalConfig(
                                            ip: String(hp[0]),
                                            port: String(hp[1]),
                                            user: String(up[0]),
                                            pwd: String(up[1])
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
                await MainActor.run { vpcCurrentLoading = false }
            } catch {
                await MainActor.run {
                    vpcCurrentLoading = false
                    toastMessage = "查询当前S5失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    private func applyVpcCountry(_ code: String) {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return }
        let sid = Int.random(in: 10000000...99999999)
        vpcIp = "us.ipwo.net"
        vpcPort = "7878"
        vpcUser = "wudi1_custom_zone_\(normalized)_sid_\(sid)_time_180"
        vpcPwd = "wudi456789"
    }
    
    private func loadVpcLocalConfig(instanceId: Int) -> VpcLocalConfig? {
        guard let map = UserDefaults.standard.dictionary(forKey: vpcLocalCacheKey) as? [String: [String: String]] else {
            return nil
        }
        let key = "\(instanceId)"
        guard let raw = map[key] else { return nil }
        let ip = (raw["ip"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (raw["port"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = raw["user"] ?? ""
        let pwd = raw["pwd"] ?? ""
        guard !ip.isEmpty, !port.isEmpty else { return nil }
        return VpcLocalConfig(ip: ip, port: port, user: user, pwd: pwd)
    }
    
    private func saveVpcLocalConfig(instanceId: Int, config: VpcLocalConfig) {
        var map = UserDefaults.standard.dictionary(forKey: vpcLocalCacheKey) as? [String: [String: String]] ?? [:]
        map["\(instanceId)"] = [
            "ip": config.ip,
            "port": config.port,
            "user": config.user,
            "pwd": config.pwd
        ]
        UserDefaults.standard.set(map, forKey: vpcLocalCacheKey)
    }
    
    private func handleReboot(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        do {
            try await AccountService.shared.rebootInstance(instanceId: id)
            await MainActor.run { toastMessage = "重启请求已发送" }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    private func handleRandomDeviceInfo(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        do {
            try await AccountService.shared.randomDeviceInfo(instanceId: id)
            await MainActor.run { toastMessage = "随机设备信息已提交" }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    private func handleRebuildChat(_ inst: Instance) async {
        guard let id = inst.ID, let boxIP = inst.boxIP, let index = inst.index else { return }
        do {
            try await AccountService.shared.rebuildChat(instanceId: "\(id)", boxIP: boxIP, index: index)
            await MainActor.run {
                toastMessage = "聊天数据重建成功"
                Task { await fetchInstanceList() }
            }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    private func handleDelete(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        do {
            try await AccountService.shared.deleteInstance(instanceId: id)
            await MainActor.run {
                appState.accountInstances = appState.accountInstances.filter { $0.ID != id }
                toastMessage = "删除成功"
            }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    private func handleMove(_ inst: Instance, index: Int) async {
        guard let id = inst.ID else { return }
        do {
            try await AccountService.shared.moveInstance(instanceId: id, index: index)
            await MainActor.run { toastMessage = "移动成功"; Task { await fetchInstanceList() } }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    private func handleReset(_ inst: Instance) async {
        guard let id = inst.ID else { return }
        do {
            try await AccountService.shared.resetInstance(instanceId: id)
            await MainActor.run { toastMessage = "重置请求已发送" }
        } catch { await MainActor.run { toastMessage = error.localizedDescription } }
    }
    
    // MARK: - Sheets
    private func renameSheet(_ inst: Instance) -> some View {
        NavigationView {
            VStack(spacing: 12) {
                TextField("新名称", text: $renameNewName).textFieldStyle(.roundedBorder).padding()
                Spacer()
            }
            .navigationTitle("修改名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showRenameSheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        guard let id = inst.ID else { return }
                        Task {
                            do {
                                try await AccountService.shared.updateInstanceName(instanceId: id, name: renameNewName, reason: "")
                                await MainActor.run { toastMessage = "名称修改成功"; showRenameSheet = nil; Task { await fetchInstanceList() } }
                            } catch { await MainActor.run { toastMessage = error.localizedDescription } }
                        }
                    }
                }
            }
        }
    }
    
    private func vpcSheet(_ inst: Instance) -> some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("说明：安卓内置VPC，等同于H5的S5设置，建议先选择国家自动填充，再检查账号密码后提交。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("代理选择")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("选择国家", selection: $vpcSelectedCountryCode) {
                    Text("请选择国家").tag(String?.none)
                    ForEach(vpcCountryOptions) { item in
                        Text("\(item.name) (\(item.code))").tag(Optional(item.code))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: vpcSelectedCountryCode) { picked in
                    guard let picked else { return }
                    vpcCustomCountryCode = ""
                    applyVpcCountry(picked)
                }
                
                TextField("或输入国家编号（如 US / GB）", text: $vpcCustomCountryCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .onChange(of: vpcCustomCountryCode) { value in
                        let normalized = value
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .uppercased()
                        if value != normalized {
                            vpcCustomCountryCode = normalized
                        }
                        guard !normalized.isEmpty else { return }
                        vpcSelectedCountryCode = nil
                        applyVpcCountry(normalized)
                    }
                
                TextField("S5 IP", text: $vpcIp)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                TextField("端口", text: $vpcPort)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                TextField("用户名", text: $vpcUser)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $vpcPwd)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    showVpcFilterSheet = true
                }) {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("设置VPC过滤域名")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(Color(white: 0.96))
                .cornerRadius(8)
                
                Button(action: {
                    showCloseVpcConfirm = true
                }) {
                    HStack {
                        if vpcLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text(vpcLoading ? "关闭VPC中..." : "关闭VPC")
                        Spacer()
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(Color(white: 0.96))
                .cornerRadius(8)
                .disabled(vpcLoading)
                
                if vpcCurrentLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在加载当前S5配置...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("设置网络(VPC)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { showVpcSheet = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确定") {
                        guard let id = inst.ID else { return }
                        guard !vpcIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !vpcPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            toastMessage = "请填写S5 IP和端口"
                            return
                        }
                        Task {
                            do {
                                try await AccountService.shared.setInstanceS5(instanceId: id, s5ip: vpcIp, s5port: vpcPort, s5user: vpcUser, s5pwd: vpcPwd)
                                saveVpcLocalConfig(
                                    instanceId: id,
                                    config: VpcLocalConfig(
                                        ip: vpcIp.trimmingCharacters(in: .whitespacesAndNewlines),
                                        port: vpcPort.trimmingCharacters(in: .whitespacesAndNewlines),
                                        user: vpcUser,
                                        pwd: vpcPwd
                                    )
                                )
                                await MainActor.run { toastMessage = "VPC 设置成功"; showVpcSheet = nil }
                            } catch { await MainActor.run { toastMessage = error.localizedDescription } }
                        }
                    }
                }
            }
            .confirmationDialog(
                "确认关闭VPC？",
                isPresented: $showCloseVpcConfirm,
                titleVisibility: .visible
            ) {
                Button("确认关闭代理", role: .destructive) {
                    guard let id = inst.ID else { return }
                    Task {
                        await MainActor.run { vpcLoading = true }
                        do {
                            try await AccountService.shared.stopInstanceS5(instanceId: id)
                            await MainActor.run {
                                vpcLoading = false
                                toastMessage = "已关闭VPC，将走本地网络"
                                showVpcSheet = nil
                            }
                        } catch {
                            await MainActor.run {
                                vpcLoading = false
                                toastMessage = error.localizedDescription
                            }
                        }
                    }
                }
                Button("取消", role: .cancel) {
                    showCloseVpcConfirm = false
                }
            } message: {
                Text("是否确认关闭代理，关闭之后将走本地网络。")
            }
            .onDisappear {
                vpcCurrentQueryTask?.cancel()
                vpcCurrentQueryTask = nil
                vpcCurrentLoading = false
                showCloseVpcConfirm = false
            }
        }
    }
    
    private var vpcFilterSheet: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text("每行输入一个域名，提交后会调用和H5一致的 set_s5_filter_url 接口。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $vpcFilterInput)
                    .frame(minHeight: 280)
                    .padding(8)
                    .background(Color(white: 0.98))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.88), lineWidth: 1))
                    .cornerRadius(8)
                Spacer()
            }
            .padding()
            .navigationTitle("设置VPC过滤域名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showVpcFilterSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let id = showVpcSheet?.ID else {
                            showVpcFilterSheet = false
                            return
                        }
                        let list = vpcFilterInput
                            .split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        Task {
                            do {
                                try await AccountService.shared.setInstanceS5FilterUrl(instanceId: id, urlList: list)
                                await MainActor.run {
                                    toastMessage = "过滤域名设置成功"
                                    showVpcFilterSheet = false
                                }
                            } catch {
                                await MainActor.run { toastMessage = error.localizedDescription }
                            }
                        }
                    }
                    .disabled(vpcLoading)
                }
            }
        }
    }
    
    private func imageSheet(_ inst: Instance) -> some View {
        NavigationView {
            List(Array(imageList.enumerated()), id: \.offset) { _, img in
                Button(action: { selectedImageId = img.id }) {
                    HStack {
                        Text(img.name ?? "未知")
                        if selectedImageId == img.id { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("切换镜像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showImageSheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        guard let id = inst.ID, let imgId = selectedImageId else { showImageSheet = nil; return }
                        let img = imageList.first(where: { $0.id == imgId })
                        Task {
                            do {
                                try await AccountService.shared.switchInstanceImage(instanceId: id, imageId: imgId, imageName: img?.name ?? "")
                                await MainActor.run { toastMessage = "切换成功"; showImageSheet = nil; Task { await fetchInstanceList() } }
                            } catch { await MainActor.run { toastMessage = error.localizedDescription } }
                        }
                    }
                }
            }
        }
    }
    
    private func copySheet(_ inst: Instance) -> some View {
        NavigationView {
            VStack(spacing: 12) {
                TextField("目标名称", text: $copyDstName).textFieldStyle(.roundedBorder)
                TextField("目标索引", text: $copyDstIndex).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                TextField("数量", text: $copyCount).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                Spacer()
            }
            .padding()
            .navigationTitle("复制云机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showCopySheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        guard let id = inst.ID, let dstIdx = Int(copyDstIndex), let cnt = Int(copyCount), cnt >= 1 else {
                            toastMessage = "请填写目标索引和数量"; return
                        }
                        Task {
                            do {
                                try await AccountService.shared.copyInstance(instanceId: id, dstName: copyDstName, dstIndex: dstIdx, count: cnt)
                                await MainActor.run { toastMessage = "复制成功"; showCopySheet = nil; Task { await fetchInstanceList() } }
                            } catch { await MainActor.run { toastMessage = error.localizedDescription } }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 容器行：与 H5 一比一（名称去前缀、状态、备注、连接投屏/开关机/任务/更多/进入会话）
private struct ContainerRowView: View {
    let instance: Instance
    var buttonAuth: [String: Int]? = nil
    /// 与 getMenu btns 中「进入会话」类权限一致；false 时不展示按钮
    var showEnterSessionButton: Bool = true
    var isCurrentContainer: Bool = false
    var isConnecting: Bool = false
    var isConnected: Bool = false
    var isStateLoading: Bool = false
    var isEditingRemark: Bool = false
    var editingRemarkValue: String = ""
    var onEditingRemarkChange: (String) -> Void = { _ in }
    var onStartEditRemark: () -> Void = {}
    var onSaveRemark: (String) -> Void = { _ in }
    var onCancelRemark: () -> Void = {}
    var onConnect: () -> Void = {}
    var onToggleState: () -> Void = {}
    var onTask: (String) -> Void = { _ in }
    var onMore: (String) -> Void = { _ in }
    var onEnterSession: () -> Void = {}
    var onTapWsError: () -> Void = {}
    
    private let strongTextColor = Color(white: 0.12)
    private let secondaryTextColor = Color(white: 0.42)
    
    private func hasPermission(_ key: String) -> Bool {
        guard let buttonAuth else { return true }
        return (buttonAuth[key] ?? 0) != 0
    }
    
    private var showConnectButton: Bool { hasPermission("connect_instance") }
    private var showToggleStateButton: Bool { hasPermission("start_instance") }
    private var showTaskMenu: Bool { hasPermission("task_instance") }
    private var showMoreMenu: Bool {
        guard let buttonAuth else { return true }
        let keys = [
            "start_instance",
            "set_vpc", "reboot_instance", "update_name", "random_device_info",
            "switch_image", "move_instance", "reset_instance", "copy_instance",
            "delete_instance", "shell_instance", "files_instance", "paste_upload"
        ]
        return keys.contains { (buttonAuth[$0] ?? 0) != 0 }
    }
    
    private var stateColor: Color {
        let s = (instance.state ?? "").lowercased()
        if s == "running" { return Color(red: 0.30, green: 0.69, blue: 0.31) }  // #4caf50
        if s == "exited" || s == "stopped" { return Color(red: 0.96, green: 0.27, blue: 0.21) }  // #f44336
        return Color(red: 1.0, green: 0.60, blue: 0)  // #ff9800 created
    }
    
    private var stateLabel: String {
        let s = instance.state ?? ""
        if s.lowercased() == "running" { return "运行" }
        if s.lowercased() == "exited" || s.lowercased() == "stopped" { return "关机" }
        return "创建中"
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(stateColor)
                .frame(width: 2)
            
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Button(action: { UIPasteboard.general.string = instance.name ?? "" }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundColor(secondaryTextColor)
                        }
                        Text(formatInstanceName(instance.name))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(strongTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    HStack(spacing: 8) {
                        Text("IP: \(instance.boxIP ?? "-")")
                            .font(.system(size: 11))
                            .foregroundColor(secondaryTextColor)
                        if let idx = instance.index {
                            Text("S\(idx)")
                                .font(.system(size: 11))
                                .foregroundColor(secondaryTextColor)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        if (instance.appType ?? "").lowercased() == "business" {
                            tagView("企业版", Color(red: 0.30, green: 0.69, blue: 0.31))
                        } else {
                            tagView("个人版", Color(red: 1.0, green: 0.60, blue: 0))
                        }
                    }
                    
                    if isEditingRemark {
                        HStack(spacing: 8) {
                            TextField("请输入备注...", text: Binding(get: { editingRemarkValue }, set: onEditingRemarkChange))
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .onSubmit { onSaveRemark(editingRemarkValue) }
                            Button("保存", action: { onSaveRemark(editingRemarkValue) })
                                .font(.system(size: 11))
                                .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            Button("取消", action: onCancelRemark)
                                .font(.system(size: 11))
                                .foregroundColor(secondaryTextColor)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(instance.scrmRemark ?? "暂无备注")
                                .font(.system(size: 11))
                                .foregroundColor(secondaryTextColor)
                            Button(action: onStartEditRemark) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundColor(secondaryTextColor)
                            }
                        }
                    }
                    
                    HStack(spacing: 12) {
                        if showConnectButton {
                            Button(action: onConnect) {
                                HStack(spacing: 4) {
                                    if isConnecting { ProgressView().scaleEffect(0.7) }
                                    Text(isConnected ? "已连接" : "连接")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                                }
                            }
                            .disabled((instance.state ?? "").lowercased() != "running" || isConnecting || isConnected)
                        }
                        
                        if showToggleStateButton {
                            Button(action: onToggleState) {
                                HStack(spacing: 4) {
                                    if isStateLoading { ProgressView().scaleEffect(0.7) }
                                    Text((instance.state ?? "").lowercased() == "running" ? "停止" : "启动")
                                        .font(.system(size: 12))
                                        .foregroundColor((instance.state ?? "").lowercased() == "running" ? Color(red: 0.96, green: 0.27, blue: 0.21) : Color(red: 0.30, green: 0.69, blue: 0.31))
                                }
                            }
                            .disabled(isStateLoading)
                        }
                        
                        if showTaskMenu {
                            Menu {
                                Button("账号互养", action: { onTask("task") })
                                Button("频道养号", action: { onTask("channel_task") })
                                Button("发布动态", action: { onTask("publish_task") })
                                Button("自定义养号", action: { onTask("custom_task") })
                                Button("任务记录", action: { onTask("task_record") })
                            } label: {
                                HStack(spacing: 2) {
                                    Text("任务")
                                        .font(.system(size: 12))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            }
                        }
                        
                        if showMoreMenu {
                            Menu {
                                if hasPermission("set_vpc") {
                                    Button("设置网络（vpc）", action: { onMore("set_vpc") })
                                }
                                if hasPermission("reboot_instance") {
                                    Button("重启云机", action: { onMore("reboot") })
                                        .disabled((instance.state ?? "").lowercased() != "running")
                                }
                                if hasPermission("update_name") {
                                    Button("修改名称", action: { onMore("update_name") })
                                }
                                if hasPermission("random_device_info") {
                                    Button("随机设备信息", action: { onMore("random_device_info") })
                                }
                                if hasPermission("switch_image") {
                                    Button("切换镜像", action: { onMore("switch_image") })
                                }
                                if hasPermission("move_instance") {
                                    Button("移动实例", action: { onMore("move") })
                                }
                                if hasPermission("reset_instance") {
                                    Button("重置云机", action: { onMore("reset") })
                                }
                                if hasPermission("copy_instance") {
                                    Button("复制云机", action: { onMore("copy") })
                                }
                                if hasPermission("delete_instance") {
                                    Button("删除云机", action: { onMore("delete") })
                                }
                                if hasPermission("shell_instance") {
                                    Button("终端窗口", action: { onMore("shell") })
                                        .disabled((instance.state ?? "").lowercased() != "running")
                                }
                                if hasPermission("files_instance") {
                                    Button("文件上传", action: { onMore("files") })
                                        .disabled((instance.state ?? "").lowercased() != "running")
                                }
                                if hasPermission("paste_upload") {
                                    Button("粘贴上传", action: { onMore("paste_upload") })
                                        .disabled((instance.state ?? "").lowercased() != "running")
                                }
                                if hasPermission("start_instance") {
                                    Button("更新Ws", action: { onMore("update_ws") })
                                    Button("重启WS", action: { onMore("restart_ws") })
                                    Button("开启同步", action: { onMore("enable_sync") })
                                    Button("关闭同步", action: { onMore("disable_sync") })
                                    Button("重建聊天数据", action: { onMore("rebuild_chat") })
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text("更多操作")
                                        .font(.system(size: 12))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            }
                        }
                        
                        if showEnterSessionButton {
                            Button(action: onEnterSession) {
                                Text("进入会话")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        if isCurrentContainer {
                            Text("当前")
                                .font(.system(size: 9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.13, green: 0.59, blue: 0.95))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        Circle()
                            .fill(stateColor)
                            .frame(width: 8, height: 8)
                        if let ws = instance.scrmWsStatus, !ws.isEmpty {
                            Text(ws)
                                .font(.system(size: 9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ws == "已登录" ? Color(red: 0.30, green: 0.69, blue: 0.31) : Color(red: 1.0, green: 0.60, blue: 0))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        if (instance.scrmWsError ?? "").isEmpty == false {
                            Button(action: onTapWsError) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        if let n = instance.newMessageCount, n > 0 {
                            Text("\(n)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Color(red: 1.0, green: 0.27, blue: 0.27))
                                .cornerRadius(10)
                        }
                    }
                    Text(stateLabel)
                        .font(.system(size: 9))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.white)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(white: 0.88)),
            alignment: .bottom
        )
    }
    
    private func tagView(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

private struct WebToolView: UIViewRepresentable {
    let title: String
    let urlString: String
    
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        if let url = URL(string: urlString) {
            web.load(URLRequest(url: url))
        }
        return web
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    AccountPlaceholderView(appState: AppState())
}
    