//
//  SessionView.swift
//  WudiApp
//
//  从账号页「进入会话」后展示：当前容器的对话列表 + 联系人列表（与 H5 Index 右侧 panel 一致）
//

import SwiftUI

enum SessionListTab: String, CaseIterable {
    case chats = "对话列表"
    case contacts = "联系人列表"
}

/// iOS 16+ 使用 toolbarBackground 消除导航栏区域白条；iOS 15 依赖 fixNavigationBarBackgroundForIOS15
private struct ToolbarBackgroundIfAvailable: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(color, for: .navigationBar)
        } else {
            content
        }
    }
}

struct SessionView: View {
    @ObservedObject var appState: AppState
    let container: Instance
    
    @State private var activeTab: SessionListTab = .chats
    @State private var chats: [Chat] = []
    @State private var contacts: [Contact] = []
    @State private var chatLoading = false
    @State private var contactsLoading = false
    @State private var chatSearch = ""
    @State private var contactSearch = ""
    @State private var errorMessage: String?
    @State private var showAddContactSheet = false
    @State private var addContactLoading = false
    @State private var newContactPhone = ""
    @State private var newContactLastName = ""
    @State private var newContactFirstName = ""
    @State private var pendingOpenChat: Chat?
    @State private var pendingOpenActive = false
    @State private var pendingOpenInitialMessages: [Message] = []
    @State private var localSyntheticChatsByJid: [String: Chat] = [:]
    
    /// 与 H5 一致，使用 app_type_key 作为 instance_id
    private var instanceId: String { container.instanceIdForApi }
    
    private var filteredChats: [Chat] {
        let q = chatSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return chats }
        return chats.filter {
            (($0.display_name ?? "").lowercased().contains(q)) ||
            (($0.jid ?? "").lowercased().contains(q)) ||
            (($0.phone ?? "").lowercased().contains(q))
        }
    }
    
    private var filteredContacts: [Contact] {
        let q = contactSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return contacts }
        return contacts.filter {
            (($0.display_name ?? "").lowercased().contains(q)) ||
            (($0.number ?? "").lowercased().contains(q)) ||
            (($0.jid ?? "").lowercased().contains(q))
        }
    }
    
    /// 对话项显示未读：接口返回 + WebSocket 增量
    private func unreadCount(for chat: Chat) -> Int {
        let jid = chat.jid ?? ""
        return appState.conversationUnreadCount(
            instanceIdForApi: instanceId,
            jid: jid,
            baseUnreadHint: chat.newMessageCount ?? 0
        )
    }
    
    /// 联系人显示名：备注优先，否则 display_name，否则脱敏手机号，否则脱敏 jid（与 H5 一致）
    private func displayName(for contact: Contact) -> String {
        if let remark = contact.remark_name, !remark.isEmpty { return remark }
        if let name = contact.display_name, !name.isEmpty { return name }
        let masked = maskPhoneOrJid(contact.number)
        if !masked.isEmpty { return masked }
        return maskPhoneOrJid(contact.jid)
    }
    
    /// 与 H5 maskPhoneOrJid 一致：手机号/JID 脱敏，中间 4 位替换为 ****
    private func maskPhoneOrJid(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        let phone: String
        let suffix: String
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            phone = String(parts[0])
            suffix = "@" + (parts.count > 1 ? String(parts[1]) : "")
        } else {
            phone = value
            suffix = ""
        }
        if phone.count <= 4 { return phone + suffix }
        let start = (phone.count - 4) / 2
        let end = start + 4
        let idxStart = phone.index(phone.startIndex, offsetBy: start)
        let idxEnd = phone.index(phone.startIndex, offsetBy: end)
        let masked = String(phone[..<idxStart]) + "****" + String(phone[idxEnd...])
        return masked + suffix
    }
    
    /// 与 H5 Index.vue 一致：0 文本，1 [图片]+text_data，2 [语音]，3/13 [视频]，90 [通话]，9 [文件]
    private func lastMessagePreview(_ chat: Chat) -> String {
        guard let last = chat.last_message else { return "" }
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
    
    /// 与 H5 Index.vue formatTime 一致：年月日 + 时分（zh-CN 风格）
    private func formatTime(_ ts: Int64?) -> String {
        guard let t = ts, t > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(t) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }
    
    /// 页面背景灰，与账号页/全部对话一致（用于导航栏区域填色，避免白条）
    private static let pageBackground = Color(red: 0.96, green: 0.96, blue: 0.96)
    
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
        .onAppear { fixNavigationBarBackgroundForIOS15() }
    }
    
    private var pageContent: some View {
        VStack(spacing: 0) {
            header
            tabBar
            searchBar
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
            }
            listContent
        }
        .background(Self.pageBackground)
        .navigationBarHidden(true)
        .modifier(ToolbarBackgroundIfAvailable(color: Self.pageBackground))
        .task {
            guard appState.canFetchInstanceChatLists else {
                await MainActor.run {
                    errorMessage = "当前账号无查看对话权限"
                }
                return
            }
            await loadBoth()
        }
        .refreshable {
            errorMessage = nil
            guard appState.canFetchInstanceChatLists else { return }
            await refreshCurrentTab()
        }
        .background(programmaticNavigationLink)
        .overlay {
            if showAddContactSheet {
                addContactModal
            }
        }
    }
    
    @ViewBuilder
    private var programmaticNavigationLink: some View {
        NavigationLink(isActive: $pendingOpenActive) {
            if let chat = pendingOpenChat {
                ChatDetailView(
                    appState: appState,
                    container: container,
                    chat: chat,
                    contacts: contacts,
                    forceLatestOnInitialEntry: unreadCount(for: chat) > 0,
                    initialMessages: pendingOpenInitialMessages
                )
                .id("\(container.instanceIdForApi)_\(chat.jid ?? "")")
            } else {
                EmptyView()
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }
    
    /// iOS 15 上 NavigationView 仍会画出白色导航栏区域，用 appearance 把该区域改成页面灰
    private func fixNavigationBarBackgroundForIOS15() {
        let color = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let barAppearance = UINavigationBar.appearance()
        barAppearance.barTintColor = color
        barAppearance.backgroundColor = color
        if #available(iOS 15.0, *) {
            let app = UINavigationBarAppearance()
            app.configureWithOpaqueBackground()
            app.backgroundColor = color
            barAppearance.scrollEdgeAppearance = app
            barAppearance.standardAppearance = app
            barAppearance.compactAppearance = app
        }
    }
    
    /// 不额外加 safeTop，避免顶部预留过大（与全部对话页一致）
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: {
                appState.currentContainer = nil
                appState.selectedTab = .account
            }) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            Text(formatInstanceName(container.name))
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button(action: { showAddContactSheet = true }) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
            }
            .disabled(addContactLoading)
            if activeTab == .chats {
                Button(action: { Task { await loadChats() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .rotationEffect(.degrees(chatLoading ? 360 : 0))
                        .animation(chatLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: chatLoading)
                }
                .disabled(chatLoading)
            } else {
                Button(action: { Task { await loadContacts() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .rotationEffect(.degrees(contactsLoading ? 360 : 0))
                        .animation(contactsLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: contactsLoading)
                }
                .disabled(contactsLoading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }
    
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SessionListTab.allCases, id: \.self) { tab in
                Button(action: { activeTab = tab }) {
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(activeTab == tab ? .semibold : .regular)
                        .foregroundColor(activeTab == tab ? Color(red: 0.09, green: 0.47, blue: 1.0) : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
        .background(Color.white)
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            if activeTab == .chats {
                TextField("搜索对话...", text: $chatSearch)
                    .textFieldStyle(.plain)
            } else {
                TextField("搜索联系人...", text: $contactSearch)
                    .textFieldStyle(.plain)
            }
            if (activeTab == .chats ? chatSearch : contactSearch).isEmpty == false {
                Button(action: {
                    if activeTab == .chats { chatSearch = "" } else { contactSearch = "" }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.95))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white)
    }
    
    @ViewBuilder
    private var listContent: some View {
        if activeTab == .chats {
            chatList
        } else {
            contactList
        }
    }
    
    private var chatList: some View {
        Group {
            if chatLoading && chats.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("加载对话中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if filteredChats.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text(chatSearch.isEmpty ? "暂无对话" : "未找到匹配的对话")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredChats) { chat in
                            Button(action: { openChat(chat) }) {
                                chatRow(chat)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }
    
    /// 与 H5 Index.vue 一致：有联系人头像或对话项头像则显示（优先 contactsAvatarMap[jid] 即 contact.avatar，否则 itemData.avatar），否则占位
    private func avatarView(for chat: Chat) -> some View {
        let contact = chat.jid.flatMap { jid in contacts.first(where: { $0.jid == jid }) }
        let base64 = contact?.avatar ?? chat.avatar
        let image = base64ToImage(base64)
        return Group {
            if let ui = image {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(white: 0.88))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "person").font(.body).foregroundColor(Color(white: 0.4)))
            }
        }
        .frame(width: 40, height: 40)
    }
    
    /// base64 转 UIImage，兼容去空格/换行
    private func base64ToImage(_ base64: String?) -> UIImage? {
        guard let raw = base64, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return UIImage(data: data)
    }
    
    /// 与 H5 Index.vue 对话项一比一：chat-avatar(40) + chat-info(名称/最新消息/时间) + chat-actions(未读角标+置顶图标)
    private func chatRow(_ chat: Chat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 左侧：用户头像（H5：contactsAvatarMap[jid] 或占位）
            avatarView(for: chat)
            // 中间：chat-info（名称 + 最新消息 + 时间，与 H5 一致）
            VStack(alignment: .leading, spacing: 2) {
                Text(displayNameForChat(chat))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .lineLimit(1)
                if let last = chat.last_message {
                    Text(lastMessagePreview(chat).isEmpty ? " " : lastMessagePreview(chat))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.53))
                        .lineLimit(1)
                    if let ts = last.timestamp, ts > 0 {
                        Text(formatTime(ts))
                            .font(.system(size: 8))
                            .foregroundColor(Color(white: 0.53))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 右侧：chat-actions（未读角标 + 置顶图标，与 H5 一致）
            HStack(spacing: 8) {
                if unreadCount(for: chat) > 0 {
                    Text("\(unreadCount(for: chat))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 6)
                        .background(Color(red: 1, green: 0.27, blue: 0.27))
                        .clipShape(Capsule())
                }
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(white: 0.94)).frame(height: 1)
        }
    }
    
    /// 与 H5 一致：备注优先，否则 display_name，否则脱敏手机号，否则脱敏 jid
    private func displayNameForChat(_ chat: Chat) -> String {
        if let jid = chat.jid,
           let contact = contacts.first(where: { $0.jid == jid }) {
            let remark = contact.remark_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !remark.isEmpty { return remark }
            let contactName = contact.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !contactName.isEmpty { return contactName }
        }
        if let name = chat.display_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let maskedPhone = maskPhoneOrJid(chat.phone)
        if !maskedPhone.isEmpty { return maskedPhone }
        return maskPhoneOrJid(chat.jid)
    }
    
    private var contactList: some View {
        Group {
            if contactsLoading && contacts.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("加载联系人中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if filteredContacts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.2")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text(contactSearch.isEmpty ? "暂无联系人" : "未找到匹配的联系人")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 联系人接口可能存在重复/空 jid，避免 Identifiable id 冲突导致行复用错乱和大面积空白
                        ForEach(Array(filteredContacts.enumerated()), id: \.offset) { _, contact in
                            Button(action: { openContact(contact) }) {
                                contactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }
    
    /// 联系人行头像：有 avatar(base64) 则显示，否则占位（与 H5 联系人列表一致）
    private func contactAvatarView(_ contact: Contact) -> some View {
        let image = base64ToImage(contact.avatar)
        return Group {
            if let ui = image {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(white: 0.88))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "person").font(.body).foregroundColor(Color(white: 0.4)))
            }
        }
        .frame(width: 40, height: 40)
    }
    
    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            contactAvatarView(contact)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(for: contact))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .lineLimit(1)
                let sub = maskPhoneOrJid(contact.number).isEmpty ? maskPhoneOrJid(contact.jid) : maskPhoneOrJid(contact.number)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(white: 0.94)).frame(height: 1)
        }
    }
    
    private var addContactModal: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    if !addContactLoading { showAddContactSheet = false }
                }
            VStack(spacing: 12) {
                Text("添加联系人")
                    .font(.headline)
                TextField("手机号（数字，至少7位）", text: $newContactPhone)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                TextField("姓（可选）", text: $newContactLastName)
                    .textFieldStyle(.roundedBorder)
                TextField("名（可选）", text: $newContactFirstName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("取消") {
                        showAddContactSheet = false
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.92))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                    .disabled(addContactLoading)
                    Button(action: {
                        Task { await addContact() }
                    }) {
                        HStack(spacing: 6) {
                            if addContactLoading { ProgressView().tint(.white) }
                            Text(addContactLoading ? "添加中..." : "添加")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(addContactLoading || newContactPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(maxWidth: 340)
            .background(Color.white)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
            .padding(.horizontal, 20)
        }
    }
    
    private func openChat(_ chat: Chat, isPendingSeed: Bool = true) {
        Task {
            let initialMessages: [Message]
            if let chatRowId = chat.chat_row_id, chatRowId > 0 {
                initialMessages = await AppCacheStore.shared.loadMessages(instanceId: instanceId, chatRowId: chatRowId, maxAge: nil) ?? []
            } else {
                initialMessages = []
            }
            await MainActor.run {
                pendingOpenInitialMessages = initialMessages
                pendingOpenChat = chat
                pendingOpenActive = true
                appState.isInChatDetail = true
            }
            await cacheChatForAllChats(chat, persistPendingSeed: isPendingSeed)
        }
    }
    
    private func openContact(_ contact: Contact) {
        if let chat = chats.first(where: { $0.jid == contact.jid }) {
            openChat(chat)
            return
        }
        let jid = (contact.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }
        let phone = (contact.number?.isEmpty == false ? contact.number! : (jid.split(separator: "@").first.map(String.init) ?? ""))
        let synthetic = Chat(
            chat_row_id: nil,
            jid: jid,
            remark_name: contact.remark_name,
            display_name: contact.display_name,
            phone: phone,
            avatar: contact.avatar,
            newMessageCount: 0,
            last_message: LastMessage(message_type: 0, text_data: "新建联系人", timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        )
        if !chats.contains(where: { $0.jid == jid }) {
            chats.insert(synthetic, at: 0)
        }
        localSyntheticChatsByJid[jid] = synthetic
        openChat(synthetic, isPendingSeed: true)
    }
    
    private func addContact() async {
        let phone = newContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = newContactLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = newContactFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.range(of: #"^\d{7,}$"#, options: .regularExpression) != nil else {
            await MainActor.run { errorMessage = "手机号必须是数字且至少7位" }
            return
        }
        if last.contains(" ") || first.contains(" ") {
            await MainActor.run { errorMessage = "姓和名不能包含空格" }
            return
        }
        guard let boxIP = container.boxIP, !boxIP.isEmpty else {
            await MainActor.run { errorMessage = "当前容器IP缺失" }
            return
        }
        await MainActor.run {
            addContactLoading = true
            errorMessage = nil
        }
        defer {
            Task { @MainActor in
                addContactLoading = false
            }
        }
        do {
            let jid = "\(phone)@s.whatsapp.net"
            let nameCombined = "\(last)\(first)".trimmingCharacters(in: .whitespacesAndNewlines)
            let contactName = nameCombined.isEmpty ? phone : nameCombined
            let params = ChatService.CallSCRMFuncParams(
                instanceID: instanceId,
                method: "add_ws_contact",
                name: container.name ?? "",
                ip: boxIP,
                index: container.index ?? 1,
                jid: jid,
                message: "",
                contactName: contactName,
                lastName: last,
                firstName: first,
                emoji: nil,
                quotedIndex: 0,
                quotedText: nil,
                quotedType: nil,
                quotedTimestamp: nil,
                appType: container.appType,
                cloneID: nil,
                targetLang: "",
                imageData: nil,
                imageFileName: nil
            )
            let res = try await ChatService.shared.callSCRMFunc(params)
            guard res.code == 1 else {
                await MainActor.run { errorMessage = "添加联系人失败: \(res.msg ?? "")" }
                return
            }
            let newContact = Contact(
                contact_id: nil,
                jid: jid,
                display_name: contactName,
                number: phone,
                remark_name: contactName,
                avatar: nil,
                is_whatsapp_user: 1
            )
            if !contactName.isEmpty {
                try? await ChatService.shared.updateContactRemarkName(
                    boxIP: boxIP,
                    instanceId: instanceId,
                    jid: jid,
                    remarkName: contactName
                )
            }
            await MainActor.run {
                if !contacts.contains(where: { $0.jid == jid }) {
                    contacts.insert(newContact, at: 0)
                }
                showAddContactSheet = false
                newContactPhone = ""
                newContactLastName = ""
                newContactFirstName = ""
                activeTab = .contacts
            }
            openContact(newContact)
            Task {
                await loadChats()
                await loadContacts()
            }
        } catch {
            await MainActor.run { errorMessage = "添加联系人失败" }
        }
    }
    
    private func cacheChatForAllChats(_ chat: Chat, persistPendingSeed: Bool = false) async {
        guard let jidRaw = chat.jid else { return }
        let jid = jidRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }
        var target = chat
        let currentDisplay = target.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackDisplay = displayNameForChat(target).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentDisplay.isEmpty, !fallbackDisplay.isEmpty {
            target.display_name = fallbackDisplay
        }
        let currentRemark = target.remark_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentRemark.isEmpty {
            let nameToUse = (target.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !nameToUse.isEmpty { target.remark_name = nameToUse }
        }
        let currentPhone = target.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentPhone.isEmpty {
            let jidPhone = jid.split(separator: "@").first.map(String.init) ?? ""
            if !jidPhone.isEmpty { target.phone = jidPhone }
        }
        if target.last_message == nil {
            target.last_message = LastMessage(
                message_type: 0,
                text_data: "新会话",
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
        let key = "\(instanceId)_\(jid)"
        await MainActor.run {
            appState.liveChatSnapshots[key] = LiveChatSnapshot(
                displayName: target.display_name ?? displayNameForChat(target),
                avatarBase64: target.avatar,
                preview: target.last_message?.text_data ?? "新会话",
                timestamp: target.last_message?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
            )
            appState.liveChatSnapshotVersion += 1
        }
        var cached = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
        if let idx = cached.firstIndex(where: { $0.jid == jid }) {
            cached[idx] = target
        } else {
            cached.insert(target, at: 0)
        }
        await AppCacheStore.shared.saveChats(instanceId: instanceId, chats: cached)
        if persistPendingSeed {
            await AppCacheStore.shared.upsertPendingConversation(instanceId: instanceId, chat: target)
        }
    }
    
    private func loadBoth() async {
        await loadChats()
        await loadContacts()
    }
    
    private func refreshCurrentTab() async {
        guard appState.canFetchInstanceChatLists else { return }
        switch activeTab {
        case .chats:
            await loadChats()
        case .contacts:
            await loadContacts()
        }
    }
    
    private func loadChats() async {
        guard appState.canFetchInstanceChatLists else {
            await MainActor.run {
                if chats.isEmpty { errorMessage = "当前账号无查看对话权限" }
            }
            return
        }
        guard !chatLoading else { return }
        await MainActor.run { chatLoading = true; errorMessage = nil }
        defer { Task { @MainActor in chatLoading = false } }
        do {
            let list = try await ChatService.shared.getChats(instanceId: instanceId, boxIP: container.boxIP)
            await MainActor.run {
                var merged = list
                // 服务端尚未返回新建联系人会话时，保留本地临时会话，避免“闪一下就消失”
                for (jid, localChat) in localSyntheticChatsByJid {
                    if merged.contains(where: { $0.jid == jid }) {
                        localSyntheticChatsByJid.removeValue(forKey: jid)
                        Task {
                            await AppCacheStore.shared.removePendingConversation(instanceId: instanceId, jid: jid)
                        }
                    } else {
                        merged.insert(localChat, at: 0)
                    }
                }
                chats = merged
            }
        } catch {
            await MainActor.run {
                // 对齐 H5：下拉刷新失败时保留现有列表，避免每次都出现错误横幅打断浏览
                if chats.isEmpty {
                    errorMessage = "加载对话列表失败"
                }
            }
        }
    }
    
    private func loadContacts() async {
        guard appState.canFetchInstanceChatLists else {
            await MainActor.run {
                if contacts.isEmpty { errorMessage = "当前账号无查看对话权限" }
            }
            return
        }
        guard !contactsLoading else { return }
        await MainActor.run { contactsLoading = true; errorMessage = nil }
        defer { Task { @MainActor in contactsLoading = false } }
        if contacts.isEmpty,
           let cached = await AppCacheStore.shared.loadContacts(instanceId: instanceId, maxAge: nil),
           !cached.isEmpty {
            await MainActor.run { contacts = cached }
        }
        do {
            let list = try await ChatService.shared.getContacts(instanceId: instanceId, boxIP: container.boxIP)
            await MainActor.run { contacts = list }
        } catch {
            await MainActor.run {
                // 已有列表时保留旧数据，避免一次刷新失败给用户“列表坏了”的感知
                if contacts.isEmpty {
                    errorMessage = "加载联系人列表失败"
                }
            }
        }
    }
}
