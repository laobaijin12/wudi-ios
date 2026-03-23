//
//  ChatDetailView.swift
//  WudiApp
//
//  从对话列表点击进入的聊天页面，参考 H5 Index.vue 中间 chat-area：头部（返回+头像+名称+脱敏手机号）+ 消息列表 + 底部输入。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Photos
import AVFoundation
import AudioToolbox
import UIKit

#if DEBUG
private let debugLogEnabled = false
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {
    guard debugLogEnabled else { return }
    print(message())
}
private let translationLogEnabled = false
@inline(__always) private func translationLog(_ message: @autoclosure () -> String) {
    guard translationLogEnabled else { return }
    print("[Translation] \(message())")
}
private let groupUsersLogEnabled = false
@inline(__always) private func groupUsersLog(_ message: @autoclosure () -> String) {
    guard groupUsersLogEnabled else { return }
    print("[GroupUsers] \(message())")
}
private let chatDiagLogEnabled = false
private let historyPageLogEnabled = false
private let chatAnchorLogEnabled = false
private let mentionStateLogEnabled = false
private let chatAutoTranslateOnVisibleEnabled = true
@inline(__always) private func chatDiagLog(_ message: @autoclosure () -> String) {
    guard chatDiagLogEnabled else { return }
    let thread = Thread.isMainThread ? "main" : "bg"
    print("[ChatDiag][\(thread)] \(message())")
}
@inline(__always) private func historyPageLog(_ message: @autoclosure () -> String) {
    guard historyPageLogEnabled else { return }
    let thread = Thread.isMainThread ? "main" : "bg"
    print("[HistoryPage][\(thread)] \(message())")
}
@inline(__always) private func chatAnchorLog(_ message: @autoclosure () -> String) {
    guard chatAnchorLogEnabled else { return }
    let thread = Thread.isMainThread ? "main" : "bg"
    print("[ChatAnchor][\(thread)] \(message())")
}
@inline(__always) private func mentionStateLog(_ message: @autoclosure () -> String) {
    guard mentionStateLogEnabled else { return }
    let thread = Thread.isMainThread ? "main" : "bg"
    print("[MentionState][\(thread)] \(message())")
}
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func translationLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func groupUsersLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func chatDiagLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func historyPageLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func chatAnchorLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func mentionStateLog(_ message: @autoclosure () -> String) {}
private let chatAutoTranslateOnVisibleEnabled = true
#endif

private enum CurrentFirstResponderTracker {
    static weak var current: UIResponder?
    static func capture() -> UIResponder? {
        current = nil
        UIApplication.shared.sendAction(#selector(UIResponder._captureFirstResponder), to: nil, from: nil, for: nil)
        return current
    }
}

private extension UIResponder {
    @objc func _captureFirstResponder() {
        CurrentFirstResponderTracker.current = self
    }
}

private extension View {
    @ViewBuilder
    func chatInteractiveKeyboardDismiss() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

private struct NativeInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HostController {
        let vc = HostController()
        vc.popGestureDelegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: HostController, context: Context) {
        uiViewController.popGestureDelegate = context.coordinator
        uiViewController.refreshInteractivePop()
    }
    
    func makeCoordinator() -> PopGestureDelegate {
        PopGestureDelegate()
    }
    
    final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return t.x > 0 && abs(t.x) >= abs(t.y)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
    
    final class HostController: UIViewController {
        weak var popGestureDelegate: UIGestureRecognizerDelegate?
        
        override func viewDidLoad() {
            super.viewDidLoad()
            refreshInteractivePop()
        }
        
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            refreshInteractivePop()
        }
        
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            refreshInteractivePop()
        }
        
        func refreshInteractivePop() {
            guard let nav = navigationController else { return }
            guard let gesture = nav.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = nav.viewControllers.count > 1
            gesture.delegate = popGestureDelegate
        }
    }
}

struct ChatDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: AppState
    let container: Instance
    let chat: Chat
    /// 从 SessionView 进入时传入；从「全部对话」进入时为空，会在 onAppear 拉取
    let contacts: [Contact]
    let forceLatestOnInitialEntry: Bool
    let initialScrollToMessageID: String?
    
    @State private var loadedContacts: [Contact] = []
    private var effectiveContacts: [Contact] { contacts.isEmpty ? loadedContacts : contacts }
    
    @State private var messages: [Message] = []
    @State private var loading = false
    @State private var didFinishInitialMessageLoad = false
    @State private var inputText = ""
    @State private var errorMessage: String?
    @State private var isLoadingHistory = false
    @State private var hasMoreHistory = true
    @State private var lastHistoryAutoLoadAt: TimeInterval = 0
    @State private var lastHistoryAutoLoadAnchorID: String?
    @State private var showManualHistoryLoadEntry = false
    /// 历史翻译：key_id -> 翻译结果（与 H5 messageTranslations 一致）
    @State private var messageTranslations: [String: String] = [:]
    /// 回复/引用消息（与 H5 quotedMessage 一致，在输入框上方显示预览）
    @State private var quotedMessage: Message?
    /// 正在编辑的消息（与 H5 editingMessage 一致，在输入框上方显示预览）
    @State private var editingMessage: Message?
    /// 表情选择器：当前要对其添加表情的消息
    /// 是否展示相册选择器
    @State private var showPhotoPicker = false
    /// WhatsApp 风格图片选择 Bottom Sheet
    @State private var showRecentMediaPicker = false
    /// 从相册选中的图片（用于预览或发送）
    @State private var selectedImage: UIImage?
    /// WhatsApp 风格图片发送页
    @State private var showImageComposeSheet = false
    /// 图片编辑器展示状态
    @State private var showImageEditor = false
    /// 图片选择后自动进入发送页（仅相册选择路径）
    @State private var autoOpenComposeAfterPicker = false
    /// 从发送页进入编辑后，编辑完成/取消时回到发送页
    @State private var reopenComposeAfterEditing = false
    /// 发送/编辑/点赞中的提交状态，防止重复点击
    @State private var sendingAction = false
    /// 媒体路径异常时已调度刷新过的消息 id（避免重复刷新）
    @State private var pendingMediaRefreshIDs: Set<Int> = []
    /// 临时发送图片（key_id -> UIImage），用于发送中气泡预览
    @State private var tempOutgoingImagesByKeyID: [String: UIImage] = [:]
    /// 是否已完成首次定位（底部或记忆位置）
    @State private var didInitialPositioning = false
    /// 当前与底部距离（用于显示「回到底部」按钮）
    @State private var bottomDistance: CGFloat = 0
    /// 当前消息区域可视高度
    @State private var messageViewportHeight: CGFloat = 0
    /// 当前会话中用户是否主动滚动过消息区（用于控制历史自动加载与锚点恢复）
    @State private var hasUserScrolledInSession = false
    /// 当前位置锚点（接近顶部的消息 id）
    @State private var currentAnchorMessageID: String?
    @State private var scrollToBottomRequestToken: Int = 0
    @State private var scrollToBottomImmediateRequestToken: Int = 0
    @State private var scrollToMessageRequestToken: Int = 0
    @State private var pendingScrollToMessageID: String?
    @State private var keyboardAnimationDuration: Double = 0.25
    @State private var keyboardIsVisible = false
    @State private var keyboardPendingSnapToBottom = false
    @State private var pendingBottomSnapWorkItem: DispatchWorkItem?
    @State private var bottomSnapRetryGeneration: Int = 0
    @State private var keyboardTransitioning = false
    @FocusState private var inputFocused: Bool
    @State private var showCustomerPanel = false
    @State private var customerNameText = ""
    @State private var customerRemarkText = ""
    @State private var customerAgeText = ""
    @State private var customerSourceText = ""
    @State private var customerIndustryText = ""
    @State private var customerOccupationText = ""
    @State private var customerFamilyStatusText = ""
    @State private var customerAnnualIncomeText = ""
    @State private var followUpRecords: [CustomerFollowUpRecord] = []
    @State private var showFollowUpEditor = false
    @State private var editingFollowUpID: String?
    @State private var followUpEditorOwnerName = ""
    @State private var followUpEditorText = ""
    @State private var pendingDeleteFollowUpID: String?
    @State private var customerPanelFeedbackText: String?
    @State private var customerPanelFeedbackIsError = false
    @State private var customerPanelFeedbackDismissTask: Task<Void, Never>?
    @State private var didRunEntrySideEffects = false
    @State private var didKickoffInitialLoad = false
    @State private var resolvedChatRowId: Int?
    @State private var showFavoritesPicker = false
    @State private var favoriteTab: String = "script"
    @State private var favoriteSearchText = ""
    @State private var favoriteScripts: [QuickScriptTemplate] = []
    @State private var favoriteImages: [QuickImageTemplate] = []
    @State private var previewRequest: PreviewImageRequest?
    @State private var pendingDeleteMessage: Message?
    @State private var deletingMessageIDs: Set<String> = []
    @State private var messageActionTarget: Message?
    @State private var showForwardConversationPicker = false
    @State private var pendingForwardPayload: ForwardPayload?
    @State private var translationWarmupTask: Task<Void, Never>?
    @State private var translationBatchTask: Task<Void, Never>?
    @State private var translationPendingKeys: [String] = []
    @State private var translationInFlightKeys: Set<String> = []
    @State private var visibleMessageIDs: Set<String> = []
    @State private var visibleTranslationScheduleTask: Task<Void, Never>?
    @State private var thumbWarmupTask: Task<Void, Never>?
    @State private var thumbVisiblePrefetchTask: Task<Void, Never>?
    @State private var mediaPriorityWarmupTask: Task<Void, Never>?
    @State private var showQuickToolsDrawer = false
    @State private var quickToolsShouldRestoreInputFocus = false
    @State private var prioritizedMessageIDs: Set<String> = []
    @State private var pendingOutgoingPayloadByKeyID: [String: PendingOutgoingPayload] = [:]
    @State private var pendingRestoreAnchorMessageID: String?
    @State private var forceScrollToLatestOnEntry = false
    @State private var highlightedMessageID: String?
    @State private var clearHighlightTask: Task<Void, Never>?
    @State private var didApplyInitialScrollTarget = false
    @State private var shouldLockToBottomOnEntry = false
    @State private var entryBottomCorrectionTask: Task<Void, Never>?
    @State private var outgoingStatusSyncTask: Task<Void, Never>?
    @State private var outgoingStatusSyncInFlight = false
    @State private var failedOutgoingReasonByMessageID: [String: String] = [:]
    @State private var failedOutgoingDetailText: String?
    @State private var incomingMessageSyncTask: Task<Void, Never>?
    @State private var groupUsers: [GroupUser] = []
    @State private var groupUsersLoading = false
    @State private var groupUsersSearchText = ""
    @State private var showGroupUsersSheet = false
    @State private var groupUsersPrefetchTask: Task<Void, Never>?
    @State private var showAddGroupMembersSheet = false
    @State private var addMemberSearchText = ""
    @State private var addMemberSelectedJIDs: Set<String> = []
    @State private var addMemberSubmitting = false
    @State private var mentionVisible = false
    @State private var mentionTriggerIndex = -1
    @State private var mentionCursorIndex = 0
    @State private var mentionKeyword = ""
    @State private var mentionManualClosedIndex = -1
    @State private var pendingMentionTokens: [PendingMentionToken] = []
    @State private var runningTaskPromptContext: RunningTaskPromptContext?
    @State private var onboardingStep: ChatOnboardingStep?
    @State private var onboardingSwipeHintAnimating = false
    @State private var lastVisibleFramesApplyAt: TimeInterval = 0
    private let chatOnboardingShownKey = "guide_chat_detail_v1"
    
    private struct PendingOutgoingPayload {
        let text: String
        let encodedText: String?
        let hasImage: Bool
        let quoted: QuotedMessage?
    }

    private struct PendingMentionToken: Identifiable, Equatable {
        let id: String
        let rawToken: String
        let mentionID: String
        let displayName: String
    }

    init(
        appState: AppState,
        container: Instance,
        chat: Chat,
        contacts: [Contact],
        forceLatestOnInitialEntry: Bool = false,
        initialMessages: [Message] = [],
        initialScrollToMessageID: String? = nil
    ) {
        self.appState = appState
        self.container = container
        self.chat = chat
        self.contacts = contacts
        self.forceLatestOnInitialEntry = forceLatestOnInitialEntry
        self.initialScrollToMessageID = initialScrollToMessageID
        self._messages = State(initialValue: initialMessages)
    }
    
    private struct RunningTaskPromptContext {
        let taskID: String?
        let continuation: CheckedContinuation<Bool, Never>
    }
    
    private enum ChatOnboardingStep: Int, CaseIterable {
        case longPressMessage
        case tapAvatar
        case openToolsDrawer
        case translationDoTranslate
        case translationEnter
        
        var title: String {
            switch self {
            case .longPressMessage: return "长按消息查看更多操作"
            case .tapAvatar: return "点击头像设置备注与客户画像"
            case .openToolsDrawer: return "右侧边缘左滑呼出工具页"
            case .translationDoTranslate: return "先试一次翻译"
            case .translationEnter: return "翻译内容可一键回填输入框"
            }
        }
        
        var detail: String {
            switch self {
            case .longPressMessage: return "先试一次长按消息，可打开回复/转发/复制等更多操作。"
            case .tapAvatar: return "再点击顶部头像，可进入备注与客户画像设置。"
            case .openToolsDrawer: return "从右边缘向左拖拽，可以快速打开工具页。"
            case .translationDoTranslate: return "工具页里先随便输入内容，然后点击翻译按钮。"
            case .translationEnter: return "在翻译工具里点回车按钮，可直接把译文填到聊天输入框。"
            }
        }
        
        var waitHint: String {
            switch self {
            case .longPressMessage: return "等待：长按任意消息"
            case .tapAvatar: return "等待：点击一次头像"
            case .openToolsDrawer: return "等待：右侧拖拽打开工具"
            case .translationDoTranslate: return "等待：点击翻译按钮"
            case .translationEnter: return "等待：点击翻译回车按钮"
            }
        }
        
        var next: ChatOnboardingStep? {
            ChatOnboardingStep(rawValue: rawValue + 1)
        }
    }
    
    private enum ChatOnboardingEvent {
        case didLongPressMessage
        case didTapAvatar
        case didOpenToolsDrawer
        case didTapTranslateButton
        case didTapTranslationEnter
    }
    
    private struct PreviewImageRequest: Identifiable {
        let id = UUID().uuidString
        let items: [PreviewGalleryItem]
        let initialIndex: Int
        let initialImage: UIImage?
    }
    
    private enum ForwardPayload {
        case image(UIImage)
        case text(String)
    }
    
    private enum SendButtonVisualState {
        case disabled
        case ready
        case sending
    }
    
    private var conversationKey: String { "\(instanceId)_\(chat.jid ?? "")" }
    private var conversationUnreadCount: Int {
        let jid = chat.jid ?? ""
        guard !jid.isEmpty else { return 0 }
        return appState.conversationUnreadCount(
            instanceIdForApi: instanceId,
            jid: jid,
            baseUnreadHint: chat.newMessageCount ?? 0
        )
    }
    private var customerPhone: String? {
        if let p = chat.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
        guard let jid = chat.jid else { return nil }
        let raw = jid.split(separator: "@").first.map(String.init) ?? jid
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    private var customerSyncContext: CustomerSyncContext {
        CustomerSyncContext(
            conversationKey: conversationKey,
            boxIP: container.boxIP,
            instanceId: instanceId,
            jid: chat.jid,
            phone: customerPhone
        )
    }
    
    private func makeQuotedMessage(from msg: Message?) -> QuotedMessage? {
        guard let msg else { return nil }
        return QuotedMessage(
            message_id: msg.message_id,
            key_id: msg.key_id,
            from_me: msg.from_me,
            key_from_me: msg.key_from_me,
            data: msg.text_data,
            text_data: msg.text_data,
            timestamp: msg.timestamp,
            message_type: msg.message_type,
            sender: msg.sender,
            sender_name: msg.sender_name,
            media_file_path: msg.media_file_path,
            media_url: msg.media_url,
            media_key: msg.media_key,
            reaction: msg.reaction
        )
    }
    
    /// 与 H5 ReactionPicker 一致的 6 个表情
    private static let reactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    
    /// 与 H5 一致，使用 app_type_key 作为 instance_id
    private var instanceId: String { container.instanceIdForApi }
    private var boxIP: String? { container.boxIP }
    private var chatRowId: Int { resolvedChatRowId ?? chat.chat_row_id ?? 0 }
    
    private func displayName() -> String {
        let localRemark = customerRemarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localRemark.isEmpty { return localRemark }
        if let jid = chat.jid,
           let contact = effectiveContacts.first(where: { $0.jid == jid }),
           let remark = contact.remark_name, !remark.isEmpty { return remark }
        if let remark = chat.remark_name?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
            return remark
        }
        if let name = chat.display_name, !name.isEmpty { return name }
        let masked = maskPhoneOrJid(chat.phone)
        if !masked.isEmpty { return masked }
        return maskPhoneOrJid(chat.jid)
    }
    
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
        return String(phone[..<idxStart]) + "****" + String(phone[idxEnd...]) + suffix
    }
    
    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private func logPosition(_ message: String) {
        #if DEBUG
        let chatPositionLoggingEnabled = false
        if chatPositionLoggingEnabled {
            debugLog("[ChatPos][\(conversationKey)] \(message)")
        }
        #endif
    }
    
    private func scheduleBottomSnap(animated: Bool, delay: Double = 0) {
        pendingBottomSnapWorkItem?.cancel()
        let work = DispatchWorkItem {
            if animated {
                scrollToBottomRequestToken += 1
            } else {
                scrollToBottomImmediateRequestToken += 1
            }
        }
        pendingBottomSnapWorkItem = work
        let safeDelay = max(0, delay)
        if safeDelay <= 0.0001 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay, execute: work)
        }
    }
    
    private func requestBottomSnapForInputFocus() {
        guard didInitialPositioning, didFinishInitialMessageLoad, !messages.isEmpty else { return }
        // 输入聚焦时优先无动画贴底，避免与键盘动画叠加导致“先抖后归位”。
        scheduleBottomSnap(animated: false, delay: 0)
        scheduleBottomSnapReliably(primaryAnimated: false, correctionDelay: 0.06, finalDelay: 0.16)
    }
    
    private func scheduleBottomSnapReliably(primaryAnimated: Bool, correctionDelay: Double, finalDelay: Double) {
        bottomSnapRetryGeneration += 1
        let generation = bottomSnapRetryGeneration
        
        func fire(_ animated: Bool, _ delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
                guard bottomSnapRetryGeneration == generation else { return }
                if animated {
                    scrollToBottomRequestToken += 1
                } else {
                    scrollToBottomImmediateRequestToken += 1
                }
            }
        }
        
        fire(primaryAnimated, 0)
        fire(false, correctionDelay)
        fire(false, finalDelay)
    }

    private func scheduleEntryBottomCorrections() {
        guard shouldLockToBottomOnEntry else { return }
        entryBottomCorrectionTask?.cancel()
        entryBottomCorrectionTask = Task {
            let delays: [UInt64] = [80_000_000, 240_000_000, 520_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                await MainActor.run {
                    scrollToBottomImmediateRequestToken &+= 1
                    chatAnchorLog("entryBottomCorrection conversation=\(conversationKey) delayMs=\(delay / 1_000_000)")
                }
            }
        }
    }
    
    private func keyboardTransitionDuration(_ note: Notification) -> Double {
        guard let raw = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber else {
            return 0.25
        }
        let value = raw.doubleValue
        if value.isNaN || value <= 0 { return 0.25 }
        return value
    }

    @MainActor
    private func updateMessageVisibility(_ id: String, isVisible: Bool) {
        guard !id.isEmpty else { return }
        var next = visibleMessageIDs
        let changed: Bool
        if isVisible {
            changed = next.insert(id).inserted
        } else {
            changed = next.remove(id) != nil
        }
        guard changed else { return }
        visibleMessageIDs = next
        if !next.isEmpty {
            scheduleVisibleThumbPrefetch(for: next)
            if chatAutoTranslateOnVisibleEnabled {
                scheduleVisibleTranslation(for: Array(next))
            }
        }
        let anchor = messages.first(where: { next.contains($0.id) })?.id
        if currentAnchorMessageID != anchor {
            currentAnchorMessageID = anchor
        }
        if isVisible {
            Task { await triggerAutoLoadOlderIfNeeded() }
        }
    }
    
    private func avatarImage() -> UIImage? {
        let contact = chat.jid.flatMap { jid in effectiveContacts.first(where: { $0.jid == jid }) }
        let base64 = contact?.avatar ?? chat.avatar
        guard let raw = base64, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return UIImage(data: data)
    }

    private func contactAvatarImage(for jid: String?) -> UIImage? {
        let cleanJid = (jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanJid.isEmpty else { return nil }
        let normalizedTarget = normalizedJidUser(cleanJid)
        let matched = effectiveContacts.first(where: { contact in
            let cjid = (contact.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cjid == cleanJid && !(contact.avatar ?? "").isEmpty
        }) ?? effectiveContacts.first(where: { contact in
            let cjid = (contact.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cnum = normalizedJidUser(contact.number)
            return !(contact.avatar ?? "").isEmpty
                && (!normalizedTarget.isEmpty && (normalizedJidUser(cjid) == normalizedTarget || cnum == normalizedTarget))
        })
        guard let raw = matched?.avatar, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return UIImage(data: data)
    }

    private func loadContactsIfNeeded() async {
        if !effectiveContacts.isEmpty { return }
        let ip = boxIP?.trimmingCharacters(in: .whitespacesAndNewlines)
        chatDiagLog("loadContactsIfNeeded start conversation=\(conversationKey) boxIP=\(ip ?? "nil")")
        do {
            let list = try await ChatService.shared.getContacts(instanceId: instanceId, boxIP: ip)
            await MainActor.run {
                loadedContacts = list
            }
            groupUsersLog("contacts loaded for avatars count=\(list.count)")
            chatDiagLog("loadContactsIfNeeded success conversation=\(conversationKey) loadedContacts=\(list.count)")
        } catch {
            groupUsersLog("contacts load failed err=\(error.localizedDescription)")
            chatDiagLog("loadContactsIfNeeded failed conversation=\(conversationKey) error=\(error.localizedDescription)")
        }
    }
    
    private func formatTime(_ ts: Int64?) -> String {
        guard let t = ts, t > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(t) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f.string(from: date)
    }
    
    private func isOutgoing(_ msg: Message) -> Bool {
        (msg.from_me ?? 0) != 0 || (msg.key_from_me ?? 0) != 0
    }
    
    private func messageBody(_ msg: Message) -> String {
        let renderedText = renderedMessageText(msg.text_data)
        switch msg.message_type {
        case 0: return renderedText
        case 1: return renderedText.isEmpty ? "[图片]" : "[图片] " + renderedText
        case 2: return "[语音]"
        case 3, 13: return "[视频]"
        case 9: return "[文件]"
        case 90: return "[通话]"
        case 15: return renderedText.isEmpty ? "该消息已删除" : renderedText
        default: return renderedText.isEmpty ? "[消息]" : renderedText
        }
    }

    private func renderedMessageText(_ raw: String?) -> String {
        let source = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }
        let pattern = "@?\\[\\[MENTION\\|([^|\\]]+)\\|([^|\\]]*)\\]\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return source
        }
        let ns = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }
        var rendered = source
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let idPart = ns.substring(with: match.range(at: 1))
            let namePart = ns.substring(with: match.range(at: 2))
            let decodedID = idPart.removingPercentEncoding ?? idPart
            let decodedName = namePart.removingPercentEncoding ?? namePart
            let label = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = decodedID.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = "@\((label.isEmpty ? fallback : label))"
            if let range = Range(match.range(at: 0), in: rendered) {
                rendered.replaceSubrange(range, with: replacement)
            }
        }
        return rendered
    }

    private func containsMentionMarkup(_ raw: String?) -> Bool {
        let source = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return false }
        return source.contains("[[MENTION|")
    }

    private func shouldTraceMentionMessage(_ msg: Message) -> Bool {
        containsMentionMarkup(msg.text_data) || renderedMessageText(msg.text_data).contains("@")
    }
    
    private var isGroupConversation: Bool {
        (chat.jid ?? "").hasSuffix("@g.us")
    }
    
    private func normalizedJidUser(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "" }
        if raw.contains("@") {
            return raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        }
        return raw
    }
    
    private func groupSenderDisplay(for msg: Message) -> String {
        let senderJidOrPhone = (msg.sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let senderUser = normalizedJidUser(senderJidOrPhone)
        let senderName = (msg.sender_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !senderJidOrPhone.isEmpty {
            if let member = groupUsers.first(where: {
                (($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == senderJidOrPhone)
                    || (normalizedJidUser($0.jid) == senderUser && !senderUser.isEmpty)
            }) {
                let remark = (member.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !remark.isEmpty { return remark }
                let name = (member.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
                let maskedMember = maskPhoneOrJid(member.jid)
                if !maskedMember.isEmpty { return maskedMember }
            }
        }
        
        if !senderJidOrPhone.isEmpty {
            if let contact = effectiveContacts.first(where: { ($0.jid ?? "") == senderJidOrPhone }) {
                let remark = (contact.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !remark.isEmpty { return remark }
                let name = (contact.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
            if !senderUser.isEmpty {
                if let contact = effectiveContacts.first(where: {
                    normalizedJidUser($0.jid) == senderUser || normalizedJidUser($0.number) == senderUser
                }) {
                    let remark = (contact.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remark.isEmpty { return remark }
                    let name = (contact.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { return name }
                }
            }
        }
        
        if !senderName.isEmpty, senderName.lowercased() != "unknown" {
            return senderName
        }
        let masked = maskPhoneOrJid(senderJidOrPhone)
        if !masked.isEmpty { return masked }
        return "群成员"
    }
    
    private func groupSenderColor(for msg: Message) -> Color {
        let seedRaw = (msg.sender ?? msg.sender_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = seedRaw.isEmpty ? "group_sender_default" : seedRaw
        let palette: [Color] = [
            Color(red: 0.12, green: 0.52, blue: 0.92),
            Color(red: 0.11, green: 0.64, blue: 0.46),
            Color(red: 0.83, green: 0.42, blue: 0.16),
            Color(red: 0.58, green: 0.36, blue: 0.87),
            Color(red: 0.07, green: 0.63, blue: 0.72),
            Color(red: 0.78, green: 0.28, blue: 0.44)
        ]
        var hash: UInt32 = 2166136261
        for b in seed.utf8 {
            hash = (hash ^ UInt32(b)) &* 16777619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
    
    private var groupMentionUsers: [GroupUser] {
        groupUsers.filter {
            let jid = ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !jid.isEmpty && jid != "me"
        }
    }
    
    private var filteredMentionUsers: [GroupUser] {
        let keyword = mentionKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return groupMentionUsers }
        return groupMentionUsers.filter { user in
            let display = mentionDisplayName(for: user).lowercased()
            let jid = (user.jid ?? "").lowercased()
            let shortJid = normalizedJidUser(user.jid).lowercased()
            let number = (resolveGroupUserContact(user)?.number ?? "").lowercased()
            return display.contains(keyword) || jid.contains(keyword) || shortJid.contains(keyword) || number.contains(keyword)
        }
    }
    
    private var showMentionPanel: Bool {
        isGroupConversation && mentionVisible && !groupMentionUsers.isEmpty
    }

    private var filteredAddMemberContacts: [Contact] {
        let keyword = addMemberSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingJIDs = Set(groupUsers.compactMap { ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) })
        return effectiveContacts.filter { contact in
            let jid = (contact.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty else { return false }
            guard !jid.hasSuffix("@g.us") else { return false }
            guard !existingJIDs.contains(jid) else { return false }
            if keyword.isEmpty { return true }
            let name = (contact.display_name ?? "").lowercased()
            let remark = (contact.remark_name ?? "").lowercased()
            let number = (contact.number ?? "").lowercased()
            let lowerJid = jid.lowercased()
            return name.contains(keyword) || remark.contains(keyword) || number.contains(keyword) || lowerJid.contains(keyword)
        }
    }
    
    private func mentionDisplayName(for user: GroupUser) -> String {
        let preferred = groupUserPreferredName(for: user)
        if !preferred.isEmpty { return preferred }
        let masked = maskPhoneOrJid(user.jid)
        if !masked.isEmpty { return masked }
        return "+"
            + normalizedJidUser(user.jid)
    }

    private func resolveGroupUserContact(_ user: GroupUser) -> Contact? {
        let memberJid = (user.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memberJid.isEmpty else { return nil }
        if let exact = effectiveContacts.first(where: {
            (($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == memberJid)
        }) {
            return exact
        }
        let normalized = normalizedJidUser(memberJid)
        guard !normalized.isEmpty else { return nil }
        return effectiveContacts.first(where: { contact in
            normalizedJidUser(contact.jid) == normalized || normalizedJidUser(contact.number) == normalized
        })
    }

    private func groupUserPreferredName(for user: GroupUser) -> String {
        if let contact = resolveGroupUserContact(user) {
            let cRemark = (contact.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cRemark.isEmpty { return cRemark }
        }
        let gRemark = (user.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gRemark.isEmpty { return gRemark }
        if let contact = resolveGroupUserContact(user) {
            let cName = (contact.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cName.isEmpty { return cName }
        }
        let gName = (user.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gName.isEmpty { return gName }
        return ""
    }
    
    private func findMentionTrigger(in text: String, cursorPos: Int) -> (index: Int, keyword: String)? {
        guard cursorPos > 0 else { return nil }
        let chars = Array(text)
        var i = cursorPos - 1
        while i >= 0 {
            let ch = chars[i]
            if ch == "@" {
                if i > 0 && !chars[i - 1].isWhitespace {
                    return nil
                }
                let keyword = String(chars[(i + 1)..<cursorPos])
                if keyword.contains(where: { $0.isWhitespace }) {
                    return nil
                }
                return (i, keyword)
            }
            if ch.isWhitespace {
                break
            }
            i -= 1
        }
        return nil
    }
    
    private func updateMentionState(for text: String, cursorPos: Int) {
        let safeCursorPos = max(0, min(cursorPos, text.count))
        guard isGroupConversation, !groupMentionUsers.isEmpty else {
            mentionVisible = false
            mentionTriggerIndex = -1
            mentionCursorIndex = 0
            mentionKeyword = ""
            mentionManualClosedIndex = -1
            return
        }
        guard let trigger = findMentionTrigger(in: text, cursorPos: safeCursorPos) else {
            mentionVisible = false
            mentionTriggerIndex = -1
            mentionCursorIndex = 0
            mentionKeyword = ""
            mentionManualClosedIndex = -1
            return
        }
        mentionTriggerIndex = trigger.index
        mentionCursorIndex = safeCursorPos
        mentionKeyword = trigger.keyword
        mentionVisible = mentionManualClosedIndex != trigger.index
    }
    
    private func closeMentionPanel() {
        mentionVisible = false
        mentionManualClosedIndex = mentionTriggerIndex
    }
    
    private func resetMentionComposerState() {
        mentionVisible = false
        mentionTriggerIndex = -1
        mentionCursorIndex = 0
        mentionKeyword = ""
        mentionManualClosedIndex = -1
    }

    private func selectMention(_ user: GroupUser) {
        let name = mentionDisplayName(for: user).trimmingCharacters(in: .whitespacesAndNewlines)
        let mentionJid = (user.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !mentionJid.isEmpty, mentionTriggerIndex >= 0 else { return }
        let text = inputText
        let safeStart = max(0, min(mentionTriggerIndex, text.count))
        let safeEnd = max(safeStart, min(mentionCursorIndex, text.count))
        let start = text.index(text.startIndex, offsetBy: safeStart)
        let end = text.index(text.startIndex, offsetBy: safeEnd)
        let prefix = String(text[..<start])
        let suffix = String(text[end...])
        let rawToken = "@\(name) "
        inputText = prefix + rawToken + suffix
        pendingMentionTokens.append(
            PendingMentionToken(
                id: UUID().uuidString,
                rawToken: rawToken,
                mentionID: mentionJid,
                displayName: name
            )
        )
        resetMentionComposerState()
    }
    
    private func selectMentionAll() {
        guard mentionTriggerIndex >= 0 else { return }
        let text = inputText
        let safeStart = max(0, min(mentionTriggerIndex, text.count))
        let safeEnd = max(safeStart, min(mentionCursorIndex, text.count))
        let start = text.index(text.startIndex, offsetBy: safeStart)
        let end = text.index(text.startIndex, offsetBy: safeEnd)
        let prefix = String(text[..<start])
        let suffix = String(text[end...])
        let rawToken = "@所有人 "
        inputText = prefix + rawToken + suffix
        pendingMentionTokens.append(
            PendingMentionToken(
                id: UUID().uuidString,
                rawToken: rawToken,
                mentionID: "all",
                displayName: "所有人"
            )
        )
        resetMentionComposerState()
    }

    private func encodedMentionPlaceholder(mentionID: String, displayName: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedID = mentionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? mentionID
        let encodedName = displayName.addingPercentEncoding(withAllowedCharacters: allowed) ?? displayName
        return "[[MENTION|\(encodedID)|\(encodedName)]]"
    }

    private func composeOutgoingTextWithMentions(_ text: String) -> String {
        guard isGroupConversation, !pendingMentionTokens.isEmpty else { return text }
        var composed = text
        var consumedIDs = Set<String>()
        for token in pendingMentionTokens {
            guard !consumedIDs.contains(token.id) else { continue }
            guard composed.contains(token.rawToken) else { continue }
            let placeholder = encodedMentionPlaceholder(mentionID: token.mentionID, displayName: token.displayName)
            composed = composed.replacingOccurrences(of: token.rawToken, with: placeholder, options: [], range: composed.range(of: token.rawToken))
            consumedIDs.insert(token.id)
        }
        return composed
    }

    private func syncPendingMentionTokens(for text: String) {
        guard !pendingMentionTokens.isEmpty else { return }
        var remaining = text
        pendingMentionTokens = pendingMentionTokens.filter { token in
            guard let range = remaining.range(of: token.rawToken) else { return false }
            remaining.removeSubrange(range)
            return true
        }
    }

    private func normalizedPhoneForGroupMember(_ jid: String?) -> String {
        let normalized = normalizedJidUser(jid)
        return normalized.filter { $0.isNumber }
    }

    private func currentInputCursorPosition(in text: String) -> Int? {
        guard let responder = CurrentFirstResponderTracker.capture() else { return nil }
        if let field = responder as? UITextField, let selected = field.selectedTextRange {
            let offset = field.offset(from: field.beginningOfDocument, to: selected.start)
            return max(0, min(offset, text.count))
        }
        if let textView = responder as? UITextView {
            return max(0, min(textView.selectedRange.location, text.count))
        }
        return nil
    }
    
    private var boxIPForMedia: String { container.boxIP ?? "" }
    private var indexForMedia: Int { container.index ?? 1 }
    private var trimmedInputText: String { inputText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSendNow: Bool { !trimmedInputText.isEmpty || selectedImage != nil }
    private var sendButtonVisualState: SendButtonVisualState {
        if sendingAction { return .sending }
        return canSendNow ? .ready : .disabled
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部：与 H5 chat-header 一致（返回 + 头像 + 名称 + 脱敏手机号）
            HStack(spacing: 12) {
                Button(action: {
                    inputFocused = false
                    withAnimation(.easeOut(duration: 0.18)) {
                        appState.isInChatDetail = false
                    }
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .symbolRenderingMode(.monochrome)
                        .font(.body.weight(.semibold))
                        .foregroundColor(Color(white: 0.12))
                        .frame(width: 44, height: 44, alignment: .center)
                }
                if let img = avatarImage() {
                    Button(action: onTapAvatar) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onTapAvatar) {
                        Circle()
                            .fill(Color(white: 0.88))
                            .frame(width: 40, height: 40)
                            .overlay(Image(systemName: "person").foregroundColor(Color(white: 0.4)))
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName())
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(Color(white: 0.12))
                            .lineLimit(1)
                        if (chat.jid ?? "").hasSuffix("@g.us") {
                            Text("群组")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.2, green: 0.56, blue: 0.96))
                                .clipShape(Capsule())
                        }
                    }
                    Text(maskPhoneOrJid(chat.jid))
                        .font(.caption)
                        .foregroundColor(Color(white: 0.42))
                        .lineLimit(1)
                }
                if isGroupConversation {
                    Button(action: openGroupUsersPanel) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Color(white: 0.28))
                                .frame(width: 34, height: 34)
                                .background(Color(white: 0.94))
                                .clipShape(Circle())
                            if groupUsers.count > 0 {
                                Text("\(groupUsers.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.09, green: 0.47, blue: 1.0))
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("群成员")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(white: 0.94)).frame(height: 1)
            }
            
            // 消息区域
            ZStack {
                Color(white: 0.97)
                if (loading || !didFinishInitialMessageLoad) && messages.isEmpty {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didFinishInitialMessageLoad && messages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("暂无消息")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if hasMoreHistory {
                                    Color.clear
                                        .frame(height: 1)
                                        .onAppear {
                                            Task { await triggerAutoLoadOlderIfNeeded() }
                                        }
                                }
                                ForEach(messages) { msg in
                                    messageRow(msg, prioritizeMediaLoad: prioritizedMessageIDs.contains(msg.id))
                                        .id(msg.id)
                                        .onAppear {
                                            Task { @MainActor in
                                                promoteMessageForMediaLoad(id: msg.id)
                                                updateMessageVisibility(msg.id, isVisible: true)
                                            }
                                        }
                                        .onDisappear {
                                            Task { @MainActor in
                                                updateMessageVisibility(msg.id, isVisible: false)
                                            }
                                        }
                                }
                                Color.clear
                                    .frame(height: 0.5)
                                    .id("chatBottom")
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: ChatBottomOffsetPreferenceKey.self,
                                                value: geo.frame(in: .named("chatScroll")).maxY
                                            )
                                        }
                                    )
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        }
                        .id(conversationKey)
                        .coordinateSpace(name: "chatScroll")
                        .chatInteractiveKeyboardDismiss()
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { _ in
                                    if !hasUserScrolledInSession {
                                        hasUserScrolledInSession = true
                                    }
                                    shouldLockToBottomOnEntry = false
                                }
                        )
                        .onAppear {
                            if !messages.isEmpty {
                                scrollToBottomStably(proxy)
                            }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { messageViewportHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { h in messageViewportHeight = h }
                            }
                        )
                        .onPreferenceChange(ChatBottomOffsetPreferenceKey.self) { maxY in
                            bottomDistance = max(0, maxY - messageViewportHeight)
                            chatAnchorLog("bottomOffset conversation=\(conversationKey) bottomDistance=\(Int(bottomDistance)) viewport=\(Int(messageViewportHeight)) anchor=\(currentAnchorMessageID ?? "nil") lockToBottom=\(shouldLockToBottomOnEntry)")
                            if keyboardTransitioning { return }
                            if bottomDistance > 36, !hasUserScrolledInSession {
                                hasUserScrolledInSession = true
                            }
                        }
                        .onChange(of: messages.count) { _ in
                            if !messages.isEmpty {
                                if let restore = pendingRestoreAnchorMessageID {
                                    logPosition("messages.count changed -> restore pending anchor \(restore)")
                                    proxy.scrollTo(restore, anchor: .top)
                                    pendingRestoreAnchorMessageID = nil
                                } else if !didInitialPositioning {
                                    logPosition("messages.count changed -> initial positioning")
                                    scrollToBottomStably(proxy)
                                } else if keyboardIsVisible && inputFocused {
                                    scheduleBottomSnap(animated: false, delay: 0.01)
                                } else if bottomDistance < 140 {
                                    if keyboardIsVisible {
                                        scheduleBottomSnap(animated: false, delay: 0)
                                    } else {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                                            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.92, blendDuration: 0.12)) {
                                                proxy.scrollTo("chatBottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                    if shouldLockToBottomOnEntry {
                                        scheduleEntryBottomCorrections()
                                    }
                                }
                            }
                        }
                        .onChange(of: scrollToBottomRequestToken) { _ in
                            guard !messages.isEmpty else { return }
                            DispatchQueue.main.async {
                                if keyboardIsVisible {
                                    let duration = max(0.16, min(0.42, keyboardAnimationDuration))
                                    withAnimation(.easeOut(duration: duration)) {
                                        proxy.scrollTo("chatBottom", anchor: .bottom)
                                    }
                                } else {
                                    withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.12)) {
                                        proxy.scrollTo("chatBottom", anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onChange(of: scrollToBottomImmediateRequestToken) { _ in
                            guard !messages.isEmpty else { return }
                            DispatchQueue.main.async {
                                var tx = Transaction()
                                tx.disablesAnimations = true
                                withTransaction(tx) {
                                    proxy.scrollTo("chatBottom", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: scrollToMessageRequestToken) { _ in
                            guard let targetID = pendingScrollToMessageID, !targetID.isEmpty else { return }
                            guard messages.contains(where: { $0.id == targetID }) else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(targetID, anchor: .center)
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if shouldShowScrollToLatestButton {
                                Button(action: {
                                    withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.12)) {
                                        proxy.scrollTo("chatBottom", anchor: .bottom)
                                    }
                                }) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 14, weight: .heavy))
                                        .foregroundColor(.white)
                                        .frame(width: 40, height: 40)
                                        .background(Color(red: 0.145, green: 0.82, blue: 0.46))
                                        .clipShape(Circle())
                                        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
                                }
                                .padding(.trailing, 14)
                                .padding(.bottom, 14)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.18), value: shouldShowScrollToLatestButton)
                        .overlay(alignment: .top) {
                            VStack(spacing: 6) {
                                if hasMoreHistory && showManualHistoryLoadEntry {
                                    Button(action: { Task { await loadOlderMessages() } }) {
                                        HStack(spacing: 6) {
                                            if isLoadingHistory {
                                                ProgressView()
                                                    .scaleEffect(0.72)
                                            }
                                            Text(isLoadingHistory ? "重试中..." : "点击重试加载历史")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color(white: 0.38))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.white.opacity(0.92))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isLoadingHistory)
                                }
                            }
                            .padding(.top, 6)
                            .animation(.easeInOut(duration: 0.18), value: showManualHistoryLoadEntry)
                        }
                    }
                }
                if let err = errorMessage {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(8)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if inputFocused {
                    dismissKeyboard()
                }
            }
            
            // 回复/编辑预览（与 H5 quoted-message-preview / editing-message-preview 一致）
            if let quoted = quotedMessage {
                quotedPreviewBar(quoted, isEdit: false)
            }
            if let edit = editingMessage {
                quotedPreviewBar(edit, isEdit: true)
            }
            // 已选图片预览（与 H5 selectedFile 一致，可清除）
            if let img = selectedImage {
                HStack(spacing: 8) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("已选图片")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { openImageEditor() }) {
                        Text("编辑")
                            .font(.caption)
                            .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.13, green: 0.59, blue: 0.95).opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: { selectedImage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color(white: 0.6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.98))
            }
            if showMentionPanel {
                VStack(spacing: 0) {
                    HStack {
                        Text("群成员")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(white: 0.35))
                        Spacer()
                        Button(action: closeMentionPanel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: 0.5))
                                .frame(width: 20, height: 20)
                                .background(Color(white: 0.93))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.985))
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Button(action: selectMentionAll) {
                                HStack(spacing: 8) {
                                    Image(systemName: "at")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                                    Text("所有人")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.white)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color(white: 0.93)).frame(height: 1)
                            }
                            
                            ForEach(filteredMentionUsers, id: \.id) { user in
                                Button(action: { selectMention(user) }) {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(Color(white: 0.92))
                                            .frame(width: 28, height: 28)
                                            .overlay(
                                                Image(systemName: "person.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Color(white: 0.5))
                                            )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mentionDisplayName(for: user))
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            Text(maskPhoneOrJid(user.jid))
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.white)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color(white: 0.94)).frame(height: 1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(white: 0.9), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            // 底部输入（与 H5 MessageInput 一致：左图图片按钮、中间输入框、右收藏夹+发送）
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onTapSendImage) {
                    ZStack {
                        Circle()
                            .stroke(Color(white: 0.82), lineWidth: 1.5)
                            .frame(width: 34, height: 34)
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
                .frame(width: 44, height: 44, alignment: .center)
                HStack(spacing: 8) {
                    Group {
                        if #available(iOS 16.0, *) {
                            TextField("输入消息...", text: $inputText, axis: .vertical)
                                .lineLimit(1...5)
                        } else {
                            TextField("输入消息...", text: $inputText)
                        }
                    }
                    .textFieldStyle(.plain)
                    .foregroundColor(.black)
                    .focused($inputFocused)
                    .onTapGesture {
                        requestBottomSnapForInputFocus()
                    }
                    .submitLabel(.send)
                    .onSubmit {
                        if selectedImage == nil {
                            sendMessage()
                        }
                    }
                    
                    Button(action: onTapFavorites) {
                        Image(systemName: "star")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color(white: 0.45))
                            .frame(width: 28, height: 28, alignment: .center)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44, alignment: .center)
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .stroke(
                                sendButtonVisualState == .ready
                                ? Color(red: 0.13, green: 0.59, blue: 0.95).opacity(0.55)
                                : Color(white: 0.82),
                                lineWidth: 1.5
                            )
                            .background(
                                Circle()
                                    .fill(
                                        sendButtonVisualState == .ready
                                        ? Color(red: 0.13, green: 0.59, blue: 0.95).opacity(0.08)
                                        : Color.clear
                                    )
                            )
                            .frame(width: 34, height: 34)
                        Image(systemName: sendButtonVisualState == .sending ? "hourglass" : "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(
                                sendButtonVisualState == .ready
                                ? Color(red: 0.13, green: 0.59, blue: 0.95)
                                : Color(white: 0.7)
                            )
                    }
                    .scaleEffect(sendButtonVisualState == .ready ? 1.02 : 1.0)
                    .animation(.easeInOut(duration: 0.12), value: sendButtonVisualState == .ready)
                }
                .disabled(!canSendNow || sendingAction)
                .frame(width: 44, height: 44, alignment: .center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(white: 0.94)).frame(height: 1)
            }
        }
        .background(
            NativeInteractivePopEnabler()
                .frame(width: 0, height: 0)
        )
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .trailing) {
            if !showQuickToolsDrawer {
                Color.clear
                    .frame(width: 26)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 14, coordinateSpace: .global)
                            .onEnded { value in
                                handleQuickToolsSwipe(value)
                            }
                    )
            }
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 22)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 14, coordinateSpace: .global)
                        .onEnded { value in
                            handleFallbackBackSwipe(value)
                        }
                )
        }
        .onAppear {
            translationLog("enter chat conversation=\(conversationKey) messageCount=\(messages.count)")
            chatDiagLog("onAppear conversation=\(conversationKey) instanceId=\(instanceId) chatRowId=\(chat.chat_row_id ?? 0) jid=\(chat.jid ?? "") contacts=\(contacts.count) messages=\(messages.count) unread=\(conversationUnreadCount) group=\(isGroupConversation)")
            appState.isInChatDetail = true
            appState.setActiveChatConversation(instanceIdForApi: instanceId, jid: chat.jid)
            restartOutgoingStatusSyncLoop()
            Task {
                await syncOutgoingStatusesIfNeeded(forceOnEntry: true)
            }
            let hasUnreadOnEntry = forceLatestOnInitialEntry || conversationUnreadCount > 0
            let existingAnchor = appState.chatScrollAnchorByConversation[conversationKey]
            let initialTarget = (initialScrollToMessageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            shouldLockToBottomOnEntry = !hasUnreadOnEntry && (existingAnchor ?? "").isEmpty && initialTarget.isEmpty
            logPosition("onAppear unread=\(conversationUnreadCount) hasUnread=\(hasUnreadOnEntry) savedAnchor=\(existingAnchor ?? "nil") messages=\(messages.count)")
            forceScrollToLatestOnEntry = hasUnreadOnEntry
            if hasUnreadOnEntry {
                // 与微信/WhatsApp体验一致：有未读时优先最新消息，不恢复旧阅读锚点。
                appState.chatScrollAnchorByConversation.removeValue(forKey: conversationKey)
                logPosition("onAppear hasUnread -> clear saved anchor and force latest")
            }
            didInitialPositioning = false
            didApplyInitialScrollTarget = false
            pendingRestoreAnchorMessageID = nil
            currentAnchorMessageID = nil
            bottomDistance = 0
            hasUserScrolledInSession = false
            prioritizedMessageIDs = []
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let draft = appState.chatDraftByConversation[conversationKey],
               !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = draft
            }
            startOnboardingIfNeeded()
            if !didRunEntrySideEffects {
                didRunEntrySideEffects = true
                Task {
                    chatDiagLog("entrySideEffect markRead scheduled conversation=\(conversationKey)")
                    // 让导航转场先完成，再做全局未读更新，减少进入页首帧抖动
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                    appState.markConversationRead(
                        instanceIdForApi: instanceId,
                        jid: chat.jid ?? "",
                        baseUnreadHint: chat.newMessageCount ?? 0
                    )
                    await appState.syncConversationReadToServer(
                        instanceIdForApi: instanceId,
                        jid: chat.jid ?? "",
                        boxIP: boxIP
                    )
                }
                Task {
                    chatDiagLog("entrySideEffect loadCustomerMeta scheduled conversation=\(conversationKey)")
                    // 客户画像同步不是首屏关键路径，延后执行降低进场压力
                    try? await Task.sleep(nanoseconds: 260_000_000)
                    if Task.isCancelled { return }
                    await loadCustomerMetaFromLocal()
                }
            }
        }
        .onDisappear {
            chatDiagLog("onDisappear conversation=\(conversationKey) messages=\(messages.count) currentAnchor=\(currentAnchorMessageID ?? "nil") visible=\(visibleMessageIDs.count)")
            logPosition("onDisappear before persist bottomDistance=\(Int(bottomDistance)) viewport=\(Int(messageViewportHeight)) currentAnchor=\(currentAnchorMessageID ?? "nil")")
            persistScrollAnchorIfNeeded()
            didRunEntrySideEffects = false
            didKickoffInitialLoad = false
            translationWarmupTask?.cancel()
            translationWarmupTask = nil
            visibleTranslationScheduleTask?.cancel()
            visibleTranslationScheduleTask = nil
            translationBatchTask?.cancel()
            translationBatchTask = nil
            translationPendingKeys = []
            translationInFlightKeys = []
            visibleMessageIDs = []
            thumbWarmupTask?.cancel()
            thumbWarmupTask = nil
            thumbVisiblePrefetchTask?.cancel()
            thumbVisiblePrefetchTask = nil
            mediaPriorityWarmupTask?.cancel()
            mediaPriorityWarmupTask = nil
            pendingBottomSnapWorkItem?.cancel()
            pendingBottomSnapWorkItem = nil
            clearHighlightTask?.cancel()
            clearHighlightTask = nil
            entryBottomCorrectionTask?.cancel()
            entryBottomCorrectionTask = nil
            outgoingStatusSyncTask?.cancel()
            outgoingStatusSyncTask = nil
            outgoingStatusSyncInFlight = false
            incomingMessageSyncTask?.cancel()
            incomingMessageSyncTask = nil
            groupUsersPrefetchTask?.cancel()
            groupUsersPrefetchTask = nil
            appState.clearActiveChatConversation(instanceIdForApi: instanceId, jid: chat.jid)
            appState.markConversationRead(
                instanceIdForApi: instanceId,
                jid: chat.jid ?? "",
                baseUnreadHint: chat.newMessageCount ?? 0
            )
            Task {
                await appState.syncConversationReadToServer(
                    instanceIdForApi: instanceId,
                    jid: chat.jid ?? "",
                    boxIP: boxIP
                )
            }
            if appState.activeChatConversationKey == nil && appState.isInChatDetail {
                appState.isInChatDetail = false
            }
        }
        .task {
            guard !didKickoffInitialLoad else { return }
            didKickoffInitialLoad = true
            if Task.isCancelled { return }
            chatDiagLog("initial task start conversation=\(conversationKey) group=\(isGroupConversation)")
            await loadMessages()
            if isGroupConversation {
                // 群聊联系人仅用于成员展示辅助；后台拉取，避免阻塞首屏消息进入。
                chatDiagLog("initial task launch group side loads conversation=\(conversationKey)")
                Task { await loadContactsIfNeeded() }
                Task { await prefetchGroupUsers(showLoading: false, forceRefresh: false) }
            } else {
                await MainActor.run { groupUsers = [] }
            }
        }
        .overlay {
            ZStack {
                if messageActionTarget != nil {
                    messageLongPressOverlay
                }
                if showQuickToolsDrawer {
                    quickToolsDrawerOverlay
                }
                chatOnboardingOverlay
            }
        }
        .alert(
            "发送失败详情",
            isPresented: Binding(
                get: { (failedOutgoingDetailText ?? "").isEmpty == false },
                set: { show in if !show { failedOutgoingDetailText = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { failedOutgoingDetailText = nil }
        } message: {
            Text(failedOutgoingDetailText ?? "")
        }
        .onChange(of: inputFocused) { focused in
            if focused {
                requestBottomSnapForInputFocus()
            } else if keyboardIsVisible, bottomDistance < 320 {
                // 手动 dismiss（如点空白）时，等键盘 willHide 再做无动画贴底。
                keyboardPendingSnapToBottom = true
            }
        }
        .onChange(of: showQuickToolsDrawer) { visible in
            if visible {
                // 每次打开抽屉重新判定是否需要恢复聊天输入焦点。
                quickToolsShouldRestoreInputFocus = false
                return
            }
            guard quickToolsShouldRestoreInputFocus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                inputFocused = true
            }
        }
        .onChange(of: didFinishInitialMessageLoad) { ready in
            if ready, inputFocused, keyboardIsVisible {
                requestBottomSnapForInputFocus()
            }
            if ready {
                applyInitialScrollTargetIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            keyboardAnimationDuration = keyboardTransitionDuration(note)
            keyboardIsVisible = true
            keyboardTransitioning = true
            guard didInitialPositioning, didFinishInitialMessageLoad, !messages.isEmpty else { return }
            guard bottomDistance < 360 || inputFocused else { return }
            let duration = max(0.16, min(0.45, keyboardAnimationDuration))
            scheduleBottomSnapReliably(
                primaryAnimated: true,
                correctionDelay: min(0.08, duration * 0.35),
                finalDelay: min(0.24, duration * 0.95)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                keyboardTransitioning = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard didInitialPositioning, didFinishInitialMessageLoad, !messages.isEmpty else { return }
            // 键盘最终落位后做一次无动画校正，解决“首点输入框偶发不到底”。
            scheduleBottomSnapReliably(primaryAnimated: false, correctionDelay: 0.03, finalDelay: 0.10)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            keyboardAnimationDuration = keyboardTransitionDuration(note)
            keyboardIsVisible = false
            keyboardTransitioning = true
            guard didInitialPositioning, didFinishInitialMessageLoad, !messages.isEmpty else { return }
            guard bottomDistance < 360 || keyboardPendingSnapToBottom else {
                keyboardPendingSnapToBottom = false
                let duration = max(0.14, min(0.42, keyboardAnimationDuration))
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    keyboardTransitioning = false
                }
                return
            }
            keyboardPendingSnapToBottom = false
            scheduleBottomSnap(animated: true, delay: 0)
            let duration = max(0.14, min(0.42, keyboardAnimationDuration))
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                keyboardTransitioning = false
            }
        }
        .onChange(of: showPhotoPicker) { presented in
            if !presented, autoOpenComposeAfterPicker, selectedImage == nil {
                autoOpenComposeAfterPicker = false
            }
        }
        .onChange(of: selectedImage) { newValue in
            guard autoOpenComposeAfterPicker else { return }
            guard newValue != nil else { return }
            autoOpenComposeAfterPicker = false
            showImageComposeSheet = true
        }
        .onChange(of: inputText) { newValue in
            appState.setChatDraft(conversationKey: conversationKey, text: newValue)
            syncPendingMentionTokens(for: newValue)
            let cursorPos = currentInputCursorPosition(in: newValue) ?? newValue.count
            updateMentionState(for: newValue, cursorPos: cursorPos)
        }
        .onChange(of: groupUsers) { _ in
            let cursorPos = currentInputCursorPosition(in: inputText) ?? inputText.count
            updateMentionState(for: inputText, cursorPos: cursorPos)
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncWSMessagesDidArrive)) { note in
            guard let info = note.userInfo else { return }
            let eventInstanceId = (info["instance_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !eventInstanceId.isEmpty, eventInstanceId == instanceId else { return }
            let targetJids = info["jids"] as? [String] ?? []
            let currentJid = (chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentJid.isEmpty, targetJids.contains(currentJid) else { return }
            let stickToBottom = bottomDistance <= 28 || isAnchorNearBottom(currentAnchorMessageID ?? "", threshold: 2)
            appState.markConversationRead(
                instanceIdForApi: instanceId,
                jid: currentJid,
                baseUnreadHint: chat.newMessageCount ?? 0
            )
            scheduleIncomingConversationSync(stickToBottom: stickToBottom)
        }
        .confirmationDialog(
            "检测到运行中任务",
            isPresented: Binding(
                get: { runningTaskPromptContext != nil },
                set: { show in
                    if !show {
                        resolveRunningTaskPrompt(stopAndContinue: false)
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("停止并继续发送", role: .destructive) {
                resolveRunningTaskPrompt(stopAndContinue: true)
            }
            Button("取消", role: .cancel) {
                resolveRunningTaskPrompt(stopAndContinue: false)
            }
        } message: {
            Text("当前实例正在运行其他SCRM任务\(runningTaskPromptContext?.taskID.map { "（任务ID：\($0)）" } ?? "")，是否先停止该任务再继续？")
        }
        .sheet(isPresented: $showCustomerPanel) {
            customerPanel
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(selectedImage: $selectedImage, isPresented: $showPhotoPicker)
        }
        .sheet(isPresented: $showRecentMediaPicker) {
            RecentMediaPickerSheet(
                onSend: { images in
                    await sendPickedImages(images)
                }
            )
        }
        .fullScreenCover(isPresented: $showImageComposeSheet) {
            if let current = selectedImage {
                ImageComposeSheet(
                    image: current,
                    isSending: sendingAction,
                    onCancel: {
                        showImageComposeSheet = false
                        selectedImage = nil
                    },
                    onEdit: { beginComposeEditingFlow() },
                    onSend: { sendSelectedImageFromCompose() }
                )
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: $showImageEditor) {
            if let current = selectedImage {
                ImageEditSheet(
                    originalImage: current,
                    onCancel: {
                        showImageEditor = false
                        if reopenComposeAfterEditing, selectedImage != nil {
                            reopenComposeAfterEditing = false
                            showImageComposeSheet = true
                        } else {
                            reopenComposeAfterEditing = false
                        }
                    },
                    onApply: { edited in
                        selectedImage = edited
                        showImageEditor = false
                        if reopenComposeAfterEditing, selectedImage != nil {
                            reopenComposeAfterEditing = false
                            showImageComposeSheet = true
                        }
                    }
                )
            } else {
                EmptyView()
            }
        }
        .fullScreenCover(item: $previewRequest) { req in
            OriginalImagePreviewView(
                boxIP: boxIPForMedia,
                index: indexForMedia,
                items: req.items,
                initialIndex: req.initialIndex,
                initialImage: req.initialImage,
                appType: container.appType,
                streamUUID: container.uuid ?? instanceId,
                isPresented: Binding(
                    get: { previewRequest != nil },
                    set: { if !$0 { previewRequest = nil } }
                ),
                onForwardImage: { image in
                    openForwardConversationPicker(payload: .image(image))
                },
                onSendEditedImage: { edited in
                    selectedImage = edited
                    previewRequest = nil
                    sendMessage()
                },
                onDeleteItem: { item in
                    guard let target = messages.first(where: {
                        if let mid = item.messageID, mid > 0, $0.message_id == mid { return true }
                        return ($0.media_file_path ?? "") == item.path
                    }) else { return }
                    pendingDeleteMessage = target
                    previewRequest = nil
                },
                onReplyItem: { item in
                    guard let target = messages.first(where: {
                        if let mid = item.messageID, mid > 0, $0.message_id == mid { return true }
                        return ($0.media_file_path ?? "") == item.path
                    }) else { return }
                    replyToMessage(target)
                    previewRequest = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        inputFocused = true
                    }
                },
                onReactItem: { item, emoji in
                    guard let target = messages.first(where: {
                        if let mid = item.messageID, mid > 0, $0.message_id == mid { return true }
                        return ($0.media_file_path ?? "") == item.path
                    }) else { return }
                    Task { await sendReaction(emoji, for: target) }
                }
            )
        }
        .sheet(isPresented: $showForwardConversationPicker, onDismiss: {
            pendingForwardPayload = nil
        }) {
            if let payload = pendingForwardPayload {
                ForwardConversationPickerSheet(
                    containers: appState.accountInstances,
                    excludedConversationID: "\(instanceId)_\(chat.jid ?? "")",
                    onForward: { targets in
                        await forwardPayloadToTargets(payload, targets: targets)
                    }
                )
                .applyRecentMediaSheetPresentationStyle()
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: $showFavoritesPicker) {
            favoritesPickerSheet
        }
        .sheet(isPresented: $showGroupUsersSheet) {
            groupUsersSheet
        }
        .confirmationDialog(
            "确定删除？",
            isPresented: Binding(
                get: { pendingDeleteMessage != nil },
                set: { if !$0 { pendingDeleteMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确定删除", role: .destructive) {
                guard let target = pendingDeleteMessage else { return }
                pendingDeleteMessage = nil
                Task { await deleteMessage(target) }
            }
            Button("取消", role: .cancel) {
                pendingDeleteMessage = nil
            }
        } message: {
            Text("删除后消息记录会保留，并显示为红色“该消息已删除”")
        }
    }
    
    private func messageRow(_ msg: Message, prioritizeMediaLoad: Bool = true) -> some View {
        let outgoing = isOutgoing(msg)
        let isDeleted = (msg.message_type == 15)
        let isImageMessage = (msg.message_type == 1)
        // 动态宽度兜底，避免极端布局下出现非有限/负尺寸。
        let screenWidth = safeDimension(UIScreen.main.bounds.width, fallback: 390, min: 240, max: 1400)
        let bubbleMaxWidth = max(180, min(320, screenWidth - 120))
        let bubbleTextMaxWidth: CGFloat = max(120, bubbleMaxWidth - 20)
        let keyId = translationCacheKey(for: msg)
        let translation = messageTranslations[keyId] ?? ""
        let adaptiveBubbleWidth = isImageMessage
            ? nil
            : measuredBubbleWidth(msg: msg, translation: translation, quoted: msg.quote_message, bubbleTextMaxWidth: bubbleTextMaxWidth)
        let reaction = msg.reaction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasReaction = !reaction.isEmpty
        let showGroupSender = isGroupConversation && !outgoing
        return HStack(alignment: .bottom, spacing: 8) {
            if outgoing { Spacer(minLength: 60) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                if showGroupSender {
                    Text(groupSenderDisplay(for: msg))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(groupSenderColor(for: msg))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                }
                // 结构分层：bubble(正文/翻译) + reaction + meta，避免互相挤压
                VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                    messageBubbleContent(
                        msg: msg,
                        outgoing: outgoing,
                        isDeleted: isDeleted,
                        isImageMessage: isImageMessage,
                        prioritizeMediaLoad: prioritizeMediaLoad,
                        translation: translation,
                        bubbleMaxWidth: bubbleMaxWidth,
                        bubbleTextMaxWidth: bubbleTextMaxWidth
                    )
                    .frame(width: adaptiveBubbleWidth, alignment: .leading)
                    .onLongPressGesture(minimumDuration: 0.3) {
                        triggerImpactFeedback(.light)
                        presentMessageActionOverlay(for: msg)
                    }
                    if hasReaction {
                        reactionBadge(reaction)
                            .padding(.top, 2)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: highlightedMessageID == msg.id)
                // 时间行 + 发送状态（更多操作改为长按触发）
                HStack(alignment: .center, spacing: 4) {
                    Text(formatTime(msg.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.72))
                    if outgoing {
                        outgoingStatusView(for: msg)
                    }
                }
                .padding(.top, 2)
            }
            if !outgoing { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private func messageBubbleContent(
        msg: Message,
        outgoing: Bool,
        isDeleted: Bool,
        isImageMessage: Bool,
        prioritizeMediaLoad: Bool,
        translation: String,
        bubbleMaxWidth: CGFloat,
        bubbleTextMaxWidth: CGFloat
    ) -> some View {
        let imageContentWidth: CGFloat = 200
        let contentMaxWidth: CGFloat = isImageMessage ? imageContentWidth : bubbleTextMaxWidth
        VStack(alignment: .leading, spacing: 6) {
            if let quoted = msg.quote_message {
                quotedMessageInlineView(parent: msg, quoted: quoted, outgoing: outgoing)
            }
            if msg.message_type == 1 {
                if let path = msg.media_file_path, !path.isEmpty {
                    if prioritizeMediaLoad {
                        MessageThumbView(
                            boxIP: boxIPForMedia,
                            index: indexForMedia,
                            filePath: path,
                            messageID: msg.message_id,
                            appType: container.appType,
                            streamUUID: container.uuid ?? instanceId,
                            onOpenOriginal: { readyImage in
                                openOriginalImage(path: path, messageId: msg.message_id, timestamp: msg.timestamp, initialImage: readyImage)
                            }
                        )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.14))
                            .frame(width: imageContentWidth, height: imageContentWidth)
                    }
                } else if let kid = msg.key_id, let tempImage = tempOutgoingImagesByKeyID[kid] {
                    Image(uiImage: tempImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: imageContentWidth, height: imageContentWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: imageContentWidth, height: imageContentWidth)
                        .overlay(ProgressView())
                }
                let renderedCaption = renderedMessageText(msg.text_data)
                if !renderedCaption.isEmpty {
                    Text(renderedCaption)
                        .font(.caption)
                        .foregroundColor(outgoing ? Color.white.opacity(0.95) : Color(white: 0.4))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: imageContentWidth, alignment: .leading)
                }
            } else if isDeleted {
                let original = (msg.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                VStack(alignment: .leading, spacing: 4) {
                    if !original.isEmpty {
                        Text(original)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: bubbleTextMaxWidth, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    Text("该消息已删除")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.92))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                }
            } else {
                Text(messageBody(msg))
                    .font(.subheadline)
                    .foregroundColor(outgoing ? .white : Color(white: 0.15))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            if !translation.isEmpty {
                Rectangle()
                    .fill(outgoing ? Color.white.opacity(0.4) : Color.gray.opacity(0.4))
                    .frame(height: 1)
                    .padding(.vertical, 4)
                Text(translation)
                    .font(.system(size: 13))
                    .foregroundColor(outgoing ? Color.white.opacity(0.9) : Color(white: 0.45))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: isImageMessage ? imageContentWidth : .infinity, alignment: .leading)
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
        .padding(.top, isImageMessage ? 1 : 8)
        .padding(.bottom, isImageMessage ? 2 : 10)
        .padding(.leading, isImageMessage ? 2 : 10)
        .padding(.trailing, isImageMessage ? 2 : 10)
        .background(
            RoundedRectangle(cornerRadius: isImageMessage ? 10 : 18)
                .fill(isDeleted ? Color(red: 0.87, green: 0.21, blue: 0.23) : (outgoing ? Color(red: 0.2, green: 0.72, blue: 0.45) : Color.white))
                .overlay(
                    RoundedRectangle(cornerRadius: isImageMessage ? 10 : 18)
                        .stroke(isDeleted ? Color(red: 0.72, green: 0.14, blue: 0.16) : (outgoing ? Color.clear : Color(white: 0.88)), lineWidth: 1)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: isImageMessage ? 10 : 18)
                .fill(highlightedMessageID == msg.id ? Color(red: 1.0, green: 0.88, blue: 0.22).opacity(outgoing ? 0.20 : 0.28) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: isImageMessage ? 10 : 18))
    }

    private func measuredBubbleWidth(msg: Message, translation: String, quoted: QuotedMessage?, bubbleTextMaxWidth: CGFloat) -> CGFloat {
        let textFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let transFont = UIFont.systemFont(ofSize: 13)
        let quotedSenderFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let quotedBodyFont = UIFont.systemFont(ofSize: 11)
        let body = messageBody(msg).trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyWidth = measuredTextWidth(body, font: textFont, maxWidth: bubbleTextMaxWidth)
        let transWidth = measuredTextWidth(trans, font: transFont, maxWidth: bubbleTextMaxWidth)
        let quotedSender = quoted.map { quotedSenderText(parent: msg, quoted: $0) } ?? ""
        let quotedBody = quoted.map { quotedInlineSnippet($0) } ?? ""
        let quotedSenderWidth = measuredTextWidth(quotedSender, font: quotedSenderFont, maxWidth: bubbleTextMaxWidth)
        let quotedBodyWidth = measuredTextWidth(quotedBody, font: quotedBodyFont, maxWidth: bubbleTextMaxWidth)
        // 引用块有固定结构开销：左竖线(2) + 间距(7) + 引用块左右内边距(8+8)。
        let quotedBlockOverhead: CGFloat = 25
        let quotedBlockWidth = max(quotedSenderWidth, quotedBodyWidth) + quotedBlockOverhead
        let contentWidth = max(bodyWidth, transWidth, quotedBlockWidth, 24)
        // 左右 padding(10 + 10) + 文本内边距(4 + 4)
        let raw = contentWidth + 28
        let minWidth: CGFloat = (quoted == nil) ? 76 : 120
        return safeDimension(raw, fallback: min(220, bubbleTextMaxWidth + 20), min: minWidth, max: bubbleTextMaxWidth + 20)
    }

    private func measuredTextWidth(_ text: String, font: UIFont, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let constraint = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let width = ceil(rect.width)
        return safeDimension(width, fallback: maxWidth, min: 0, max: maxWidth)
    }

    private func reactionBadge(_ reaction: String) -> some View {
        Text(reaction)
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(white: 0.85), lineWidth: 1)
            )
    }

    private func quotedMessageInlineView(parent: Message, quoted: QuotedMessage, outgoing: Bool) -> some View {
        let accent = outgoing ? Color.white.opacity(0.86) : Color(red: 0.16, green: 0.62, blue: 0.95)
        let background = outgoing ? Color.white.opacity(0.12) : Color(white: 0.95)
        return HStack(alignment: .top, spacing: 7) {
            Rectangle()
                .fill(accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(quotedSenderText(parent: parent, quoted: quoted))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .lineLimit(1)
                Text(quotedInlineSnippet(quoted))
                    .font(.system(size: 11))
                    .foregroundColor(outgoing ? Color.white.opacity(0.92) : Color(white: 0.34))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            jumpToQuotedMessage(from: quoted)
        }
    }
    
    private func quotedSenderText(parent: Message, quoted: QuotedMessage) -> String {
        let senderName = (quoted.sender_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !senderName.isEmpty, senderName.lowercased() != "unknown" {
            return senderName
        }
        if (quoted.from_me ?? quoted.key_from_me ?? 0) == 1 { return "你" }
        let senderRaw = (quoted.sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !senderRaw.isEmpty {
            let masked = maskPhoneOrJid(senderRaw)
            if !masked.isEmpty { return masked }
        }
        return isOutgoing(parent) ? "对方" : "你"
    }
    
    private func quotedInlineSnippet(_ msg: QuotedMessage) -> String {
        switch msg.message_type ?? 0 {
        case 1:
            return "[图片]" + quotedMessageBody(msg)
        case 2:
            return "[语音]"
        case 3, 13:
            return "[视频]"
        case 9:
            return "[文件]"
        case 90:
            return "[通话]"
        default:
            let text = quotedMessageBody(msg).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "[消息]" : text
        }
    }
    
    private func jumpToQuotedMessage(from quoted: QuotedMessage) {
        guard let target = resolveQuotedTarget(quoted) else {
            errorMessage = "未找到被引用消息"
            return
        }
        pendingScrollToMessageID = target.id
        scrollToMessageRequestToken += 1
        flashMessageHighlight(targetID: target.id)
    }
    
    private func resolveQuotedTarget(_ quoted: QuotedMessage) -> Message? {
        if let key = quoted.key_id, !key.isEmpty {
            if let byKey = messages.first(where: { ($0.key_id ?? "") == key }) { return byKey }
        }
        if let mid = quoted.message_id, mid > 0 {
            if let byID = messages.first(where: { $0.message_id == mid }) { return byID }
        }
        return nil
    }
    
    private func quotedMessageBody(_ msg: QuotedMessage) -> String {
        let text1 = renderedMessageText(msg.text_data)
        if !text1.isEmpty { return text1 }
        let text2 = renderedMessageText(msg.data)
        if !text2.isEmpty { return text2 }
        return ""
    }
    
    private func flashMessageHighlight(targetID: String) {
        clearHighlightTask?.cancel()
        highlightedMessageID = targetID
        clearHighlightTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                if highlightedMessageID == targetID {
                    highlightedMessageID = nil
                }
            }
        }
    }

    private func applyInitialScrollTargetIfNeeded() {
        guard !didApplyInitialScrollTarget else { return }
        guard didInitialPositioning else { return }
        guard didFinishInitialMessageLoad else { return }
        let target = (initialScrollToMessageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard !messages.isEmpty else { return }

        if let hit = messages.first(where: {
            if $0.id == target { return true }
            if ($0.key_id ?? "") == target { return true }
            if let mid = $0.message_id, "\(mid)" == target { return true }
            return false
        }) {
            didApplyInitialScrollTarget = true
            pendingScrollToMessageID = hit.id
            scrollToMessageRequestToken += 1
            flashMessageHighlight(targetID: hit.id)
        }
    }

    private func resolvedInitialScrollMessageID() -> String? {
        let target = (initialScrollToMessageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return messages.first(where: {
            if $0.id == target { return true }
            if ($0.key_id ?? "") == target { return true }
            if let mid = $0.message_id, "\(mid)" == target { return true }
            return false
        })?.id
    }
    
    private func copyMessage(_ msg: Message) {
        let text = msg.text_data ?? messageBody(msg)
        UIPasteboard.general.string = text
    }
    
    private func replyToMessage(_ msg: Message) {
        quotedMessage = msg
        editingMessage = nil
    }
    
    private func startEditMessage(_ msg: Message) {
        editingMessage = msg
        quotedMessage = nil
        inputText = msg.text_data ?? ""
    }

    private func requestDeleteMessage(_ msg: Message) {
        guard isOutgoing(msg), msg.message_type != 15 else { return }
        pendingDeleteMessage = msg
    }

    private func deleteMessage(_ msg: Message) async {
        guard !sendingAction else { return }
        guard let boxIP = boxIP, !boxIP.isEmpty else {
            await MainActor.run { errorMessage = "容器 IP 缺失，无法删除" }
            return
        }
        guard let jid = chat.jid, !jid.isEmpty else {
            await MainActor.run { errorMessage = "会话 JID 缺失，无法删除" }
            return
        }
        guard msg.message_type != 15 else { return }

        await MainActor.run { deletingMessageIDs.insert(msg.id) }
        defer {
            Task { @MainActor in
                deletingMessageIDs.remove(msg.id)
            }
        }

        do {
            var quotedIndex: Int? = nil
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                quotedIndex = messages.count - idx + 1
            }
            let params = ChatService.CallSCRMFuncParams(
                instanceID: container.uuid ?? instanceId,
                method: "delete_message",
                name: container.name ?? "",
                ip: boxIP,
                index: container.index ?? 1,
                jid: jid,
                message: nil,
                contactName: nil,
                emoji: nil,
                quotedIndex: quotedIndex,
                quotedText: msg.text_data ?? messageBody(msg),
                quotedType: msg.message_type,
                quotedTimestamp: msg.timestamp,
                appType: container.appType,
                cloneID: nil,
                targetLang: "",
                imageData: nil,
                imageFileName: nil
            )
            let res = try await callSCRMFuncWithRunningCheck(params)
            guard res.code == 1 else {
                await MainActor.run {
                    errorMessage = res.msg ?? "删除失败"
                }
                return
            }
            await MainActor.run {
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx].message_type = 15
                }
                errorMessage = nil
            }
            await persistMessagesSnapshot()
        } catch {
            await MainActor.run {
                errorMessage = "删除失败"
            }
        }
    }
    
    private func clearQuotedMessage() {
        quotedMessage = nil
    }
    
    private func clearEditingMessage() {
        editingMessage = nil
        inputText = ""
    }
    
    private func onReactionSelectedFromLongPress(_ emoji: String, for msg: Message) {
        dismissMessageActionOverlay()
        Task { await sendReaction(emoji, for: msg) }
    }
    
    private var longPressOverlayEnterAnimation: Animation {
        .interactiveSpring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.2)
    }
    
    private var longPressOverlayExitAnimation: Animation {
        .interactiveSpring(response: 0.34, dampingFraction: 0.9, blendDuration: 0.18)
    }
    
    private func presentMessageActionOverlay(for msg: Message) {
        handleOnboardingEvent(.didLongPressMessage)
        withAnimation(longPressOverlayEnterAnimation) {
            messageActionTarget = msg
        }
    }
    
    private func dismissMessageActionOverlay() {
        withAnimation(longPressOverlayExitAnimation) {
            messageActionTarget = nil
        }
    }
    
    /// 发送图片/附件：调起相册选择（与 H5 openFileSelector 一致）
    private func onTapSendImage() {
        mentionVisible = false
        showRecentMediaPicker = true
    }
    
    private func openImageEditor() {
        guard selectedImage != nil else { return }
        reopenComposeAfterEditing = false
        showImageEditor = true
    }
    
    private func beginComposeEditingFlow() {
        guard selectedImage != nil else { return }
        reopenComposeAfterEditing = true
        showImageComposeSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if selectedImage != nil {
                showImageEditor = true
            } else {
                reopenComposeAfterEditing = false
            }
        }
    }
    
    private func sendSelectedImageFromCompose() {
        guard selectedImage != nil else { return }
        showImageComposeSheet = false
        sendMessage()
    }
    
    private func sendPickedImages(_ images: [UIImage]) async {
        let normalized = images.map { $0.normalizedForEditing() }
        guard !normalized.isEmpty else { return }
        
        let backupInput = inputText
        let backupQuoted = quotedMessage
        let backupEditing = editingMessage
        
        for image in normalized {
            await MainActor.run {
                inputText = ""
                quotedMessage = nil
                editingMessage = nil
                selectedImage = image
            }
            await sendOrEditMessage()
        }
        
        await MainActor.run {
            inputText = backupInput
            quotedMessage = backupQuoted
            editingMessage = backupEditing
            appState.setChatDraft(conversationKey: conversationKey, text: backupInput)
        }
    }
    
    /// 收藏夹（与 H5 收藏夹弹层一致，占位待接话术/收藏图片）
    private func onTapFavorites() {
        favoriteScripts = QuickTemplateStore.loadScriptTemplates().sorted { $0.updatedAt > $1.updatedAt }
        favoriteImages = QuickTemplateStore.loadImageTemplates().sorted { $0.updatedAt > $1.updatedAt }
        favoriteSearchText = ""
        favoriteTab = favoriteScripts.isEmpty && !favoriteImages.isEmpty ? "image" : "script"
        if favoriteScripts.isEmpty && favoriteImages.isEmpty {
            errorMessage = "暂无模板，请先在工具页添加话术或图片模板"
            return
        }
        showFavoritesPicker = true
    }
    
    @ViewBuilder
    private var favoritesPickerSheet: some View {
        NavigationView {
            VStack(spacing: 10) {
                Picker("模板类型", selection: $favoriteTab) {
                    Text("话术").tag("script")
                    Text("图片").tag("image")
                }
                .pickerStyle(.segmented)
                
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(favoriteTab == "script" ? "搜索话术..." : "搜索图片模板...", text: $favoriteSearchText)
                        .textFieldStyle(.plain)
                    if !favoriteSearchText.isEmpty {
                        Button(action: { favoriteSearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(white: 0.95))
                .cornerRadius(8)
                
                if favoriteTab == "script" {
                    favoriteScriptListView
                } else {
                    favoriteImageListView
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .navigationTitle("快捷模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showFavoritesPicker = false }
                }
            }
        }
    }
    
    @ViewBuilder
    private var groupUsersSheet: some View {
        let q = groupUsersSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items: [GroupUser] = {
            let base = groupUsers
            guard !q.isEmpty else { return base }
            return base.filter { user in
                let jid = (user.jid ?? "").lowercased()
                let display = mentionDisplayName(for: user).lowercased()
                let number = (resolveGroupUserContact(user)?.number ?? "").lowercased()
                return jid.contains(q) || display.contains(q) || number.contains(q)
            }
        }()
        NavigationView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索成员 jid/名称", text: $groupUsersSearchText)
                        .textFieldStyle(.plain)
                    if !groupUsersSearchText.isEmpty {
                        Button(action: { groupUsersSearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(white: 0.95))
                .cornerRadius(8)

                if groupUsersLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("加载群成员中...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
                if !groupUsersLoading && items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text("暂无成员")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items, id: \.id) { user in
                            HStack(spacing: 10) {
                                if (user.jid ?? "") == "me" {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(Color(white: 0.7))
                                        .frame(width: 34, height: 34)
                                } else if let avatar = contactAvatarImage(for: user.jid) {
                                    Image(uiImage: avatar)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 34, height: 34)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(Color(white: 0.7))
                                        .frame(width: 34, height: 34)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if (user.jid ?? "") == "me" {
                                        Text("我")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("当前账号")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(mentionDisplayName(for: user))
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(maskPhoneOrJid(user.jid))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(12)
            .navigationTitle("群成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showGroupUsersSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        groupUsersPrefetchTask?.cancel()
                        groupUsersPrefetchTask = Task {
                            await prefetchGroupUsers(showLoading: true, forceRefresh: true)
                        }
                    }) {
                        Text("刷新")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        addMemberSearchText = ""
                        addMemberSelectedJIDs = []
                        showAddGroupMembersSheet = true
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "person.badge.plus.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("添加")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Color(red: 0.11, green: 0.62, blue: 0.32))
                        .frame(minWidth: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showAddGroupMembersSheet) {
            addGroupMembersSheet
        }
    }

    @ViewBuilder
    private var addGroupMembersSheet: some View {
        NavigationView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索联系人 jid/名称", text: $addMemberSearchText)
                        .textFieldStyle(.plain)
                    if !addMemberSearchText.isEmpty {
                        Button(action: { addMemberSearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(white: 0.95))
                .cornerRadius(8)

                if filteredAddMemberContacts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text("暂无可添加联系人")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredAddMemberContacts, id: \.id) { contact in
                            let jid = (contact.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            Button {
                                if addMemberSelectedJIDs.contains(jid) {
                                    addMemberSelectedJIDs.remove(jid)
                                } else {
                                    addMemberSelectedJIDs.insert(jid)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addMemberSelectedJIDs.contains(jid) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(addMemberSelectedJIDs.contains(jid) ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        let remark = (contact.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        let name = (contact.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !remark.isEmpty {
                                            Text(remark).font(.system(size: 14, weight: .semibold))
                                        } else if !name.isEmpty {
                                            Text(name).font(.system(size: 14, weight: .medium))
                                        } else {
                                            Text(maskPhoneOrJid(contact.jid)).font(.system(size: 14, weight: .medium))
                                        }
                                        Text(maskPhoneOrJid(contact.jid))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(12)
            .navigationTitle("添加群成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddGroupMembersSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if addMemberSubmitting {
                        ProgressView()
                    } else {
                        Button("确认(\(addMemberSelectedJIDs.count))") {
                            Task { await confirmAddMembersToGroup() }
                        }
                        .disabled(addMemberSelectedJIDs.isEmpty || addMemberSubmitting)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var favoriteScriptListView: some View {
        let q = favoriteSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = q.isEmpty ? favoriteScripts : favoriteScripts.filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
        if items.isEmpty {
            Text("暂无可用话术模板")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        Button(action: { quickSendScriptTemplate(item) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(item.content)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(Color.white)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(white: 0.9), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var favoriteImageListView: some View {
        let q = favoriteSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = q.isEmpty ? favoriteImages : favoriteImages.filter { $0.title.lowercased().contains(q) }
        if items.isEmpty {
            Text("暂无可用图片模板")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        Button(action: { quickSendImageTemplate(item) }) {
                            HStack(spacing: 10) {
                                if let image = item.uiImage() {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(white: 0.92))
                                        .frame(width: 52, height: 52)
                                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                                }
                                Text(item.title)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.white)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(white: 0.9), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    private func quickSendScriptTemplate(_ item: QuickScriptTemplate) {
        let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        showFavoritesPicker = false
        selectedImage = nil
        inputText = content
        sendMessage()
    }
    
    private func quickSendImageTemplate(_ item: QuickImageTemplate) {
        guard let image = item.uiImage() else {
            errorMessage = "模板图片已损坏，请在工具页重新添加"
            return
        }
        showFavoritesPicker = false
        inputText = ""
        selectedImage = image
        sendMessage()
    }
    
    private func openOriginalImage(path: String, messageId: Int?, timestamp: Int64? = nil, initialImage: UIImage? = nil) {
        let galleryRaw = messages.compactMap { msg -> PreviewGalleryItem? in
            guard msg.message_type == 1,
                  let p = msg.media_file_path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !p.isEmpty else { return nil }
            let id = (msg.key_id?.isEmpty == false ? msg.key_id! : "\(msg.message_id ?? 0)_\(p)")
            return PreviewGalleryItem(id: id, path: p, messageID: msg.message_id, timestamp: msg.timestamp)
        }
        // 去重：同一条消息（messageID + path）仅保留一份，避免预览索引错位。
        var dedupSeen = Set<String>()
        let gallery = galleryRaw.filter { item in
            let key = "\(item.messageID ?? -1)|\(item.path)"
            if dedupSeen.contains(key) { return false }
            dedupSeen.insert(key)
            return true
        }
        let initial: PreviewGalleryItem = PreviewGalleryItem(
            id: "\(messageId ?? 0)_\(path)",
            path: path,
            messageID: messageId,
            timestamp: timestamp
        )
        let items = gallery.isEmpty ? [initial] : gallery
        let idxExact = items.firstIndex(where: { $0.messageID == messageId && $0.path == path && messageId != nil })
        let idxById = items.firstIndex(where: { $0.messageID == messageId && messageId != nil })
        // 同路径可能在历史里出现多次，点底部最新一张时应优先命中最后一个。
        let idxByPath = items.lastIndex(where: { $0.path == path })
        let resolvedIndex = idxExact ?? idxById ?? idxByPath ?? max(0, items.count - 1)
        previewRequest = PreviewImageRequest(
            items: items,
            initialIndex: resolvedIndex,
            initialImage: initialImage
        )
    }
    
    private func handleQuickToolsSwipe(_ value: DragGesture.Value) {
        let isMostlyHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
        guard isMostlyHorizontal else { return }
        
        if showQuickToolsDrawer {
            let closeEnough = value.translation.width >= 70 || value.predictedEndTranslation.width >= 110
            if closeEnough {
                withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.12)) {
                    showQuickToolsDrawer = false
                }
            }
            return
        }
        
        let screenWidth = UIScreen.main.bounds.width
        let fromRightEdge = value.startLocation.x >= max(0, screenWidth - 32)
        let openEnough = value.translation.width <= -70 || value.predictedEndTranslation.width <= -120
        guard fromRightEdge, openEnough else { return }
        
        dismissKeyboard()
        withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.12)) {
            showQuickToolsDrawer = true
        }
        handleOnboardingEvent(.didOpenToolsDrawer)
    }
    
    private func handleFallbackBackSwipe(_ value: DragGesture.Value) {
        guard !showQuickToolsDrawer else { return }
        let horizontal = value.translation.width
        guard horizontal > 70 else { return }
        guard abs(horizontal) > abs(value.translation.height) * 1.25 else { return }
        inputFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            appState.isInChatDetail = false
        }
        dismiss()
    }
    
    private func startOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: chatOnboardingShownKey) else {
            onboardingStep = nil
            return
        }
        defaults.set(true, forKey: chatOnboardingShownKey)
        onboardingStep = .longPressMessage
    }
    
    private func skipCurrentOnboardingStep() {
        withAnimation(.easeInOut(duration: 0.2)) {
            onboardingStep = onboardingStep?.next
        }
    }
    
    private func endOnboarding() {
        withAnimation(.easeInOut(duration: 0.2)) {
            onboardingStep = nil
        }
    }
    
    private func handleOnboardingEvent(_ event: ChatOnboardingEvent) {
        guard let step = onboardingStep else { return }
        let matched: Bool
        switch (step, event) {
        case (.longPressMessage, .didLongPressMessage),
             (.tapAvatar, .didTapAvatar),
             (.openToolsDrawer, .didOpenToolsDrawer),
             (.translationDoTranslate, .didTapTranslateButton),
             (.translationEnter, .didTapTranslationEnter):
            matched = true
        default:
            matched = false
        }
        guard matched else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            onboardingStep = step.next
        }
    }
    
    @ViewBuilder
    private var chatOnboardingOverlay: some View {
        if let step = onboardingStep {
            let cardTopPadding: CGFloat = (step == .tapAvatar) ? 84 : 12
            ZStack(alignment: .top) {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                
                if step == .tapAvatar {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .position(x: 80, y: 66)
                        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
                }
                
                if step == .openToolsDrawer {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.point.right.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(white: 0.86), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .offset(x: onboardingSwipeHintAnimating ? -34 : 0, y: 146)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            onboardingSwipeHintAnimating = true
                        }
                    }
                    .onDisappear {
                        onboardingSwipeHintAnimating = false
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
                            Text(step.waitHint)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(red: 0.13, green: 0.49, blue: 0.95))
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        Button("跳过本步") { skipCurrentOnboardingStep() }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.35))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.94))
                            .clipShape(Capsule())
                        Button("结束引导") { endOnboarding() }
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
                .padding(.top, cardTopPadding)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(20)
        }
    }
    
    private func openForwardConversationPicker(payload: ForwardPayload) {
        pendingForwardPayload = payload
        previewRequest = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            showForwardConversationPicker = true
        }
    }
    
    private func forwardPayloadToTargets(_ payload: ForwardPayload, targets: [ForwardConversationTarget]) async -> (success: Int, failed: Int) {
        let imageData: Data?
        let messageText: String
        let method: String
        switch payload {
        case .image(let image):
            guard let encoded = image.jpegData(compressionQuality: 0.88) else {
                await MainActor.run { errorMessage = "图片编码失败，无法转发" }
                return (0, targets.count)
            }
            method = "send_image"
            messageText = ""
            imageData = encoded
        case .text(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                await MainActor.run { errorMessage = "文本为空，无法转发" }
                return (0, targets.count)
            }
            method = "send_message"
            messageText = clean
            imageData = nil
        }
        var success = 0
        var failed = 0
        for target in targets {
            let params = ChatService.CallSCRMFuncParams(
                instanceID: target.instanceID,
                method: method,
                name: target.containerName,
                ip: target.boxIP,
                index: target.index,
                jid: target.jid,
                message: messageText,
                contactName: nil,
                emoji: nil,
                quotedIndex: nil,
                quotedText: nil,
                quotedType: nil,
                quotedTimestamp: nil,
                appType: target.appType,
                cloneID: nil,
                targetLang: "",
                imageData: imageData,
                imageFileName: method == "send_image" ? "forward_\(Int(Date().timeIntervalSince1970)).jpg" : nil
            )
            do {
                let res = try await callSCRMFuncWithRunningCheck(params)
                if res.code == 1 {
                    success += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            await MainActor.run { errorMessage = "转发完成：成功\(success)个，失败\(failed)个" }
        } else {
            await MainActor.run { errorMessage = nil }
        }
        return (success, failed)
    }
    
    private func onTapAvatar() {
        handleOnboardingEvent(.didTapAvatar)
        showCustomerPanel = true
    }
    
    @ViewBuilder
    private var customerPanel: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("客户画像")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(white: 0.15))
                            profileField(title: "姓名", text: $customerNameText, keyboard: .default)
                            profileField(title: "备注", text: $customerRemarkText, keyboard: .default)
                            profileField(title: "年龄", text: $customerAgeText, keyboard: .numberPad)
                            profileField(title: "来源", text: $customerSourceText, keyboard: .default)
                            profileField(title: "行业", text: $customerIndustryText, keyboard: .default)
                            profileField(title: "职业", text: $customerOccupationText, keyboard: .default)
                            profileField(title: "家庭情况", text: $customerFamilyStatusText, keyboard: .default)
                            profileField(title: "年收入", text: $customerAnnualIncomeText, keyboard: .default)
                        }
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(10)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("跟进记录")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(white: 0.15))
                                Spacer()
                                Button(action: openAddFollowUpEditor) {
                                    Label("添加", systemImage: "plus")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            if followUpRecords.isEmpty {
                                Text("暂无跟进记录")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(white: 0.55))
                            } else {
                                ForEach(followUpRecords) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 12) {
                                            Text("跟进时间")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color(white: 0.5))
                                            Text(formatTime(item.ts))
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(white: 0.35))
                                        }
                                        HStack(spacing: 12) {
                                            Text("跟进人")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color(white: 0.5))
                                            Text(followUpOwnerDisplayName(item))
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(white: 0.35))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        HStack(alignment: .top, spacing: 12) {
                                            Text("跟进内容")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color(white: 0.5))
                                                .padding(.top, 1)
                                            Text(item.text)
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(white: 0.2))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        HStack {
                                            Spacer()
                                            Button("编辑") { openEditFollowUpEditor(item) }
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(red: 0.13, green: 0.49, blue: 0.95))
                                            Button("删除") { pendingDeleteFollowUpID = item.id }
                                                .font(.system(size: 12))
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    Divider()
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(10)
                    }
                    .padding(12)
                }
                .background(Color(white: 0.95))
            }
            .navigationTitle(displayName().isEmpty ? "客户信息" : displayName())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCustomerPanel = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        let name = customerNameText
                        let remark = customerRemarkText
                        let age = customerAgeText
                        let source = customerSourceText
                        let industry = customerIndustryText
                        let occupation = customerOccupationText
                        let family = customerFamilyStatusText
                        let annualIncome = customerAnnualIncomeText
                        Task {
                            await CustomerMetaStore.shared.updateUserInfo(
                                name: name,
                                remark: remark,
                                age: age,
                                source: source,
                                industry: industry,
                                occupation: occupation,
                                familyStatus: family,
                                annualIncome: annualIncome,
                                context: customerSyncContext
                            )
                            await loadCustomerMetaFromLocal()
                            await MainActor.run {
                                appState.presentUserFeedback("客户信息已保存", level: .success)
                                showCustomerPanelFeedback("客户信息已保存")
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                "确认删除该跟进记录？",
                isPresented: Binding(
                    get: { pendingDeleteFollowUpID != nil },
                    set: { if !$0 { pendingDeleteFollowUpID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    guard let id = pendingDeleteFollowUpID else { return }
                    pendingDeleteFollowUpID = nil
                    Task { await deleteFollowUpRecord(id: id) }
                }
                Button("取消", role: .cancel) {
                    pendingDeleteFollowUpID = nil
                }
            }
            .sheet(isPresented: $showFollowUpEditor) {
                if #available(iOS 16.0, *) {
                    followUpEditorSheet
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                } else {
                    followUpEditorSheet
                }
            }
            .overlay(alignment: .top) {
                if let text = customerPanelFeedbackText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(customerPanelFeedbackIsError
                                      ? Color(red: 0.80, green: 0.22, blue: 0.20).opacity(0.95)
                                      : Color.black.opacity(0.82))
                        )
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
    
    private func profileField(title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.45))
                .frame(width: 62, alignment: .leading)
            TextField("请输入\(title)", text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
        }
    }
    
    @ViewBuilder
    private var followUpEditorSheet: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("跟进人")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.45))
                        .frame(width: 62, alignment: .leading)
                    TextField("请输入跟进人", text: $followUpEditorOwnerName)
                        .textFieldStyle(.roundedBorder)
                }
                TextEditor(text: $followUpEditorText)
                    .font(.system(size: 14))
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Color(white: 0.97))
                    .cornerRadius(8)
                Spacer()
            }
            .padding(12)
            .navigationTitle(editingFollowUpID == nil ? "添加跟进记录" : "编辑跟进记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { closeFollowUpEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await saveFollowUpEditor() }
                    }
                    .disabled(
                        followUpEditorOwnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || followUpEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
    
    private func openAddFollowUpEditor() {
        editingFollowUpID = nil
        followUpEditorOwnerName = followUpCurrentUserName()
        followUpEditorText = ""
        showFollowUpEditor = true
    }
    
    private func openEditFollowUpEditor(_ item: CustomerFollowUpRecord) {
        editingFollowUpID = item.id
        followUpEditorOwnerName = followUpOwnerDisplayName(item)
        followUpEditorText = item.text
        showFollowUpEditor = true
    }
    
    private func closeFollowUpEditor() {
        showFollowUpEditor = false
        editingFollowUpID = nil
        followUpEditorOwnerName = ""
        followUpEditorText = ""
    }
    
    private func saveFollowUpEditor() async {
        let owner = followUpEditorOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = followUpEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !text.isEmpty else { return }
        if let recordID = editingFollowUpID {
            let ok = await CustomerMetaStore.shared.updateFollowUp(
                recordID: recordID,
                ownerName: owner,
                content: text,
                context: customerSyncContext
            )
            await MainActor.run {
                if ok {
                    appState.presentUserFeedback("跟进记录已更新", level: .success)
                    showCustomerPanelFeedback("跟进记录已更新")
                } else {
                    errorMessage = "更新跟进记录失败"
                    appState.presentUserFeedback("更新跟进记录失败", level: .error)
                    showCustomerPanelFeedback("更新跟进记录失败", isError: true)
                }
            }
        } else {
            await CustomerMetaStore.shared.addFollowUp(text, ownerName: owner, context: customerSyncContext)
            await MainActor.run {
                appState.presentUserFeedback("跟进记录已添加", level: .success)
                showCustomerPanelFeedback("跟进记录已添加")
            }
        }
        await loadCustomerMetaFromLocal()
        await MainActor.run { closeFollowUpEditor() }
    }
    
    private func deleteFollowUpRecord(id: String) async {
        let ok = await CustomerMetaStore.shared.deleteFollowUp(recordID: id, context: customerSyncContext)
        await MainActor.run {
            if ok {
                appState.presentUserFeedback("跟进记录已删除", level: .success)
                showCustomerPanelFeedback("跟进记录已删除")
            } else {
                errorMessage = "删除跟进记录失败"
                appState.presentUserFeedback("删除跟进记录失败", level: .error)
                showCustomerPanelFeedback("删除跟进记录失败", isError: true)
            }
        }
        await loadCustomerMetaFromLocal()
    }
    
    private func showCustomerPanelFeedback(_ text: String, isError: Bool = false) {
        customerPanelFeedbackDismissTask?.cancel()
        customerPanelFeedbackDismissTask = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            customerPanelFeedbackText = text
            customerPanelFeedbackIsError = isError
        }
        customerPanelFeedbackDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.16)) {
                    customerPanelFeedbackText = nil
                }
            }
        }
    }
    
    private func loadCustomerMetaFromLocal() async {
        let meta = await CustomerMetaStore.shared.load(conversationKey: conversationKey)
        await MainActor.run {
            customerNameText = meta.name
            customerRemarkText = meta.remark
            customerAgeText = meta.age
            customerSourceText = meta.source
            customerIndustryText = meta.industry
            customerOccupationText = meta.occupation
            customerFamilyStatusText = meta.familyStatus
            customerAnnualIncomeText = meta.annualIncome
            followUpRecords = meta.followUps
        }
        await CustomerMetaStore.shared.sync(context: customerSyncContext)
        await CustomerMetaStore.shared.pullRemoteAndMerge(context: customerSyncContext)
        let refreshed = await CustomerMetaStore.shared.load(conversationKey: conversationKey)
        await MainActor.run {
            customerNameText = refreshed.name
            customerRemarkText = refreshed.remark
            customerAgeText = refreshed.age
            customerSourceText = refreshed.source
            customerIndustryText = refreshed.industry
            customerOccupationText = refreshed.occupation
            customerFamilyStatusText = refreshed.familyStatus
            customerAnnualIncomeText = refreshed.annualIncome
            followUpRecords = refreshed.followUps
        }
    }
    
    private func followUpCurrentUserName() -> String {
        let nick = appState.userNickName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty, nick != "未设置昵称" { return nick }
        let login = (appState.userLoginName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !login.isEmpty { return login }
        return "我"
    }
    
    private func followUpOwnerDisplayName(_ item: CustomerFollowUpRecord) -> String {
        let owner = (item.ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty { return owner }
        return "我"
    }
    
    /// 发送文本/图片消息（与 H5 handleSend 一致）
    private func sendMessage() {
        guard canSendNow, !sendingAction else { return }
        mentionVisible = false
        playSendTapSound()
        triggerImpactFeedback(.soft)
        Task { await sendOrEditMessage() }
    }
    
    private func playSendTapSound() {
        // 1103 相比 1104 更柔和，接近 Telegram 发送点击反馈
        AudioServicesPlaySystemSound(1103)
    }
    
    private func triggerImpactFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    private var quickToolsDrawerOverlay: some View {
        GeometryReader { geo in
            let geoWidth = safeDimension(geo.size.width, fallback: 390, min: 240, max: 1400)
            let geoHeight = safeDimension(geo.size.height, fallback: UIScreen.main.bounds.height, min: 200, max: 3000)
            let panelWidth = max(280, min(geoWidth * 0.67, 420))
            ZStack(alignment: .trailing) {
                Color.black
                    .opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        let shouldRestore = quickToolsShouldRestoreInputFocus
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.12)) {
                            showQuickToolsDrawer = false
                        }
                        if shouldRestore {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                                inputFocused = true
                            }
                        }
                    }
                
                ToolsPlaceholderView(
                    appState: appState,
                    storageScopeKey: conversationKey,
                    onTranslationInputFocusChanged: { focused in
                        if focused {
                            quickToolsShouldRestoreInputFocus = true
                        }
                    },
                    onFillTranslationToChatInput: { translated in
                        let value = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        inputText = value
                        handleOnboardingEvent(.didTapTranslationEnter)
                        quickToolsShouldRestoreInputFocus = true
                        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.1)) {
                            showQuickToolsDrawer = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                            inputFocused = true
                        }
                    },
                    onTranslationActionTriggered: {
                        handleOnboardingEvent(.didTapTranslateButton)
                    },
                    showTranslationButtonGuide: onboardingStep == .translationDoTranslate,
                    showTranslationEnterGuide: onboardingStep == .translationEnter
                )
                    .frame(width: panelWidth, height: geoHeight)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 18, x: -4, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    /// 回复/编辑预览条：对齐 WhatsApp 双行样式（上：名称，下：消息）
    private func quotedPreviewBar(_ msg: Message, isEdit: Bool) -> some View {
        let accent = isEdit
            ? Color(red: 1, green: 0.76, blue: 0.03)
            : Color(red: 0.2, green: 0.72, blue: 0.95)
        return HStack(alignment: .center, spacing: 8) {
            Rectangle()
                .fill(accent)
                .frame(width: 2, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(quotedPreviewTitle(for: msg, isEdit: isEdit))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(quotedPreviewSnippet(msg))
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                pendingScrollToMessageID = msg.id
                scrollToMessageRequestToken += 1
            }
            Button(action: {
                if isEdit { clearEditingMessage() } else { clearQuotedMessage() }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(white: 0.65))
            }
            .frame(width: 28, height: 28)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 38)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(white: 0.9), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }
    
    private func quotedPreviewTitle(for msg: Message, isEdit: Bool) -> String {
        if isEdit { return "正在编辑" }
        if isOutgoing(msg) { return "你" }
        if let sender = msg.sender_name?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            return sender
        }
        return displayName()
    }
    
    private func quotedPreviewSnippet(_ msg: Message) -> String {
        let text = messageBody(msg).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "[消息]" }
        let maxCount = 20
        if text.count <= maxCount { return text }
        return String(text.prefix(maxCount)) + "..."
    }
    
    /// 长按消息操作层：背景虚化 + 消息聚焦 + 上方表情 + 下方操作
    private var messageLongPressOverlay: some View {
        Group {
            if let target = messageActionTarget {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.08))
                        .ignoresSafeArea()
                        .onTapGesture { dismissMessageActionOverlay() }
                    VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            ForEach(Self.reactionEmojis, id: \.self) { emoji in
                                Button(action: { onReactionSelectedFromLongPress(emoji, for: target) }) {
                                    Text(emoji)
                                        .font(.system(size: 30))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(Capsule())
                        
                        longPressFocusBubble(target)
                        
                        VStack(spacing: 8) {
                            overlayActionButton("回复", "arrowshape.turn.up.left") {
                                replyToMessage(target)
                                dismissMessageActionOverlay()
                            }
                            overlayActionButton("转发", "arrowshape.turn.up.right") {
                                Task { await forwardMessageFromOverlay(target) }
                            }
                            overlayActionButton("复制", "doc.on.doc") {
                                copyMessage(target)
                                showActionToast("已复制")
                                dismissMessageActionOverlay()
                            }
                            overlayActionButton("收藏", "star") {
                                Task { await favoriteMessageFromOverlay(target) }
                            }
                            overlayActionButton("删除", "trash", destructive: true, disabled: !(isOutgoing(target) && target.message_type != 15)) {
                                dismissMessageActionOverlay()
                                requestDeleteMessage(target)
                            }
                        }
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 16)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity.combined(with: .scale(scale: 0.985))
                    )
                )
            }
        }
    }
    
    @ViewBuilder
    private func longPressFocusBubble(_ msg: Message) -> some View {
        let outgoing = isOutgoing(msg)
        let isDeleted = (msg.message_type == 15)
        let body = messageBody(msg)
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 6) {
            if msg.message_type == 1, let path = msg.media_file_path, !path.isEmpty {
                MessageThumbView(
                    boxIP: boxIPForMedia,
                    index: indexForMedia,
                    filePath: path,
                    messageID: msg.message_id,
                    appType: container.appType,
                    streamUUID: container.uuid ?? instanceId,
                    onOpenOriginal: { _ in }
                )
            } else {
                Text(body)
                    .font(.system(size: 15))
                    .foregroundColor(outgoing ? .white : Color(white: 0.15))
                    .lineLimit(6)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDeleted ? Color(red: 0.87, green: 0.21, blue: 0.23) : (outgoing ? Color(red: 0.2, green: 0.72, blue: 0.45) : Color.white))
        )
        .frame(maxWidth: 280, alignment: outgoing ? .trailing : .leading)
    }
    
    private func overlayActionButton(_ title: String, _ system: String, destructive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(destructive ? Color.red : (disabled ? Color(white: 0.7) : Color(white: 0.2)))
            .frame(width: 200, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(white: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
    
    private func showActionToast(_ text: String) {
        appState.presentUserFeedback(text, level: .info)
    }
    
    private func forwardMessageFromOverlay(_ msg: Message) async {
        if msg.message_type == 1 {
            if let image = await resolveImageForMessageAction(msg) {
                await MainActor.run {
                    openForwardConversationPicker(payload: .image(image))
                    dismissMessageActionOverlay()
                }
            } else {
                await MainActor.run {
                    showActionToast("图片加载失败，无法转发")
                    dismissMessageActionOverlay()
                }
            }
            return
        }
        let text = (msg.text_data ?? messageBody(msg)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            await MainActor.run {
                showActionToast("无可转发内容")
                dismissMessageActionOverlay()
            }
            return
        }
        await MainActor.run {
            openForwardConversationPicker(payload: .text(text))
            dismissMessageActionOverlay()
        }
    }
    
    private func favoriteMessageFromOverlay(_ msg: Message) async {
        if msg.message_type == 1, let image = await resolveImageForMessageAction(msg) {
            let title = "聊天收藏_\(Int(Date().timeIntervalSince1970))"
            guard let item = QuickImageTemplate.make(title: title, image: image) else {
                await MainActor.run { showActionToast("收藏失败") }
                return
            }
            QuickTemplateStore.saveImageTemplate(item)
            await MainActor.run {
                showActionToast("已收藏到图片模板")
                dismissMessageActionOverlay()
            }
            return
        }
        let text = (msg.text_data ?? messageBody(msg)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            await MainActor.run { showActionToast("无可收藏内容") }
            return
        }
        let item = QuickScriptTemplate(
            id: UUID().uuidString,
            title: "聊天收藏_\(Int(Date().timeIntervalSince1970))",
            category: "聊天收藏",
            content: text,
            updatedAt: Date()
        )
        QuickTemplateStore.saveScriptTemplate(item)
        await MainActor.run {
            showActionToast("已收藏到话术模板")
            dismissMessageActionOverlay()
        }
    }
    
    private func resolveImageForMessageAction(_ msg: Message) async -> UIImage? {
        if let kid = msg.key_id, let temp = tempOutgoingImagesByKeyID[kid] {
            return temp
        }
        guard let path = msg.media_file_path, !path.isEmpty else { return nil }
        do {
            let data = try await ChatService.shared.fetchMediaStream(
                boxIP: boxIPForMedia,
                index: indexForMedia,
                filePath: path,
                messageId: msg.message_id,
                isThumb: false,
                appType: container.appType,
                instanceId: container.uuid ?? instanceId
            )
            if let img = UIImage(data: data) { return img }
        } catch { }
        do {
            let data = try await ChatService.shared.fetchMediaStream(
                boxIP: boxIPForMedia,
                index: indexForMedia,
                filePath: path,
                messageId: msg.message_id,
                isThumb: true,
                appType: container.appType,
                instanceId: container.uuid ?? instanceId
            )
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
    
    private func persistScrollAnchorIfNeeded() {
        chatAnchorLog("persist begin conversation=\(conversationKey) bottomDistance=\(Int(bottomDistance)) viewport=\(Int(messageViewportHeight)) anchor=\(currentAnchorMessageID ?? "nil") hasUserScrolled=\(hasUserScrolledInSession) latestAreaNow=\(isViewingLatestArea) lockToBottom=\(shouldLockToBottomOnEntry)")
        if hasUserScrolledInSession,
           let anchor = currentAnchorMessageID,
           !anchor.isEmpty,
           isAnchorClearlyAwayFromBottom(anchor) {
            appState.chatScrollAnchorByConversation[conversationKey] = anchor
            logPosition("persist saved anchor=\(anchor) by userScrolled=true bottomDistance=\(Int(bottomDistance)) viewport=\(Int(messageViewportHeight))")
            chatAnchorLog("persist saved conversation=\(conversationKey) anchor=\(anchor)")
        } else if isViewingLatestArea {
            appState.chatScrollAnchorByConversation.removeValue(forKey: conversationKey)
            logPosition("persist cleared anchor because viewing latest area bottomDistance=\(Int(bottomDistance))")
            chatAnchorLog("persist cleared conversation=\(conversationKey)")
        } else if shouldLockToBottomOnEntry {
            appState.chatScrollAnchorByConversation.removeValue(forKey: conversationKey)
            chatAnchorLog("persist clearedByEntryBottom conversation=\(conversationKey)")
        } else {
            let existing = appState.chatScrollAnchorByConversation[conversationKey] ?? "nil"
            logPosition("persist keep existing anchor=\(existing) bottomDistance=\(Int(bottomDistance)) viewport=\(Int(messageViewportHeight))")
            chatAnchorLog("persist keptExisting conversation=\(conversationKey) anchor=\(existing)")
        }
    }
    
    private var shouldShowScrollToLatestButton: Bool {
        guard didFinishInitialMessageLoad, hasUserScrolledInSession, messages.count > 8 else { return false }
        return !isViewingLatestArea
    }

    private func isAnchorNearBottom(_ anchor: String, threshold: Int = 3) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == anchor }) else {
            return bottomDistance <= 24
        }
        let trailingCount = max(0, messages.count - 1 - idx)
        return trailingCount <= max(1, threshold)
    }

    private func isAnchorClearlyAwayFromBottom(_ anchor: String) -> Bool {
        guard !anchor.isEmpty else {
            return bottomDistance > max(160, messageViewportHeight * 0.45)
        }
        if let idx = messages.firstIndex(where: { $0.id == anchor }) {
            let trailingCount = max(0, messages.count - 1 - idx)
            if trailingCount >= 10 {
                return true
            }
            if trailingCount <= 4 {
                return false
            }
        }
        return bottomDistance > max(160, messageViewportHeight * 0.45)
    }

    private var isViewingLatestArea: Bool {
        if hasUserScrolledInSession,
           let anchor = currentAnchorMessageID,
           !anchor.isEmpty {
            if isAnchorClearlyAwayFromBottom(anchor) {
                return false
            }
            return isAnchorNearBottom(anchor, threshold: 6)
        }
        if messageViewportHeight > 0, bottomDistance <= 40 {
            return true
        }
        guard let anchor = currentAnchorMessageID, !anchor.isEmpty else {
            return bottomDistance <= 24
        }
        return isAnchorNearBottom(anchor, threshold: 6)
    }
    
    /// 首次进入无动画单次定位：优先恢复离开前锚点，其次落到底部。
    private func scrollToBottomStably(_ proxy: ScrollViewProxy) {
        guard !didInitialPositioning else { return }
        didInitialPositioning = true
        let targetMessageID = resolvedInitialScrollMessageID()
        let restoreAnchor = appState.chatScrollAnchorByConversation[conversationKey]
        let shouldRestoreAnchor = targetMessageID == nil && !forceScrollToLatestOnEntry && !(restoreAnchor ?? "").isEmpty
        logPosition("initialPosition target=\(targetMessageID ?? "nil") shouldRestore=\(shouldRestoreAnchor) forceLatest=\(forceScrollToLatestOnEntry) restoreAnchor=\(restoreAnchor ?? "nil")")
        chatAnchorLog("initialPosition conversation=\(conversationKey) target=\(targetMessageID ?? "nil") shouldRestore=\(shouldRestoreAnchor) restoreAnchor=\(restoreAnchor ?? "nil") forceLatest=\(forceScrollToLatestOnEntry)")
        DispatchQueue.main.async {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                if let targetMessageID {
                    didApplyInitialScrollTarget = true
                    pendingScrollToMessageID = targetMessageID
                    logPosition("initialPosition scrollTo target=\(targetMessageID)")
                    chatAnchorLog("initialPosition action=target conversation=\(conversationKey) id=\(targetMessageID)")
                    proxy.scrollTo(targetMessageID, anchor: .center)
                } else if shouldRestoreAnchor, let restoreAnchor {
                    logPosition("initialPosition scrollTo restore anchor=\(restoreAnchor)")
                    chatAnchorLog("initialPosition action=restore conversation=\(conversationKey) anchor=\(restoreAnchor)")
                    proxy.scrollTo(restoreAnchor, anchor: .top)
                } else {
                    logPosition("initialPosition scrollTo chatBottom")
                    chatAnchorLog("initialPosition action=bottom conversation=\(conversationKey)")
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                    scheduleEntryBottomCorrections()
                }
            }
        }
    }
    
    @ViewBuilder
    private func outgoingStatusView(for msg: Message) -> some View {
        switch msg.deliveryState {
        case .localProcessing:
            ZStack {
                Circle()
                    .fill(Color(red: 0.07, green: 0.52, blue: 0.95).opacity(0.14))
                    .frame(width: 16, height: 16)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.07, green: 0.52, blue: 0.95)))
                    .scaleEffect(0.72)
            }
        case .pendingSync, .sending:
            // 与 H5 对齐：998(待刷新)与 0/1(待发送/发送中)用等待态，不显示单勾
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.55))
        case .failed:
            Button(action: { showFailedOutgoingDetail(for: msg) }) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.9, green: 0.28, blue: 0.25))
            }
            .buttonStyle(.plain)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.45))
        case .delivered, .read:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(msg.deliveryState == .read ? Color(red: 0.2, green: 0.72, blue: 0.95) : Color(white: 0.45))
        case .unknown:
            EmptyView()
        }
    }

    private func showFailedOutgoingDetail(for msg: Message) {
        let key = msg.id
        let fallback = "消息发送失败，请重试"
        let reason = (failedOutgoingReasonByMessageID[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        failedOutgoingDetailText = reason.isEmpty ? fallback : reason
    }
    
    private func sendOrEditMessage() async {
        if sendingAction { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = (selectedImage != nil)
        let editing = (editingMessage != nil)
        guard hasImage || !text.isEmpty else { return }
        if hasImage && !text.isEmpty {
            await MainActor.run { errorMessage = "图片和文本不能同时发送" }
            return
        }
        guard let boxIP = boxIP, !boxIP.isEmpty else {
            await MainActor.run { errorMessage = "容器 IP 缺失，无法发送" }
            return
        }
        guard let jid = chat.jid, !jid.isEmpty else {
            await MainActor.run { errorMessage = "会话 JID 缺失，无法发送" }
            return
        }
        
        let target = editingMessage ?? quotedMessage
        let targetQuoted = makeQuotedMessage(from: target)
        let originalInputText = inputText
        let originalSelectedImage = selectedImage
        let originalQuoted = quotedMessage
        let originalEditing = editingMessage
        let originalPendingMentionTokens = pendingMentionTokens
        let encodedOutgoingText = hasImage ? nil : composeOutgoingTextWithMentions(text)
        var tempMessageID: String?
        var editingMessageIndex: Int?
        var editingOriginalStatus: Int?
        
        if !editing {
            let kid = "local_\(Int(Date().timeIntervalSince1970 * 1000))"
            tempMessageID = kid
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            let tempMsg = Message(
                message_id: Int(Date().timeIntervalSince1970 * 1000),
                key_id: kid,
                from_me: 1,
                key_from_me: 1,
                text_data: text,
                timestamp: ts,
                message_type: hasImage ? 1 : 0,
                status: 999,
                sender: nil,
                sender_name: nil,
                media_file_path: nil,
                media_url: nil,
                media_key: nil,
                reaction: nil,
                quote_message: targetQuoted
            )
            if shouldTraceMentionMessage(tempMsg) {
                mentionStateLog("temp create conversation=\(conversationKey) key=\(kid) mid=\(tempMsg.message_id ?? 0) status=\(tempMsg.status ?? -1) raw=\(tempMsg.text_data ?? "") rendered=\(renderedMessageText(tempMsg.text_data)) encoded=\(encodedOutgoingText ?? "")")
            }
            await MainActor.run {
                if let img = originalSelectedImage {
                    tempOutgoingImagesByKeyID[kid] = img
                }
                messages.append(tempMsg)
                pendingOutgoingPayloadByKeyID[kid] = PendingOutgoingPayload(
                    text: text,
                    encodedText: encodedOutgoingText,
                    hasImage: hasImage,
                    quoted: targetQuoted
                )
                inputText = ""
                appState.clearChatDraft(conversationKey: conversationKey)
                selectedImage = nil
                quotedMessage = nil
                editingMessage = nil
                pendingMentionTokens = []
            }
            await persistMessagesSnapshot()
        } else if let edit = originalEditing, let idx = messages.firstIndex(where: { $0.id == edit.id }) {
            editingMessageIndex = idx
            editingOriginalStatus = messages[idx].status
            await MainActor.run {
                messages[idx].status = 999
            }
            await persistMessagesSnapshot()
        }
        
        sendingAction = true
        defer { sendingAction = false }
        do {
            var quotedIndex: Int? = nil
            if let target, let idx = messages.firstIndex(where: { $0.id == target.id }) {
                quotedIndex = messages.count - idx
                if editing { quotedIndex = (quotedIndex ?? 0) + 1 }
            }
            let params = ChatService.CallSCRMFuncParams(
                instanceID: container.uuid ?? instanceId,
                method: editing ? "edit_message" : (hasImage ? "send_image" : "send_message"),
                name: container.name ?? "",
                ip: boxIP,
                index: container.index ?? 1,
                jid: jid,
                message: encodedOutgoingText ?? text,
                contactName: contactNameForSend(jid: jid),
                emoji: nil,
                quotedIndex: quotedIndex,
                quotedText: target?.text_data ?? target.map { messageBody($0) },
                quotedType: target?.message_type,
                quotedTimestamp: target?.timestamp,
                appType: container.appType,
                cloneID: nil,
                targetLang: "",
                imageData: hasImage ? originalSelectedImage?.jpegData(compressionQuality: 0.88) : nil,
                imageFileName: hasImage ? "image_\(Int(Date().timeIntervalSince1970)).jpg" : nil
            )
            let res = try await callSCRMFuncWithRunningCheck(params)
            guard res.code == 1 else {
                await MainActor.run {
                    let failText = res.msg ?? (editing ? "消息编辑失败" : "消息发送失败")
                    errorMessage = failText
                    if editing {
                        inputText = originalInputText
                        appState.setChatDraft(conversationKey: conversationKey, text: originalInputText)
                        selectedImage = originalSelectedImage
                        quotedMessage = originalQuoted
                        editingMessage = originalEditing
                        pendingMentionTokens = originalPendingMentionTokens
                    }
                    if let kid = tempMessageID {
                        if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                            messages[idx].status = 997
                        }
                        failedOutgoingReasonByMessageID[kid] = failText
                    }
                    if let idx = editingMessageIndex {
                        messages[idx].status = editingOriginalStatus
                    }
                }
                await persistMessagesSnapshot()
                return
            }
            await MainActor.run {
                errorMessage = nil
                if let kid = tempMessageID, let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                    messages[idx].status = 998
                    failedOutgoingReasonByMessageID.removeValue(forKey: kid)
                }
                if editing {
                    inputText = ""
                    appState.clearChatDraft(conversationKey: conversationKey)
                    quotedMessage = nil
                    editingMessage = nil
                    pendingMentionTokens = []
                    if let idx = editingMessageIndex {
                        messages[idx].status = 998
                    }
                }
            }
            await persistMessagesSnapshot()
            try? await Task.sleep(nanoseconds: 800_000_000)
            await loadMessages()
        } catch is CancellationError {
            await MainActor.run {
                if editing {
                    inputText = originalInputText
                    appState.setChatDraft(conversationKey: conversationKey, text: originalInputText)
                    selectedImage = originalSelectedImage
                    quotedMessage = originalQuoted
                    editingMessage = originalEditing
                    pendingMentionTokens = originalPendingMentionTokens
                }
                if let kid = tempMessageID,
                   let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                    messages.remove(at: idx)
                    pendingOutgoingPayloadByKeyID.removeValue(forKey: kid)
                    tempOutgoingImagesByKeyID.removeValue(forKey: kid)
                }
                if let idx = editingMessageIndex {
                    messages[idx].status = editingOriginalStatus
                }
                if errorMessage == nil || errorMessage?.isEmpty == true {
                    errorMessage = "已取消发送"
                }
            }
            await persistMessagesSnapshot()
        } catch {
            await MainActor.run {
                let failText = editing ? "消息编辑失败" : "消息发送失败"
                errorMessage = failText
                if editing {
                    inputText = originalInputText
                    appState.setChatDraft(conversationKey: conversationKey, text: originalInputText)
                    selectedImage = originalSelectedImage
                    quotedMessage = originalQuoted
                    editingMessage = originalEditing
                    pendingMentionTokens = originalPendingMentionTokens
                }
                if let kid = tempMessageID {
                    if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                        messages[idx].status = 997
                    }
                    failedOutgoingReasonByMessageID[kid] = failText
                }
                if let idx = editingMessageIndex {
                    messages[idx].status = editingOriginalStatus
                }
            }
            await persistMessagesSnapshot()
        }
    }
    
    private func retryPendingMessage(_ msg: Message) {
        guard !sendingAction else { return }
        guard let kid = msg.key_id, kid.hasPrefix("local_"),
              let payload = pendingOutgoingPayloadByKeyID[kid],
              let boxIP = boxIP, !boxIP.isEmpty,
              let jid = chat.jid, !jid.isEmpty else { return }
        Task {
            await MainActor.run {
                if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                    messages[idx].status = 999
                }
                failedOutgoingReasonByMessageID.removeValue(forKey: kid)
            }
            await persistMessagesSnapshot()
            sendingAction = true
            defer { sendingAction = false }
            do {
                let imageData = payload.hasImage ? tempOutgoingImagesByKeyID[kid]?.jpegData(compressionQuality: 0.88) : nil
                let params = ChatService.CallSCRMFuncParams(
                    instanceID: container.uuid ?? instanceId,
                    method: payload.hasImage ? "send_image" : "send_message",
                    name: container.name ?? "",
                    ip: boxIP,
                    index: container.index ?? 1,
                    jid: jid,
                    message: payload.hasImage ? payload.text : (payload.encodedText ?? payload.text),
                    contactName: contactNameForSend(jid: jid),
                    emoji: nil,
                    quotedIndex: payload.quoted.flatMap { quoted in
                        if let key = quoted.key_id, !key.isEmpty,
                           let idx = messages.firstIndex(where: { ($0.key_id ?? "") == key }) {
                            return messages.count - idx
                        }
                        if let mid = quoted.message_id, mid > 0,
                           let idx = messages.firstIndex(where: { $0.message_id == mid }) {
                            return messages.count - idx
                        }
                        return nil
                    },
                    quotedText: payload.quoted.flatMap { quoted in
                        let text = (quoted.text_data ?? quoted.data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : text
                    },
                    quotedType: payload.quoted?.message_type,
                    quotedTimestamp: payload.quoted?.timestamp,
                    appType: container.appType,
                    cloneID: nil,
                    targetLang: "",
                    imageData: imageData,
                    imageFileName: payload.hasImage ? "image_\(Int(Date().timeIntervalSince1970)).jpg" : nil
                )
                let res = try await callSCRMFuncWithRunningCheck(params)
                guard res.code == 1 else {
                    await MainActor.run {
                        if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                            messages[idx].status = 997
                        }
                        let failText = res.msg ?? "重发失败"
                        errorMessage = failText
                        failedOutgoingReasonByMessageID[kid] = failText
                    }
                    await persistMessagesSnapshot()
                    return
                }
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                        messages[idx].status = 998
                    }
                    errorMessage = nil
                    failedOutgoingReasonByMessageID.removeValue(forKey: kid)
                }
                await persistMessagesSnapshot()
                try? await Task.sleep(nanoseconds: 700_000_000)
                await loadMessages()
            } catch {
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.key_id == kid }) {
                        messages[idx].status = 997
                    }
                    let failText = "重发失败"
                    errorMessage = failText
                    failedOutgoingReasonByMessageID[kid] = failText
                }
                await persistMessagesSnapshot()
            }
        }
    }
    
    private func contactNameForSend(jid: String) -> String {
        if jid.hasSuffix("@g.us") {
            return displayName()
        }
        return effectiveContacts
            .filter { $0.jid == jid }
            .compactMap(\.display_name)
            .joined(separator: "#!#")
    }
    
    private func persistMessagesSnapshot() async {
        let snapshot = await MainActor.run { messages }
        await AppCacheStore.shared.saveMessages(instanceId: instanceId, chatRowId: chatRowId, messages: snapshot)
    }
    
    private func sendReaction(_ emoji: String, for target: Message) async {
        if sendingAction { return }
        guard let boxIP = boxIP, !boxIP.isEmpty, let jid = chat.jid, !jid.isEmpty else { return }
        sendingAction = true
        defer { sendingAction = false }
        do {
            var quotedIndex: Int? = nil
            if let idx = messages.firstIndex(where: { $0.id == target.id }) {
                quotedIndex = messages.count - idx + 1
            }
            let params = ChatService.CallSCRMFuncParams(
                instanceID: container.uuid ?? instanceId,
                method: "like_emoji",
                name: container.name ?? "",
                ip: boxIP,
                index: container.index ?? 1,
                jid: jid,
                message: nil,
                contactName: contactNameForSend(jid: jid),
                emoji: emoji,
                quotedIndex: quotedIndex,
                quotedText: target.text_data ?? messageBody(target),
                quotedType: target.message_type,
                quotedTimestamp: target.timestamp,
                appType: container.appType,
                cloneID: nil,
                targetLang: "",
                imageData: nil,
                imageFileName: nil
            )
            let res = try await callSCRMFuncWithRunningCheck(params)
            guard res.code == 1 else { return }
            await refreshSingleMessage(target)
        } catch { }
    }
    
    private func callSCRMFuncWithRunningCheck(_ params: ChatService.CallSCRMFuncParams) async throws -> ChatService.CallSCRMFuncResult {
        let ready = await ensureRunningTaskReady(ip: params.ip, index: params.index)
        guard ready else { throw CancellationError() }
        switch params.method {
        case "send_message", "send_image":
            return try await ChatService.shared.enqueueSCRMTask(params)
        default:
            return try await ChatService.shared.callSCRMFunc(params)
        }
    }
    
    private func ensureRunningTaskReady(ip: String, index: Int) async -> Bool {
        do {
            let status = try await ChatService.shared.getRunningTask(ip: ip, index: index)
            guard status.locked else { return true }
            let type = (status.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == "cul" {
                await MainActor.run {
                    errorMessage = "当前实例正在运行养号任务（任务ID：\(status.taskID ?? "-")），请先停止后再发送"
                }
                return false
            }
            if type == "scrm" {
                let shouldStop = await promptStopRunningTask(taskID: status.taskID)
                guard shouldStop else {
                    await MainActor.run { errorMessage = "已取消发送" }
                    return false
                }
                try await ChatService.shared.stopRunningTask(ip: ip, index: index)
                return true
            }
            await MainActor.run { errorMessage = "当前实例存在运行中任务，请稍后再试" }
            return false
        } catch {
            await MainActor.run { errorMessage = "检测运行任务失败，请稍后重试" }
            return false
        }
    }
    
    private func promptStopRunningTask(taskID: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                runningTaskPromptContext = RunningTaskPromptContext(
                    taskID: taskID,
                    continuation: continuation
                )
            }
        }
    }
    
    private func resolveRunningTaskPrompt(stopAndContinue: Bool) {
        guard let ctx = runningTaskPromptContext else { return }
        runningTaskPromptContext = nil
        ctx.continuation.resume(returning: stopAndContinue)
    }
    
    private func refreshSingleMessage(_ msg: Message) async {
        guard let mid = msg.message_id, mid > 0 else {
            await loadMessages()
            return
        }
        if shouldTraceMentionMessage(msg) {
            mentionStateLog("detail refresh start conversation=\(conversationKey) key=\(msg.key_id ?? "") mid=\(mid) status=\(msg.status ?? -1) raw=\(msg.text_data ?? "") rendered=\(renderedMessageText(msg.text_data))")
        }
        do {
            let detail = try await ChatService.shared.getMessageDetail(
                chatRowId: chatRowId,
                instanceId: instanceId,
                messageId: mid,
                boxIP: boxIP,
                index: container.index
            )
            await MainActor.run {
                if let idx = messages.firstIndex(where: { $0.id == msg.id || $0.message_id == mid }) {
                    let detailID = detail.messageID ?? 0
                    let detailKey = (detail.keyID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasUsableIdentity = detailID > 0 || !detailKey.isEmpty
                    if !hasUsableIdentity {
                        if shouldTraceMentionMessage(msg) {
                            mentionStateLog("detail refresh ignoredInvalid conversation=\(conversationKey) key=\(msg.key_id ?? "") mid=\(mid) detailID=\(detailID) detailKey=\(detailKey) detailStatus=\(detail.status ?? -1) detailRaw=\(detail.textData ?? "")")
                        }
                        return
                    }
                    var item = messages[idx]
                    let beforeRaw = item.text_data ?? ""
                    let beforeRendered = renderedMessageText(item.text_data)
                    let beforeStatus = item.status ?? -1
                    let existingRenderedText = renderedMessageText(item.text_data)
                    let existingHasMentionMarkup = containsMentionMarkup(item.text_data)
                    if detailID > 0 { item.message_id = detailID }
                    if !detailKey.isEmpty { item.key_id = detailKey }
                    if let v = detail.textData {
                        let newRenderedText = renderedMessageText(v)
                        let newHasMentionMarkup = containsMentionMarkup(v)
                        let shouldKeepExistingText =
                            !existingRenderedText.isEmpty &&
                            (newRenderedText.isEmpty || (existingHasMentionMarkup && !newHasMentionMarkup))
                        if !shouldKeepExistingText,
                           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            item.text_data = v
                        }
                    }
                    if let v = detail.timestamp { item.timestamp = v }
                    if let v = detail.messageType { item.message_type = v }
                    if let v = detail.status { item.status = v }
                    if let v = detail.mediaFilePath { item.media_file_path = v }
                    if let v = detail.mediaURL { item.media_url = v }
                    if let v = detail.mediaKey { item.media_key = v }
                    if let v = detail.reaction { item.reaction = v }
                    if shouldTraceMentionMessage(msg) || containsMentionMarkup(detail.textData) || renderedMessageText(detail.textData).contains("@") {
                        mentionStateLog("detail refresh apply conversation=\(conversationKey) key=\(item.key_id ?? "") mid=\(item.message_id ?? 0) status \(beforeStatus)->\(item.status ?? -1) beforeRaw=\(beforeRaw) beforeRendered=\(beforeRendered) detailRaw=\(detail.textData ?? "") detailRendered=\(renderedMessageText(detail.textData)) afterRaw=\(item.text_data ?? "") afterRendered=\(renderedMessageText(item.text_data))")
                    }
                    messages[idx] = item
                    let snapshot = messages
                    Task {
                        await AppCacheStore.shared.saveMessages(instanceId: instanceId, chatRowId: chatRowId, messages: snapshot)
                    }
                }
            }
        } catch { }
    }
    
    private func scheduleMediaPathRefreshIfNeeded(for msgs: [Message]) {
        for m in msgs {
            guard let t = m.message_type, [1, 3, 13].contains(t) else { continue }
            guard let mid = m.message_id, mid > 0 else { continue }
            let path = m.media_file_path ?? ""
            let shouldRefresh = path.isEmpty || path.hasPrefix("/data/user/")
            if !shouldRefresh || pendingMediaRefreshIDs.contains(mid) { continue }
            pendingMediaRefreshIDs.insert(mid)
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refreshSingleMessage(m)
                await MainActor.run { pendingMediaRefreshIDs.remove(mid) }
            }
        }
    }

    private func normalizeMessageIdentifiers(_ msgs: [Message]) -> [Message] {
        var seen: [String: Int] = [:]
        return msgs.map { original in
            var item = original
            let key = (item.key_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return item }
            if let mid = item.message_id, mid > 0 { return item }

            let text = (item.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let media = (item.media_file_path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ts = item.timestamp ?? 0
            let type = item.message_type ?? -1
            let from = item.from_me ?? item.key_from_me ?? -1
            let sender = (item.sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let base = "fallback_\(ts)_\(type)_\(from)_\(sender)_\(text.prefix(24))_\(media.prefix(24))"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            let synthetic = occurrence == 0 ? base : "\(base)#\(occurrence)"
            item.key_id = synthetic
            chatDiagLog("normalizeMessageIdentifier syntheticKey=\(synthetic) ts=\(ts) type=\(type)")
            return item
        }
    }
    
    /// 远端拉取后保留尚未被服务端确认的本地临时气泡，避免「✅后瞬间消失」。
    /// 当远端出现同类型/同文案/近时间戳的出站消息时，自动认为已确认并移除本地临时项。
    private func mergeRemoteMessagesPreservingLocal(_ remoteOrdered: [Message], currentLocal: [Message]) -> [Message] {
        var merged = normalizeMessageIdentifiers(remoteOrdered)
        let normalizedLocal = normalizeMessageIdentifiers(currentLocal)
        var localByStableID: [String: Message] = [:]
        for msg in normalizedLocal {
            let key = (msg.key_id?.isEmpty == false ? msg.key_id! : "\(msg.message_id ?? 0)")
            localByStableID[key] = msg
        }
        
        // 优先保留本地已删除状态，避免服务端消息延迟导致“退出重进又恢复未删”
        for idx in merged.indices {
            var item = merged[idx]
            let stableID = (item.key_id?.isEmpty == false ? item.key_id! : "\(item.message_id ?? 0)")
            guard let local = localByStableID[stableID] else { continue }
            let localDeleted = (local.message_type == 15)
            if localDeleted, item.message_type != 15 {
                item.message_type = 15
                let remoteText = (item.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let localText = (local.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if remoteText.isEmpty, !localText.isEmpty {
                    item.text_data = local.text_data
                }
                merged[idx] = item
                continue
            }
            if item.message_type == 15 {
                let remoteText = (item.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let localText = (local.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if remoteText.isEmpty, !localText.isEmpty {
                    item.text_data = local.text_data
                    merged[idx] = item
                }
            }
        }
        
        // 优先保留本地已解析出的媒体路径，避免进入聊天页时图片先占位再闪现
        for idx in merged.indices {
            var item = merged[idx]
            guard let t = item.message_type, [1, 3, 13].contains(t) else { continue }
            let stableID = (item.key_id?.isEmpty == false ? item.key_id! : "\(item.message_id ?? 0)")
            guard let local = localByStableID[stableID] else { continue }
            let remotePath = (item.media_file_path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localPath = (local.media_file_path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if remotePath.isEmpty, !localPath.isEmpty {
                item.media_file_path = localPath
                merged[idx] = item
            }
        }

        // 文本消息在服务端增量刷新阶段偶尔会回空 data，此时保留本地已有正文，避免群聊 @ 消息闪成空白气泡。
        for idx in merged.indices {
            var item = merged[idx]
            let stableID = (item.key_id?.isEmpty == false ? item.key_id! : "\(item.message_id ?? 0)")
            guard let local = localByStableID[stableID] else { continue }
            let beforeRaw = item.text_data ?? ""
            let remoteText = renderedMessageText(item.text_data)
            let localText = renderedMessageText(local.text_data)
            let remoteHasMentionMarkup = containsMentionMarkup(item.text_data)
            let localHasMentionMarkup = containsMentionMarkup(local.text_data)
            if (remoteText.isEmpty && !localText.isEmpty)
                || (localHasMentionMarkup && !remoteHasMentionMarkup && !localText.isEmpty) {
                item.text_data = local.text_data
                if localHasMentionMarkup || remoteHasMentionMarkup || localText.contains("@") || remoteText.contains("@") {
                    mentionStateLog("merge preserve text conversation=\(conversationKey) key=\(stableID) remoteRaw=\(beforeRaw) remoteRendered=\(remoteText) localRaw=\(local.text_data ?? "") localRendered=\(localText) finalRaw=\(item.text_data ?? "")")
                }
                merged[idx] = item
            }
        }
        
        // 本地临时发送态优先，避免远端回包前状态回滚（sending -> unknown）
        for idx in merged.indices {
            var item = merged[idx]
            let stableID = (item.key_id?.isEmpty == false ? item.key_id! : "\(item.message_id ?? 0)")
            guard let local = localByStableID[stableID] else { continue }
            if local.deliveryState.isTransient, !item.isDeletedMessage {
                item.status = local.status
                merged[idx] = item
            }
        }
        
        let remoteIDs = Set(remoteOrdered.map(\.id))
        let mergedIDs = Set(merged.map(\.id))
        
        for local in normalizedLocal {
            guard let kid = local.key_id, kid.hasPrefix("local_") else { continue }
            if remoteIDs.contains(local.id) { continue }
            
            let matchedByRemote = remoteOrdered.contains { remote in
                guard isOutgoing(remote) else { return false }
                if (remote.message_type ?? -1) != (local.message_type ?? -1) { return false }
                if (remote.text_data ?? "") != (local.text_data ?? "") { return false }
                guard let lts = local.timestamp, let rts = remote.timestamp else { return false }
                return abs(rts - lts) <= 120_000
            }
            if matchedByRemote { continue }
            merged.append(local)
        }

        // H5 的历史加载是 prepend 到当前 messages 上，并不会在后续刷新第一页时把已加载历史抹掉。
        // iOS 这里如果只保留 remoteOrdered（最新 50 条）+ 本地临时消息，就会把用户向上翻出来的历史页冲掉。
        // 因此需要把当前列表里“已加载的远端历史消息”也继续保留，直到用户切换会话或主动重新同步。
        for local in normalizedLocal {
            if mergedIDs.contains(local.id) { continue }
            if remoteIDs.contains(local.id) { continue }
            if let kid = local.key_id, kid.hasPrefix("local_") { continue }

            let hasRemoteIdentity: Bool = {
                if let mid = local.message_id, mid > 0 { return true }
                let key = (local.key_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return !key.isEmpty
            }()
            guard hasRemoteIdentity else { continue }

            merged.append(local)
        }
        
        merged.sort { lhs, rhs in
            let lts = lhs.timestamp ?? 0
            let rts = rhs.timestamp ?? 0
            if lts != rts { return lts < rts }
            return (lhs.message_id ?? Int.max) < (rhs.message_id ?? Int.max)
        }
        return merged
    }
    
    private func resolveChatRowIdIfNeeded() async -> Int {
        if chatRowId > 0 {
            chatDiagLog("resolveChatRowId direct conversation=\(conversationKey) chatRowId=\(chatRowId)")
            return chatRowId
        }
        let jid = (chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return 0 }
        let cachedChats = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
        if let matched = cachedChats.first(where: {
            ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == jid
        }),
           let rowId = matched.chat_row_id,
           rowId > 0 {
            await MainActor.run { resolvedChatRowId = rowId }
            chatDiagLog("resolveChatRowId cacheHit conversation=\(conversationKey) chatRowId=\(rowId) cachedChats=\(cachedChats.count)")
            return rowId
        }
        chatDiagLog("resolveChatRowId failed conversation=\(conversationKey) jid=\(jid) cachedChats=\(cachedChats.count)")
        return 0
    }
    
    private func resolveGroupJidRowIdIfNeeded() async -> Int {
        if let jidRow = chat.jid_row_id, jidRow > 0 {
            groupUsersLog("resolve jid_row_id from chat=\(jidRow)")
            return jidRow
        }
        let jid = (chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else {
            groupUsersLog("resolve jid_row_id failed: empty chat.jid")
            return 0
        }
        let cachedChats = await AppCacheStore.shared.loadChats(instanceId: instanceId, maxAge: nil) ?? []
        if let matched = cachedChats.first(where: {
            ($0.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == jid
        }) {
            if let jidRow = matched.jid_row_id, jidRow > 0 {
                groupUsersLog("resolve jid_row_id from cache.jid_row_id=\(jidRow)")
                return jidRow
            }
            if let rowId = matched.chat_row_id, rowId > 0 {
                groupUsersLog("resolve jid_row_id fallback cache.chat_row_id=\(rowId)")
                return rowId
            }
        }
        if let rowId = chat.chat_row_id, rowId > 0 {
            groupUsersLog("resolve jid_row_id fallback chat.chat_row_id=\(rowId)")
            return rowId
        }
        groupUsersLog("resolve jid_row_id failed: no usable id for jid=\(jid)")
        return 0
    }

    private func openGroupUsersPanel() {
        guard isGroupConversation else { return }
        groupUsersSearchText = ""
        showGroupUsersSheet = true
        groupUsersPrefetchTask?.cancel()
        groupUsersPrefetchTask = Task {
            await prefetchGroupUsers(showLoading: true, forceRefresh: true)
        }
    }

    private func prefetchGroupUsers(showLoading: Bool, forceRefresh: Bool) async {
        chatDiagLog("prefetchGroupUsers start conversation=\(conversationKey) showLoading=\(showLoading) forceRefresh=\(forceRefresh)")
        groupUsersLog("prefetch start conversation=\(conversationKey) instance=\(instanceId) forceRefresh=\(forceRefresh) showLoading=\(showLoading)")
        guard isGroupConversation else {
            chatDiagLog("prefetchGroupUsers skip nonGroup conversation=\(conversationKey)")
            groupUsersLog("prefetch skip: not group conversation")
            await MainActor.run {
                groupUsers = []
                groupUsersLoading = false
            }
            return
        }
        if !forceRefresh {
            let hasCached = await MainActor.run { !groupUsers.isEmpty }
            if hasCached {
                groupUsersLog("prefetch skip: cached group users exists")
                return
            }
        }
        let groupJidRowId = await resolveGroupJidRowIdIfNeeded()
        guard groupJidRowId > 0 else {
            chatDiagLog("prefetchGroupUsers skip invalidGroupJidRowId conversation=\(conversationKey)")
            groupUsersLog("prefetch stop: invalid groupJidRowId=\(groupJidRowId)")
            return
        }
        let hasInMemory = await MainActor.run { !groupUsers.isEmpty }
        var hasImmediateData = hasInMemory
        if !hasInMemory,
           let cached = await AppCacheStore.shared.loadGroupUsers(instanceId: instanceId, groupJidRowId: groupJidRowId, maxAge: nil),
           !cached.isEmpty {
            await MainActor.run { groupUsers = cached }
            hasImmediateData = true
            groupUsersLog("prefetch cache loaded count=\(cached.count)")
        }
        groupUsersLog("prefetch resolved groupJidRowId=\(groupJidRowId) boxIP=\(boxIP ?? "") index=\(container.index ?? -1)")
        let shouldShowLoading = showLoading && !hasImmediateData
        if shouldShowLoading {
            await MainActor.run { groupUsersLoading = true }
        }
        defer {
            if shouldShowLoading {
                Task { @MainActor in groupUsersLoading = false }
            }
        }
        do {
            groupUsersLog("full request start")
            let fullList = try await ChatService.shared.getGroupUsersV2(
                instanceId: instanceId,
                groupJidRowId: groupJidRowId,
                boxIP: boxIP
            )
            groupUsersLog("full request success count=\(fullList.count)")
            var merged: [GroupUser] = [
                GroupUser(
                    ID: 0,
                    InstanceID: 0,
                    CloneID: "",
                    InstanceGroupUserID: 0,
                    instance_group_user_id: 0,
                    group_jid_row_id: 0,
                    jid: "me",
                    rank: 0,
                    display_name: nil,
                    remark_name: nil
                )
            ] + fullList
            
            let maxGroupUserId = fullList.map { $0.mergedGroupUserID }.max() ?? 0
            groupUsersLog("incremental request start since instance_group_user_id=\(maxGroupUserId)")
            let incremental = try await ChatService.shared.getGroupUserBySQLiteV2(
                instanceId: instanceId,
                groupJidRowId: groupJidRowId,
                instanceGroupUserId: maxGroupUserId,
                boxIP: boxIP,
                index: container.index
            )
            groupUsersLog("incremental request success count=\(incremental.count)")
            if !incremental.isEmpty {
                var existing = Set(merged.map { "\($0.mergedGroupUserID)_\($0.jid ?? "")" })
                for user in incremental {
                    let key = "\(user.mergedGroupUserID)_\(user.jid ?? "")"
                    if existing.contains(key) { continue }
                    existing.insert(key)
                    merged.append(user)
                }
            }
            await MainActor.run {
                groupUsers = merged
            }
            await AppCacheStore.shared.saveGroupUsers(instanceId: instanceId, groupJidRowId: groupJidRowId, users: merged)
            groupUsersLog("prefetch merged finalCount=\(merged.count)")
            chatDiagLog("prefetchGroupUsers success conversation=\(conversationKey) groupJidRowId=\(groupJidRowId) merged=\(merged.count)")
        } catch {
            groupUsersLog("prefetch failed error=\(error.localizedDescription)")
            chatDiagLog("prefetchGroupUsers failed conversation=\(conversationKey) groupJidRowId=\(groupJidRowId) error=\(error.localizedDescription)")
            if showLoading {
                await MainActor.run {
                    errorMessage = "加载群成员失败"
                }
            }
        }
    }

    private func confirmAddMembersToGroup() async {
        guard !addMemberSubmitting else { return }
        guard isGroupConversation else { return }
        guard let groupJid = chat.jid?.trimmingCharacters(in: .whitespacesAndNewlines), !groupJid.isEmpty else {
            await MainActor.run { errorMessage = "群聊 JID 缺失，无法添加成员" }
            return
        }
        guard let ip = boxIP?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else {
            await MainActor.run { errorMessage = "容器 IP 缺失，无法添加成员" }
            return
        }
        let selected = addMemberSelectedJIDs
            .map { normalizedPhoneForGroupMember($0) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !selected.isEmpty else { return }

        await MainActor.run { addMemberSubmitting = true }
        defer {
            Task { @MainActor in addMemberSubmitting = false }
        }

        let groupMembers = selected.joined(separator: "#!#")
        do {
            let params = ChatService.CallSCRMFuncParams(
                instanceID: container.uuid ?? instanceId,
                method: "add_group_member",
                name: container.name ?? "",
                ip: ip,
                index: container.index ?? 1,
                jid: groupJid,
                message: "",
                contactName: contactNameForSend(jid: groupJid),
                phoneOverride: "group",
                emoji: nil,
                quotedIndex: nil,
                quotedText: nil,
                quotedType: nil,
                quotedTimestamp: nil,
                appType: container.appType,
                cloneID: "",
                targetLang: "",
                imageData: nil,
                imageFileName: nil,
                extraFields: [
                    "group_members": groupMembers
                ]
            )
            let res = try await callSCRMFuncWithRunningCheck(params)
            if res.code == 1 {
                await MainActor.run {
                    showAddGroupMembersSheet = false
                    addMemberSelectedJIDs = []
                    errorMessage = nil
                }
                groupUsersPrefetchTask?.cancel()
                groupUsersPrefetchTask = Task {
                    await prefetchGroupUsers(showLoading: true, forceRefresh: true)
                }
                return
            }
            await MainActor.run {
                errorMessage = "添加成员失败：\(res.msg ?? "未知错误")"
            }
        } catch {
            await MainActor.run {
                errorMessage = "添加成员失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadMessages() async {
        if loading {
            chatDiagLog("loadMessages skip alreadyLoading conversation=\(conversationKey)")
            return
        }
        let beginAt = Date()
        let activeChatRowId = await resolveChatRowIdIfNeeded()
        chatDiagLog("loadMessages start conversation=\(conversationKey) resolvedChatRowId=\(activeChatRowId) existingMessages=\(messages.count)")
        guard activeChatRowId > 0 else {
            errorMessage = "未找到聊天对话"
            didFinishInitialMessageLoad = true
            chatDiagLog("loadMessages abort noChatRowId conversation=\(conversationKey)")
            return
        }
        if messageTranslations.isEmpty,
           let cachedTranslations = await AppCacheStore.shared.loadMessageTranslations(instanceId: instanceId, chatRowId: activeChatRowId, maxAge: 7 * 24 * 3600),
           !cachedTranslations.isEmpty {
            await MainActor.run { messageTranslations = cachedTranslations }
            translationLog("cache loaded translations=\(cachedTranslations.count)")
        }
        if messages.isEmpty,
           let cached = await AppCacheStore.shared.loadMessages(instanceId: instanceId, chatRowId: activeChatRowId, maxAge: nil),
           !cached.isEmpty {
            let normalizedCached = normalizeMessageIdentifiers(cached)
            await MainActor.run { messages = normalizedCached }
            translationLog("cache loaded messages=\(cached.count)")
            chatDiagLog("loadMessages cacheHit conversation=\(conversationKey) cachedMessages=\(cached.count)")
            scheduleMediaPathRefreshIfNeeded(for: normalizedCached)
            await MainActor.run { scheduleInitialMediaPriority(for: normalizedCached) }
        }
        loading = true
        errorMessage = nil
        defer {
            loading = false
            didFinishInitialMessageLoad = true
        }
        do {
            let pageSize = 50
            let list = try await ChatService.shared.getMessages(chatRowId: activeChatRowId, instanceId: instanceId, boxIP: boxIP, page: 1, pageSize: pageSize, sortId: 0)
            let ordered = list.reversed()
            let currentSnapshot = messages
            let snapshotCount = currentSnapshot.count
            let existingMinSort = currentSnapshot.compactMap(\.sort_id).filter { $0 > 0 }.min() ?? 0
            let existingMaxSort = currentSnapshot.compactMap(\.sort_id).filter { $0 > 0 }.max() ?? 0
            let fetchedMinSort = list.compactMap(\.sort_id).filter { $0 > 0 }.min() ?? 0
            let fetchedMaxSort = list.compactMap(\.sort_id).filter { $0 > 0 }.max() ?? 0
            let merged = mergeRemoteMessagesPreservingLocal(Array(ordered), currentLocal: currentSnapshot)
            let mergedMinSort = merged.compactMap(\.sort_id).filter { $0 > 0 }.min() ?? 0
            let mergedMaxSort = merged.compactMap(\.sort_id).filter { $0 > 0 }.max() ?? 0
            historyPageLog("loadLatest conversation=\(conversationKey) pageSize=\(pageSize) fetched=\(list.count) fetchedMinSort=\(fetchedMinSort) fetchedMaxSort=\(fetchedMaxSort) beforeCount=\(snapshotCount) beforeMinSort=\(existingMinSort) beforeMaxSort=\(existingMaxSort) mergedCount=\(merged.count) mergedMinSort=\(mergedMinSort) mergedMaxSort=\(mergedMaxSort)")
            translationLog("remote fetched=\(list.count) merged=\(merged.count)")
            let elapsed = Int(Date().timeIntervalSince(beginAt) * 1000)
            chatDiagLog("loadMessages success conversation=\(conversationKey) fetched=\(list.count) merged=\(merged.count) previous=\(currentSnapshot.count) hasMore=\(list.count >= pageSize) elapsedMs=\(elapsed)")
            await MainActor.run {
                messages = merged
                hasMoreHistory = list.count >= pageSize
                withAnimation(.easeInOut(duration: 0.16)) {
                    showManualHistoryLoadEntry = false
                }
                let liveLocalKeys = Set(merged.compactMap { msg -> String? in
                    guard let kid = msg.key_id, kid.hasPrefix("local_") else { return nil }
                    return kid
                })
                pendingOutgoingPayloadByKeyID = pendingOutgoingPayloadByKeyID.filter { liveLocalKeys.contains($0.key) }
                tempOutgoingImagesByKeyID = tempOutgoingImagesByKeyID.filter { liveLocalKeys.contains($0.key) }
                failedOutgoingReasonByMessageID = failedOutgoingReasonByMessageID.filter { liveLocalKeys.contains($0.key) }
            }
            await AppCacheStore.shared.saveMessages(instanceId: instanceId, chatRowId: activeChatRowId, messages: merged)
            scheduleMediaPathRefreshIfNeeded(for: merged)
            scheduleTranslationWarmup(for: merged)
            await MainActor.run { scheduleInitialMediaPriority(for: merged) }
        } catch {
            let elapsed = Int(Date().timeIntervalSince(beginAt) * 1000)
            chatDiagLog("loadMessages failed conversation=\(conversationKey) chatRowId=\(activeChatRowId) elapsedMs=\(elapsed) error=\(error.localizedDescription)")
            await MainActor.run {
                if messages.isEmpty {
                    errorMessage = "加载消息失败"
                }
            }
        }
    }
    
    private func loadOlderMessages() async {
        let activeChatRowId = await resolveChatRowIdIfNeeded()
        guard activeChatRowId > 0, !isLoadingHistory, hasMoreHistory else { return }
        let oldestSortId = messages.compactMap(\.sort_id).filter { $0 > 0 }.min() ?? 0
        guard oldestSortId > 0 else {
            await MainActor.run { hasMoreHistory = false }
            return
        }
        await MainActor.run { isLoadingHistory = true }
        defer { Task { @MainActor in isLoadingHistory = false } }
        chatDiagLog("loadOlderMessages start conversation=\(conversationKey) chatRowId=\(activeChatRowId) oldestSortId=\(oldestSortId) currentMessages=\(messages.count)")
        do {
            let pageSize = 40
            let list = try await ChatService.shared.getMessages(
                chatRowId: activeChatRowId,
                instanceId: instanceId,
                boxIP: boxIP,
                page: 1,
                pageSize: pageSize,
                sortId: oldestSortId
            )
            let olderOrdered = normalizeMessageIdentifiers(list.reversed())
            let existingKeys = Set(messages.map(\.id))
            let toPrepend = olderOrdered.filter { !existingKeys.contains($0.id) }
            let fetchedSortIDs = list.compactMap(\.sort_id).filter { $0 > 0 }
            let prependSortIDs = toPrepend.compactMap(\.sort_id).filter { $0 > 0 }
            historyPageLog("loadOlder conversation=\(conversationKey) oldestSortId=\(oldestSortId) pageSize=\(pageSize) currentCount=\(messages.count) fetched=\(list.count) fetchedMinSort=\(fetchedSortIDs.min() ?? 0) fetchedMaxSort=\(fetchedSortIDs.max() ?? 0) prepend=\(toPrepend.count) prependMinSort=\(prependSortIDs.min() ?? 0) prependMaxSort=\(prependSortIDs.max() ?? 0)")
            await MainActor.run {
                let anchor = currentAnchorMessageID ?? messages.first?.id
                if !toPrepend.isEmpty {
                    messages = toPrepend + messages
                    prioritizeFirstScreenMedia(in: messages)
                    pendingRestoreAnchorMessageID = anchor
                }
                hasMoreHistory = list.count >= pageSize && !toPrepend.isEmpty
                if !hasMoreHistory || !toPrepend.isEmpty {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showManualHistoryLoadEntry = false
                    }
                }
            }
            let totalAfter = await MainActor.run { messages.count }
            historyPageLog("loadOlderAfter conversation=\(conversationKey) total=\(totalAfter) hasMore=\(hasMoreHistory)")
            chatDiagLog("loadOlderMessages success conversation=\(conversationKey) fetched=\(list.count) prepended=\(toPrepend.count) total=\(totalAfter)")
            await persistMessagesSnapshot()
        } catch {
            historyPageLog("loadOlderFailed conversation=\(conversationKey) oldestSortId=\(oldestSortId) error=\(error.localizedDescription)")
            chatDiagLog("loadOlderMessages failed conversation=\(conversationKey) error=\(error.localizedDescription)")
            await MainActor.run {
                errorMessage = "加载更多失败"
                withAnimation(.easeInOut(duration: 0.16)) {
                    showManualHistoryLoadEntry = true
                }
            }
        }
    }
    
    private func triggerAutoLoadOlderIfNeeded() async {
        guard hasMoreHistory, !isLoadingHistory else { return }
        // 首屏阶段禁止自动拉历史，避免进入会话时误触发“跳到历史消息”。
        // 不再只依赖顶部 sentinel 的 onAppear，而是参考 H5/微信的思路：
        // 当前可见首条消息已经逼近列表顶部时，就触发分页。
        guard didInitialPositioning, hasUserScrolledInSession else { return }
        let visibleAnchor = currentAnchorMessageID
        if let visibleAnchor, visibleAnchor == lastHistoryAutoLoadAnchorID {
            return
        }
        guard let visibleAnchor,
              let anchorIndex = messages.firstIndex(where: { $0.id == visibleAnchor }) else {
            return
        }
        let isNearTop = anchorIndex <= 3
        guard isNearTop else { return }
        // 防抖：避免顶部 sentinel 在布局变动时连续触发多次请求
        let now = Date().timeIntervalSince1970
        if now - lastHistoryAutoLoadAt < 0.8 { return }
        lastHistoryAutoLoadAnchorID = visibleAnchor
        lastHistoryAutoLoadAt = now
        historyPageLog("autoTriggerOlder conversation=\(conversationKey) anchor=\(visibleAnchor) anchorIndex=\(anchorIndex) total=\(messages.count) bottomDistance=\(Int(bottomDistance)) oldestSortId=\(messages.compactMap(\.sort_id).filter { $0 > 0 }.min() ?? 0)")
        await loadOlderMessages()
    }
    
    /// 首屏消息优先：先激活底部可视区附近消息的媒体加载，屏外延后。
    @MainActor
    private func scheduleInitialMediaPriority(for msgs: [Message]) {
        mediaPriorityWarmupTask?.cancel()
        prioritizeFirstScreenMedia(in: msgs)
        mediaPriorityWarmupTask = Task {
            try? await Task.sleep(nanoseconds: 520_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                prioritizedMessageIDs.formUnion(msgs.map(\.id))
            }
        }
    }
    
    @MainActor
    private func prioritizeFirstScreenMedia(in msgs: [Message]) {
        let count = min(28, msgs.count)
        guard count > 0 else {
            prioritizedMessageIDs = []
            return
        }
        let ids = msgs.suffix(count).map(\.id)
        prioritizedMessageIDs = Set(ids)
    }
    
    @MainActor
    private func promoteMessageForMediaLoad(id: String) {
        if prioritizedMessageIDs.contains(id) { return }
        prioritizedMessageIDs.insert(id)
    }
    
    /// 翻译不是首屏关键路径：延后后台补齐，避免进入聊天页首帧卡顿。
    private func scheduleTranslationWarmup(for msgs: [Message]) {
        translationWarmupTask?.cancel()
        translationLog("warmup scheduled messages=\(msgs.count)")
        chatDiagLog("scheduleTranslationWarmup lite conversation=\(conversationKey) messages=\(msgs.count)")
        translationWarmupTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            let targets = await MainActor.run { () -> [String] in
                let visible = Array(visibleMessageIDs.prefix(6))
                if !visible.isEmpty { return visible }
                return Array(msgs.suffix(min(6, msgs.count)).map(\.id))
            }
            guard !targets.isEmpty else { return }
            await MainActor.run {
                enqueueTranslationsForVisibleMessages(targets)
            }
        }
    }

    @MainActor
    private func scheduleVisibleTranslation(for messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        visibleTranslationScheduleTask?.cancel()
        let ordered = messages
            .filter { messageIDs.contains($0.id) }
            .suffix(8)
            .map(\.id)
        guard !ordered.isEmpty else { return }
        chatDiagLog("translation visible schedule conversation=\(conversationKey) ids=\(ordered.count)")
        visibleTranslationScheduleTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                enqueueTranslationsForVisibleMessages(ordered)
            }
        }
    }

    @MainActor
    private func scheduleVisibleThumbPrefetch(for visibleIDs: Set<String>) {
        thumbVisiblePrefetchTask?.cancel()
        guard !visibleIDs.isEmpty else { return }
        let orderedVisible = messages.enumerated().compactMap { idx, msg -> Int? in
            visibleIDs.contains(msg.id) ? idx : nil
        }
        guard !orderedVisible.isEmpty else { return }
        let lower = max(0, (orderedVisible.min() ?? 0) - 2)
        let upper = min(messages.count - 1, (orderedVisible.max() ?? 0) + 2)
        let targets: [(String, Int, String)] = messages[lower...upper].compactMap { msg in
            guard msg.message_type == 1,
                  let path = msg.media_file_path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  let mid = msg.message_id,
                  mid > 0 else { return nil }
            return (msg.id, mid, path)
        }
        guard !targets.isEmpty else { return }
        thumbVisiblePrefetchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            for target in targets {
                if Task.isCancelled { return }
                let key = buildMediaThumbCacheKey(
                    boxIP: boxIPForMedia,
                    index: indexForMedia,
                    filePath: target.2,
                    messageId: target.1,
                    isThumb: true,
                    appType: container.appType,
                    streamUUID: container.uuid ?? instanceId
                )
                if await MainActor.run(body: { MessageThumbDecodedCache.shared.image(for: key) != nil }) {
                    continue
                }
                if let rendered = await MessageThumbRenderedCacheStore.shared.load(key),
                   let decoded = UIImage(data: rendered) {
                    await MainActor.run {
                        MessageThumbDecodedCache.shared.store(decoded, for: key)
                    }
                    continue
                }
                do {
                    let data = try await ChatService.shared.fetchMediaStream(
                        boxIP: boxIPForMedia,
                        index: indexForMedia,
                        filePath: target.2,
                        messageId: target.1,
                        isThumb: true,
                        appType: container.appType,
                        instanceId: container.uuid ?? instanceId
                    )
                    if Task.isCancelled { return }
                    guard let raw = UIImage(data: data) else { continue }
                    let rendered = await MainActor.run { renderThumbnailImage(from: raw, side: 200) ?? raw }
                    if let renderedData = rendered.jpegData(compressionQuality: 0.82) {
                        await MessageThumbRenderedCacheStore.shared.save(key, data: renderedData)
                    }
                    await MainActor.run {
                        MessageThumbDecodedCache.shared.store(rendered, for: key)
                    }
                    chatDiagLog("thumb prefetch stored conversation=\(conversationKey) messageId=\(target.1) key=\(key)")
                } catch {
                    chatDiagLog("thumb prefetch failed conversation=\(conversationKey) messageId=\(target.1) error=\(error.localizedDescription)")
                }
            }
        }
    }

    /// 图片缩略图预热：提前把首屏常见图片解码进内存，避免进入页后逐条解码引发抖动。
    private func scheduleThumbWarmup(for msgs: [Message]) {
        thumbWarmupTask?.cancel()
        thumbWarmupTask = nil
        let targets = msgs.filter { msg in
            msg.message_type == 1 && !(msg.media_file_path ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        chatDiagLog("scheduleThumbWarmup disabled conversation=\(conversationKey) targets=\(targets.count)")
    }

    /// 当前会话命中 WS 新消息事件后，做短时间重试刷新，避免“通知已到但消息列表未刷新”。
    /// - stickToBottom: 用户在底部附近时，收到新消息后保持贴底（微信/WhatsApp 行为）。
    private func scheduleIncomingConversationSync(stickToBottom: Bool) {
        incomingMessageSyncTask?.cancel()
        chatDiagLog("scheduleIncomingConversationSync conversation=\(conversationKey) stickToBottom=\(stickToBottom)")
        incomingMessageSyncTask = Task {
            let delays: [UInt64] = [60_000_000, 260_000_000, 760_000_000]
            for delay in delays {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                await loadMessages()
                if stickToBottom {
                    await MainActor.run {
                        scheduleBottomSnap(animated: false, delay: 0)
                        scheduleBottomSnapReliably(primaryAnimated: false, correctionDelay: 0.05, finalDelay: 0.14)
                    }
                }
            }
        }
    }
    
    private func translationCacheKey(for msg: Message) -> String {
        let key = (msg.key_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        if let mid = msg.message_id, mid > 0 { return "mid_\(mid)" }
        return ""
    }

    @MainActor
    private func enqueueTranslationsForVisibleMessages(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        guard let ip = boxIP, !ip.isEmpty else { return }
        let existing = messageTranslations
        var queued = Set(translationPendingKeys)
        let pendingBefore = translationPendingKeys.count
        let inFlightBefore = translationInFlightKeys.count

        for id in messageIDs {
            guard let msg = messages.first(where: { $0.id == id }) else { continue }
            let key = translationCacheKey(for: msg)
            guard !key.isEmpty else { continue }
            if let cached = existing[key], !cached.isEmpty { continue }
            if translationInFlightKeys.contains(key) || queued.contains(key) { continue }
            let text = (msg.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            translationPendingKeys.append(key)
            queued.insert(key)
        }
        let added = translationPendingKeys.count - pendingBefore
        if added > 0 {
            translationLog("enqueue added=\(added) pending=\(translationPendingKeys.count) inFlight=\(inFlightBefore) visibleInput=\(messageIDs.count)")
            chatDiagLog("translation enqueue conversation=\(conversationKey) added=\(added) pending=\(translationPendingKeys.count) visibleInput=\(messageIDs.count)")
        }
        if !translationPendingKeys.isEmpty && translationBatchTask == nil {
            translationLog("queue start processor pending=\(translationPendingKeys.count)")
            chatDiagLog("translation queue start conversation=\(conversationKey) pending=\(translationPendingKeys.count)")
            translationBatchTask = Task {
                await processTranslationQueue(ip: ip)
            }
        }
    }

    private func processTranslationQueue(ip: String) async {
        defer {
            Task { @MainActor in
                translationBatchTask = nil
                translationLog("queue processor stopped")
            }
        }
        while true {
            if Task.isCancelled { return }
            let batchKeys: [String] = await MainActor.run {
                if translationPendingKeys.isEmpty { return [] }
                let n = min(20, translationPendingKeys.count)
                let keys = Array(translationPendingKeys.prefix(n))
                translationPendingKeys.removeFirst(n)
                for key in keys {
                    translationInFlightKeys.insert(key)
                }
                return keys
            }
            if batchKeys.isEmpty { return }
            translationLog("batch picked keys=\(batchKeys.count)")
            chatDiagLog("translation batch picked conversation=\(conversationKey) keys=\(batchKeys.count)")

            let pairs: [(key: String, text: String)] = await MainActor.run {
                batchKeys.compactMap { key in
                    guard let msg = messages.first(where: { translationCacheKey(for: $0) == key }) else { return nil }
                    let text = (msg.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return (key, text)
                }
            }
            if pairs.isEmpty {
                translationLog("batch skipped: no valid text")
                chatDiagLog("translation batch skipped conversation=\(conversationKey) reason=no_valid_text")
                await MainActor.run {
                    for key in batchKeys { translationInFlightKeys.remove(key) }
                }
                continue
            }

            var translatedByKey: [String: String] = [:]
            do {
                let texts = pairs.map(\.text)
                translationLog("batch request count=\(texts.count)")
                chatDiagLog("translation batch request conversation=\(conversationKey) count=\(texts.count)")
                let translated = try await ChatService.shared.translateBatch(texts: texts, boxIP: ip)
                if translated.count == pairs.count {
                    translationLog("batch success count=\(translated.count)")
                    chatDiagLog("translation batch success conversation=\(conversationKey) count=\(translated.count)")
                    for (idx, item) in pairs.enumerated() {
                        let value = translated[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            translatedByKey[item.key] = value
                        }
                    }
                } else {
                    translationLog("batch size mismatch expected=\(pairs.count) actual=\(translated.count), fallback single")
                    chatDiagLog("translation batch mismatch conversation=\(conversationKey) expected=\(pairs.count) actual=\(translated.count)")
                    for item in pairs {
                        let value = (try? await ChatService.shared.translate(text: item.text, keyId: item.key, boxIP: ip))?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !value.isEmpty {
                            translatedByKey[item.key] = value
                        }
                    }
                }
            } catch {
                translationLog("batch failed: \(error.localizedDescription), fallback single")
                chatDiagLog("translation batch failed conversation=\(conversationKey) error=\(error.localizedDescription)")
                for item in pairs {
                    let value = (try? await ChatService.shared.translate(text: item.text, keyId: item.key, boxIP: ip))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !value.isEmpty {
                        translatedByKey[item.key] = value
                    }
                }
            }

            if !translatedByKey.isEmpty {
                await MainActor.run {
                    for (key, val) in translatedByKey {
                        messageTranslations[key] = val
                    }
                }
                translationLog("batch merged translated=\(translatedByKey.count)")
                chatDiagLog("translation batch merged conversation=\(conversationKey) translated=\(translatedByKey.count)")
                let merged = await MainActor.run { messageTranslations }
                let activeChatRowId = await resolveChatRowIdIfNeeded()
                if activeChatRowId > 0 {
                    await AppCacheStore.shared.saveMessageTranslations(
                        instanceId: instanceId,
                        chatRowId: activeChatRowId,
                        translations: merged
                    )
                    translationLog("cache saved chatRowId=\(activeChatRowId) totalTranslations=\(merged.count)")
                }
            }

            await MainActor.run {
                for key in batchKeys {
                    translationInFlightKeys.remove(key)
                }
            }
            let pendingLeft = await MainActor.run { translationPendingKeys.count }
            translationLog("batch finished pendingLeft=\(pendingLeft)")
        }
    }

    /// 聊天页内补齐出站消息状态（单勾/双勾/已读），避免仅靠发送后一次刷新导致不同步。
    private func syncOutgoingStatusesIfNeeded(forceOnEntry: Bool = false) async {
        let shouldSkip = await MainActor.run {
            loading || !didFinishInitialMessageLoad || outgoingStatusSyncInFlight
        }
        if shouldSkip { return }
        chatDiagLog("syncOutgoingStatuses start conversation=\(conversationKey) forceOnEntry=\(forceOnEntry)")
        await MainActor.run { outgoingStatusSyncInFlight = true }
        defer {
            Task { @MainActor in
                outgoingStatusSyncInFlight = false
            }
        }

        var snapshot = await MainActor.run { messages }
        if snapshot.isEmpty { return }

        var outgoing = snapshot.filter { isOutgoing($0) && !$0.isDeletedMessage }
        if outgoing.isEmpty { return }

        let hasTransientOrLocal = outgoing.contains { msg in
            if let kid = msg.key_id, kid.hasPrefix("local_") { return true }
            switch msg.deliveryState {
            case .localProcessing, .pendingSync, .sending:
                return true
            default:
                return false
            }
        }
        if hasTransientOrLocal {
            let traced = outgoing.filter { shouldTraceMentionMessage($0) }
            if !traced.isEmpty {
                let summary = traced.map { "\($0.key_id ?? ""):\($0.status ?? -1):\(renderedMessageText($0.text_data))" }.joined(separator: " | ")
                mentionStateLog("sync refreshForTransientOrLocal conversation=\(conversationKey) messages=\(summary)")
            }
            chatDiagLog("syncOutgoingStatuses refreshForTransientOrLocal conversation=\(conversationKey)")
            await loadMessages()
            snapshot = await MainActor.run { messages }
            if snapshot.isEmpty { return }
            outgoing = snapshot.filter { isOutgoing($0) && !$0.isDeletedMessage }
            if outgoing.isEmpty { return }
        }

        let candidates = Array(
            outgoing.reversed().filter { msg in
                guard let mid = msg.message_id, mid > 0 else { return false }
                if let kid = msg.key_id, kid.hasPrefix("local_") { return false }
                let status = msg.status ?? -1
                // sending/pending/sent/delivered 都继续追踪，直到 read
                return status == 0 || status == 1 || status == 4 || status == 5 || status == 998
            }.prefix(forceOnEntry ? 16 : 8)
        )
        if candidates.isEmpty { return }
        let tracedCandidates = candidates.filter { shouldTraceMentionMessage($0) }
        if !tracedCandidates.isEmpty {
            let summary = tracedCandidates.map { "\($0.key_id ?? ""):\($0.message_id ?? 0):\($0.status ?? -1):\(renderedMessageText($0.text_data))" }.joined(separator: " | ")
            mentionStateLog("sync candidates conversation=\(conversationKey) messages=\(summary)")
        }
        chatDiagLog("syncOutgoingStatuses candidates conversation=\(conversationKey) count=\(candidates.count)")

        for msg in candidates {
            if Task.isCancelled { return }
            await refreshSingleMessage(msg)
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
    }

    private func restartOutgoingStatusSyncLoop() {
        outgoingStatusSyncTask?.cancel()
        chatDiagLog("restartOutgoingStatusSyncLoop conversation=\(conversationKey)")
        outgoingStatusSyncTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            while !Task.isCancelled {
                await syncOutgoingStatusesIfNeeded()
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if Task.isCancelled { break }
            }
        }
    }
}

private struct ChatBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PreviewGalleryItem: Identifiable, Equatable {
    let id: String
    let path: String
    let messageID: Int?
    let timestamp: Int64?
}

private func buildMediaThumbCacheKey(
    boxIP: String,
    index: Int,
    filePath: String,
    messageId: Int?,
    isThumb: Bool,
    appType: String?,
    streamUUID: String
) -> String {
    let ip = boxIP
    let wsType = appType ?? "person"
    let uuid = streamUUID.trimmingCharacters(in: .whitespacesAndNewlines)
    let msgIdString = messageId.map(String.init) ?? ""
    let thumbFlag = isThumb ? "1" : "0"
    let raw = "\(ip)|\(index)|\(filePath)|\(msgIdString)|\(thumbFlag)|\(wsType)|\(uuid)"
    return raw.replacingOccurrences(of: "[^A-Za-z0-9_\\-\\.]+", with: "_", options: .regularExpression)
}

@MainActor
private final class MessageThumbDecodedCache {
    static let shared = MessageThumbDecodedCache()
    private let store = NSCache<NSString, UIImage>()
    
    private init() {
        store.countLimit = 180
    }
    
    func image(for key: String) -> UIImage? {
        store.object(forKey: key as NSString)
    }
    
    func store(_ image: UIImage, for key: String) {
        store.setObject(image, forKey: key as NSString)
    }
}

private actor MessageThumbRenderedCacheStore {
    static let shared = MessageThumbRenderedCacheStore()

    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private let memoryLimit = 220
    private let diskFolder = "message_thumb_rendered_cache_v1"

    func load(_ key: String, maxAge: TimeInterval = 7 * 24 * 3600) async -> Data? {
        if let data = memory[key] {
            return data
        }
        let fileURL = diskURL(for: key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > maxAge {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        remember(key: key, data: data)
        return data
    }

    func save(_ key: String, data: Data) async {
        remember(key: key, data: data)
        let fileURL = diskURL(for: key)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func remember(key: String, data: Data) {
        memory[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > memoryLimit {
            let first = order.removeFirst()
            memory.removeValue(forKey: first)
        }
    }

    private func diskURL(for key: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent(diskFolder, isDirectory: true)
            .appendingPathComponent(key)
    }
}

@MainActor
private func renderThumbnailImage(from image: UIImage, side: CGFloat = 200) -> UIImage? {
    let sourceSize = image.size
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
    let scale = max(side / sourceSize.width, side / sourceSize.height)
    let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let origin = CGPoint(
        x: (side - scaledSize.width) / 2,
        y: (side - scaledSize.height) / 2
    )
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    return renderer.image { _ in
        image.draw(in: CGRect(origin: origin, size: scaledSize))
    }
}

private actor MessageThumbLoadGate {
    static let shared = MessageThumbLoadGate()
    private let maxActive = 4
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    func acquire() async {
        if active < maxActive {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
            return
        }
        if active > 0 {
            active -= 1
        }
    }
}

// MARK: - 图片消息缩略图（新协议：图片需 msg_id，缩略图需 is_thumb=1）
private struct MessageThumbView: View {
    private static let thumbSide: CGFloat = 200
    let boxIP: String
    let index: Int
    let filePath: String
    let messageID: Int?
    let appType: String?
    let streamUUID: String
    let onOpenOriginal: (UIImage?) -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadToken = 0
    @State private var showLoadingPlaceholder = false
    @State private var lastResolvedThumbKey: String = ""
    @State private var retryCount = 0
    
    private var thumbCacheKey: String {
        buildMediaThumbCacheKey(
            boxIP: boxIP,
            index: index,
            filePath: filePath,
            messageId: messageID,
            isThumb: true,
            appType: appType,
            streamUUID: streamUUID
        )
    }
    
    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbSide, height: Self.thumbSide)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if failed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: Self.thumbSide, height: Self.thumbSide)
                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(showLoadingPlaceholder ? Color.gray.opacity(0.15) : Color.clear)
                    .frame(width: Self.thumbSide, height: Self.thumbSide)
                    .overlay {
                        if showLoadingPlaceholder {
                            ProgressView()
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.16), value: image != nil)
        .onAppear {
            if lastResolvedThumbKey != thumbCacheKey {
                lastResolvedThumbKey = thumbCacheKey
                image = nil
                failed = false
                showLoadingPlaceholder = false
                retryCount = 0
            }
        }
        .onChange(of: thumbCacheKey) { newKey in
            guard lastResolvedThumbKey != newKey else { return }
            lastResolvedThumbKey = newKey
            image = nil
            failed = false
            showLoadingPlaceholder = false
            retryCount = 0
            loadToken &+= 1
            chatDiagLog("thumb key changed filePath=\(filePath) messageId=\(messageID ?? 0) key=\(newKey)")
        }
        .task(id: "\(thumbCacheKey)#\(loadToken)") {
            guard image == nil, !failed else { return }
            let key = thumbCacheKey
            chatDiagLog("thumb task start filePath=\(filePath) messageId=\(messageID ?? 0) key=\(key)")
            if let memImage = await MainActor.run(body: { MessageThumbDecodedCache.shared.image(for: key) }) {
                await MainActor.run {
                    image = memImage
                    failed = false
                    showLoadingPlaceholder = false
                }
                chatDiagLog("thumb task hitMemoryCache filePath=\(filePath) messageId=\(messageID ?? 0) key=\(key)")
                return
            }
            if let rendered = await MessageThumbRenderedCacheStore.shared.load(key),
               let diskImage = UIImage(data: rendered) {
                await MainActor.run {
                    image = diskImage
                    failed = false
                    showLoadingPlaceholder = false
                    MessageThumbDecodedCache.shared.store(diskImage, for: key)
                }
                chatDiagLog("thumb task hitRenderedDiskCache filePath=\(filePath) messageId=\(messageID ?? 0) key=\(key)")
                return
            }
            await MainActor.run { showLoadingPlaceholder = true }
            do {
                await MessageThumbLoadGate.shared.acquire()
                defer { Task { await MessageThumbLoadGate.shared.release() } }
                
                let msgID = messageID.map(String.init) ?? ""
                debugLog("[Media] thumb load start filePath=\(filePath) msg_id=\(msgID) uuid=\(streamUUID)")
                let data = try await ChatService.shared.fetchMediaStream(
                    boxIP: boxIP,
                    index: index,
                    filePath: filePath,
                    messageId: messageID,
                    isThumb: true,
                    appType: appType,
                    instanceId: streamUUID
                )
                if Task.isCancelled { return }
                let decoded = UIImage(data: data)
                let rendered = await MainActor.run { decoded.flatMap { renderThumbnailImage(from: $0, side: Self.thumbSide) } ?? decoded }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.16)) {
                        image = rendered
                    }
                    showLoadingPlaceholder = false
                    if image == nil {
                        debugLog("[Media] thumb decode failed bytes=\(data.count) filePath=\(filePath)")
                        failed = true
                    } else {
                        if let rendered {
                            MessageThumbDecodedCache.shared.store(rendered, for: key)
                        }
                        debugLog("[Media] thumb decode ok bytes=\(data.count) filePath=\(filePath)")
                    }
                }
                if let rendered,
                   let renderedData = rendered.jpegData(compressionQuality: 0.82) {
                    await MessageThumbRenderedCacheStore.shared.save(key, data: renderedData)
                }
                chatDiagLog("thumb task success filePath=\(filePath) messageId=\(messageID ?? 0) bytes=\(data.count) decoded=\(decoded != nil) rendered=\(rendered != nil)")
            } catch {
                debugLog("[Media] thumb load error filePath=\(filePath) err=\(error.localizedDescription)")
                let isCancelled = Task.isCancelled || error is CancellationError || error.localizedDescription == "已取消"
                await MainActor.run {
                    showLoadingPlaceholder = false
                    if isCancelled {
                        failed = false
                    } else {
                        failed = true
                    }
                }
                chatDiagLog("thumb task failed filePath=\(filePath) messageId=\(messageID ?? 0) cancelled=\(isCancelled) error=\(error.localizedDescription)")
                if isCancelled {
                    let currentRetry = await MainActor.run { () -> Int in
                        guard retryCount < 2 else { return retryCount }
                        retryCount += 1
                        return retryCount
                    }
                    if currentRetry <= 2 {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            loadToken &+= 1
                        }
                    }
                }
            }
        }
        .onTapGesture {
            if failed {
                chatDiagLog("thumb task manualRetry filePath=\(filePath) messageId=\(messageID ?? 0)")
                failed = false
                image = nil
                retryCount = 0
                loadToken += 1
            } else {
                onOpenOriginal(image)
            }
        }
    }
}

// MARK: - 原图预览（顶部：返回/时间/编辑；底部：分享/收藏）
private struct OriginalImagePreviewView: View {
    let boxIP: String
    let index: Int
    let items: [PreviewGalleryItem]
    let initialIndex: Int
    let initialImage: UIImage?
    let appType: String?
    let streamUUID: String
    @Binding var isPresented: Bool
    let onForwardImage: (UIImage) -> Void
    let onSendEditedImage: (UIImage) -> Void
    let onDeleteItem: (PreviewGalleryItem) -> Void
    let onReplyItem: (PreviewGalleryItem) -> Void
    let onReactItem: (PreviewGalleryItem, String) -> Void
    
    @State private var currentIndex: Int
    @State private var image: UIImage?
    @State private var loading = true
    @State private var failed = false
    @State private var fallbackFromThumb = false
    @State private var showImageEditor = false
    @State private var toastText: String?
    @State private var cachedOriginalByItemID: [String: UIImage] = [:]
    @State private var cachedThumbByItemID: [String: UIImage] = [:]
    @State private var favoriteTemplateIDByItemID: [String: String] = [:]
    @State private var favoritedItemIDs: Set<String> = []
    @State private var consumedInitialImage = false
    @State private var showShareOptions = false
    @State private var showEmojiInline = false
    @State private var showDeleteConfirm = false
    @State private var showSystemShareSheet = false
    @State private var chromeVisible = true
    
    init(
        boxIP: String,
        index: Int,
        items: [PreviewGalleryItem],
        initialIndex: Int,
        initialImage: UIImage?,
        appType: String?,
        streamUUID: String,
        isPresented: Binding<Bool>,
        onForwardImage: @escaping (UIImage) -> Void,
        onSendEditedImage: @escaping (UIImage) -> Void,
        onDeleteItem: @escaping (PreviewGalleryItem) -> Void,
        onReplyItem: @escaping (PreviewGalleryItem) -> Void,
        onReactItem: @escaping (PreviewGalleryItem, String) -> Void
    ) {
        self.boxIP = boxIP
        self.index = index
        self.items = items
        self.initialIndex = initialIndex
        self.initialImage = initialImage
        self.appType = appType
        self.streamUUID = streamUUID
        self._isPresented = isPresented
        self.onForwardImage = onForwardImage
        self.onSendEditedImage = onSendEditedImage
        self.onDeleteItem = onDeleteItem
        self.onReplyItem = onReplyItem
        self.onReactItem = onReactItem
        let safeInitial = min(max(initialIndex, 0), max(0, items.count - 1))
        _currentIndex = State(initialValue: safeInitial)
    }
    
    private var currentItem: PreviewGalleryItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }
    private var isCurrentItemFavorited: Bool {
        guard let item = currentItem else { return false }
        return favoritedItemIDs.contains(item.id)
    }
    private var hasPrev: Bool { currentIndex > 0 }
    private var hasNext: Bool { currentIndex < items.count - 1 }
    private var hasPager: Bool { items.count > 1 }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            imagePagerLayer
            
            VStack(spacing: 0) {
                if chromeVisible {
                    topBar
                        .transition(.opacity)
                }
                Spacer()
                if chromeVisible {
                    bottomBar
                        .transition(.opacity)
                }
            }
            
            if chromeVisible {
                HStack {
                    floatingBubbleButton(systemName: "face.smiling") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showEmojiInline.toggle()
                        }
                    }
                    Spacer()
                    floatingBubbleButton(systemName: "arrowshape.turn.up.left", title: "回复") {
                        guard let item = currentItem else { return }
                        onReplyItem(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, actionBubbleBottomPadding)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            
            if chromeVisible && showEmojiInline {
                HStack(spacing: 10) {
                    ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏"], id: \.self) { emoji in
                        Button(action: {
                            guard let item = currentItem else { return }
                            onReactItem(item, emoji)
                            withAnimation(.easeInOut(duration: 0.14)) {
                                showEmojiInline = false
                            }
                            showToast("已发送表情")
                        }) {
                            Text(emoji)
                                .font(.system(size: 22))
                                .frame(width: 38, height: 38)
                                .background(chromePanelColor)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, actionBubbleBottomPadding + 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            
            if let toastText {
                VStack {
                    Spacer()
                    Text(toastText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(.bottom, 86)
                }
                .transition(.opacity)
            }
        }
        .task(id: currentIndex) {
            await loadOriginalImage()
            await preloadNeighborThumbs()
            await MainActor.run { syncFavoriteStateForCurrentItem() }
        }
        .sheet(isPresented: $showImageEditor) {
            if let image {
                ImageEditSheet(
                    originalImage: image,
                    onCancel: { showImageEditor = false },
                    onApply: { edited in
                        showImageEditor = false
                        onSendEditedImage(edited)
                    }
                )
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: $showSystemShareSheet) {
            if let image {
                ActivityShareSheet(activityItems: [image])
            } else {
                EmptyView()
            }
        }
        .confirmationDialog("更多操作", isPresented: $showShareOptions, titleVisibility: .visible) {
            Button("保存到相册") { saveCurrentImageToPhotos() }
            Button("系统分享") { showSystemShareSheet = true }
            Button("转发") {
                guard let image else { return }
                onForwardImage(image)
            }
            Button("复制") {
                guard let image else { return }
                UIPasteboard.general.image = image
                showToast("已复制图片")
            }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("确定删除这张图片消息？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let item = currentItem else { return }
                onDeleteItem(item)
            }
            Button("取消", role: .cancel) { }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
    }
    
    @ViewBuilder
    private var imagePagerLayer: some View {
        if hasPager {
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, _ in
                    pagerPage(index: idx)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        } else {
            singleImageLayer
        }
        
        if loading {
            ProgressView()
                .tint(.white)
                .padding(10)
                .background(Color.black.opacity(0.38))
                .clipShape(Circle())
        }
    }
    
    @ViewBuilder
    private var singleImageLayer: some View {
        if let img = image {
            ZoomableImageView(image: img) {
                toggleChrome()
            }
                .ignoresSafeArea()
        } else if !loading {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
                Text("原图加载失败")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
        }
    }
    
    @ViewBuilder
    private func pagerPage(index: Int) -> some View {
        if items.indices.contains(index), let img = previewImage(at: index) {
            ZStack {
                Color.black
                ZoomableImageView(image: img) {
                    toggleChrome()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipped()
        } else {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func previewImage(at index: Int) -> UIImage? {
        guard items.indices.contains(index) else { return nil }
        let id = items[index].id
        if index == currentIndex {
            return image ?? cachedOriginalByItemID[id] ?? cachedThumbByItemID[id]
        }
        if let original = cachedOriginalByItemID[id] { return original }
        return cachedThumbByItemID[id]
    }
    
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }
    
    private func preloadNeighborThumbs() async {
        guard hasPager else { return }
        if hasPrev, items.indices.contains(currentIndex - 1) {
            await loadPreviewThumbIfNeeded(for: items[currentIndex - 1])
        }
        if hasNext, items.indices.contains(currentIndex + 1) {
            await loadPreviewThumbIfNeeded(for: items[currentIndex + 1])
        }
    }
    
    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: { isPresented = false }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(detailTimeText())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if items.count > 1 {
                    Text("\(currentIndex + 1)/\(items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: { if image != nil { showImageEditor = true } }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(image == nil ? Color.white.opacity(0.45) : .white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .disabled(image == nil)
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(Color(red: 0.14, green: 0.14, blue: 0.14).opacity(0.92))
    }
    
    private var chromePanelColor: Color {
        Color(red: 0.14, green: 0.14, blue: 0.14).opacity(0.92)
    }
    
    private var bottomBar: some View {
        return VStack(spacing: 0) {
            if items.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            Button(action: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    currentIndex = idx
                                }
                            }) {
                                ZStack {
                                    if let thumb = cachedThumbByItemID[item.id] ?? (idx == currentIndex ? image : nil) {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 52, height: 52)
                                            .clipped()
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.14))
                                            .overlay(
                                                Image(systemName: "photo")
                                                    .font(.system(size: 14, weight: .medium))
                                                    .foregroundColor(Color.white.opacity(0.7))
                                            )
                                    }
                                }
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(idx == currentIndex ? Color(red: 0.18, green: 0.82, blue: 0.48) : Color.white.opacity(0.24), lineWidth: idx == currentIndex ? 2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .task {
                                await loadPreviewThumbIfNeeded(for: item)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 68)
                .background(chromePanelColor)
            }
            HStack(spacing: 10) {
                Button(action: {
                    showShareOptions = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    guard let image else { return }
                    onForwardImage(image)
                }) {
                    Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(image == nil ? Color.white.opacity(0.45) : .white)
                    .frame(maxWidth: .infinity)
                }
                .disabled(image == nil)
                .buttonStyle(.plain)
                
                Button(action: { toggleFavoriteCurrentImage() }) {
                    Image(systemName: isCurrentItemFavorited ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(image == nil ? Color.white.opacity(0.45) : .white)
                    .frame(maxWidth: .infinity)
                }
                .disabled(image == nil)
                .buttonStyle(.plain)
                
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.red.opacity(0.92))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(chromePanelColor)
        }
    }
    
    private func detailTimeText() -> String {
        guard let ts = currentItem?.timestamp, ts > 0 else { return "图片" }
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
    
    private func addToImageTemplate() {
        guard let image else { return }
        let title = "聊天图片\(formattedTemplateTime())"
        guard let item = QuickImageTemplate.make(title: title, image: image) else {
            showToast("收藏失败")
            return
        }
        QuickTemplateStore.saveImageTemplate(item)
        showToast("已收藏到图片模板")
    }
    
    private var actionBubbleBottomPadding: CGFloat {
        items.count > 1 ? 136 : 82
    }
    
    private func floatingBubbleButton(systemName: String, title: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let title, !title.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: systemName)
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(chromePanelColor)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(chromePanelColor)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private func formattedTemplateTime() -> String {
        let date: Date
        if let ts = currentItem?.timestamp, ts > 0 {
            date = Date(timeIntervalSince1970: Double(ts) / 1000)
        } else {
            date = Date()
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: date)
    }
    
    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.14)) {
            toastText = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.14)) {
                toastText = nil
            }
        }
    }
    
    private func loadOriginalImage() async {
        guard let item = currentItem else {
            await MainActor.run {
                image = nil
                loading = false
                failed = true
                fallbackFromThumb = false
            }
            return
        }
        let itemID = item.id
        if let cached = cachedOriginalByItemID[itemID] {
            await MainActor.run {
                image = cached
                loading = false
                failed = false
                fallbackFromThumb = false
                syncFavoriteStateForCurrentItem()
            }
            return
        }
        await MainActor.run {
            loading = true
            failed = false
            fallbackFromThumb = false
        }
        if let initialImage, !consumedInitialImage, currentIndex == initialIndex {
            await MainActor.run {
                image = initialImage
                loading = true
                failed = false
                fallbackFromThumb = true
                consumedInitialImage = true
                syncFavoriteStateForCurrentItem()
            }
        } else {
            // 没有可直接复用的首帧时，再走缩略图请求兜底，避免首开白屏。
            await loadThumbFirstIfPossible(item)
        }
        guard let messageID = item.messageID, messageID > 0 else {
            await MainActor.run {
                loading = false
                failed = (image == nil)
            }
            return
        }
        do {
            let data = try await ChatService.shared.fetchMediaStream(
                boxIP: boxIP,
                index: index,
                filePath: item.path,
                messageId: messageID,
                isThumb: false,
                appType: appType,
                instanceId: streamUUID
            )
            let decoded = await decodeImage(data)
            await MainActor.run {
                guard currentItem?.id == itemID else { return }
                image = decoded
                loading = false
                failed = (image == nil)
                if let decoded {
                    cachedOriginalByItemID[itemID] = decoded
                    fallbackFromThumb = false
                }
                syncFavoriteStateForCurrentItem()
            }
            if image == nil {
                await MainActor.run {
                    guard currentItem?.id == itemID else { return }
                    loading = false
                    failed = (self.image == nil)
                }
            }
        } catch {
            await MainActor.run {
                guard currentItem?.id == itemID else { return }
                loading = false
                failed = (image == nil)
            }
        }
    }
    
    private func loadThumbFirstIfPossible(_ item: PreviewGalleryItem) async {
        do {
            let data = try await ChatService.shared.fetchMediaStream(
                boxIP: boxIP,
                index: index,
                filePath: item.path,
                messageId: item.messageID,
                isThumb: true,
                appType: appType,
                instanceId: streamUUID
            )
            let decoded = await decodeImage(data)
            await MainActor.run {
                guard currentItem?.id == item.id else { return }
                image = decoded
                loading = true
                fallbackFromThumb = (image != nil)
                syncFavoriteStateForCurrentItem()
            }
        } catch {
            await MainActor.run {
                guard currentItem?.id == item.id else { return }
                loading = true
                fallbackFromThumb = false
            }
        }
    }
    
    private func decodeImage(_ data: Data) async -> UIImage? {
        return await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }
    
    private func saveCurrentImageToPhotos() {
        guard let image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        showToast("已保存到相册")
    }
    
    private func toggleFavoriteCurrentImage() {
        guard let item = currentItem, let image else { return }
        if let templateID = favoriteTemplateIDByItemID[item.id] {
            QuickTemplateStore.deleteImageTemplate(id: templateID)
            favoriteTemplateIDByItemID.removeValue(forKey: item.id)
            favoritedItemIDs.remove(item.id)
            showToast("已取消收藏")
            return
        }
        let title = "聊天图片\(formattedTemplateTime())"
        guard let template = QuickImageTemplate.make(title: title, image: image) else {
            showToast("收藏失败")
            return
        }
        QuickTemplateStore.saveImageTemplate(template)
        favoriteTemplateIDByItemID[item.id] = template.id
        favoritedItemIDs.insert(item.id)
        showToast("已收藏")
    }
    
    private func syncFavoriteStateForCurrentItem() {
        guard let item = currentItem, let image else { return }
        guard let base64 = image.jpegData(compressionQuality: 0.86)?.base64EncodedString() else { return }
        let templates = QuickTemplateStore.loadImageTemplates()
        if let matched = templates.first(where: { $0.imageBase64 == base64 }) {
            favoriteTemplateIDByItemID[item.id] = matched.id
            favoritedItemIDs.insert(item.id)
        } else {
            favoriteTemplateIDByItemID.removeValue(forKey: item.id)
            favoritedItemIDs.remove(item.id)
        }
    }
    
    private func loadPreviewThumbIfNeeded(for item: PreviewGalleryItem) async {
        if cachedThumbByItemID[item.id] != nil { return }
        do {
            let data = try await ChatService.shared.fetchMediaStream(
                boxIP: boxIP,
                index: index,
                filePath: item.path,
                messageId: item.messageID,
                isThumb: true,
                appType: appType,
                instanceId: streamUUID
            )
            let decoded = await decodeImage(data)
            guard let decoded else { return }
            await MainActor.run {
                if cachedThumbByItemID[item.id] == nil {
                    cachedThumbByItemID[item.id] = decoded
                }
            }
        } catch {
            return
        }
    }
}

private struct ZoomableImageView: View {
    let image: UIImage
    let onSingleTap: () -> Void
    
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            let safeWidth = (geo.size.width.isFinite && !geo.size.width.isNaN) ? max(1, geo.size.width) : 1
            let safeHeight = (geo.size.height.isFinite && !geo.size.height.isNaN) ? max(1, geo.size.height) : 1
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: safeWidth, height: safeHeight, alignment: .center)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSingleTap)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let next = max(1, min(4, lastScale * value))
                            scale = next
                            if next <= 1.001 {
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                        .onEnded { _ in
                            if scale <= 1.001 {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    scale = 1
                                    lastScale = 1
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            } else {
                                lastScale = scale
                                clampOffset(in: geo.size)
                                lastOffset = offset
                            }
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                            clampOffset(in: geo.size)
                        }
                        .onEnded { _ in
                            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.12)) {
                                clampOffset(in: geo.size)
                                lastOffset = offset
                            }
                        },
                    including: scale > 1.001 ? .all : .none
                )
        }
    }
    
    private func clampOffset(in size: CGSize) {
        let maxX = max(0, (size.width * (scale - 1)) / 2)
        let maxY = max(0, (size.height * (scale - 1)) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ForwardConversationTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let jid: String
    let instanceID: String
    let containerName: String
    let boxIP: String
    let index: Int
    let appType: String?
    let lastTimestamp: Int64
}

private struct ForwardConversationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let containers: [Instance]
    let excludedConversationID: String
    let onForward: ([ForwardConversationTarget]) async -> (success: Int, failed: Int)
    
    @State private var loading = false
    @State private var sending = false
    @State private var searchText = ""
    @State private var targets: [ForwardConversationTarget] = []
    @State private var selectedIDs: Set<String> = []
    @State private var statusText: String?
    
    private let defaultVisibleCount = 50
    
    private var visibleTargets: [ForwardConversationTarget] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return Array(targets.prefix(defaultVisibleCount)) }
        return targets.filter { item in
            item.title.lowercased().contains(q)
            || item.subtitle.lowercased().contains(q)
            || item.jid.lowercased().contains(q)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Color(white: 0.55))
                    TextField("搜索会话", text: $searchText)
                        .font(.system(size: 14))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(white: 0.65))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.42))
                        .padding(.top, 8)
                }
                
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targets.count > defaultVisibleCount {
                    Text("默认展示最近 \(defaultVisibleCount) 条会话，搜索可匹配全量会话")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.46))
                        .padding(.top, 8)
                }
                
                if visibleTargets.isEmpty {
                    if loading {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else {
                        Spacer()
                        Text("暂无可转发会话")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.55))
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleTargets) { item in
                                HStack(spacing: 10) {
                                    Button(action: { Task { await sendSingle(item) } }) {
                                        HStack(spacing: 10) {
                                            Circle()
                                                .fill(Color(white: 0.88))
                                                .frame(width: 34, height: 34)
                                                .overlay(
                                                    Text(String(item.title.prefix(1)))
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundColor(Color(white: 0.35))
                                                )
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.title)
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundColor(Color(white: 0.15))
                                                    .lineLimit(1)
                                                Text(item.subtitle)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(Color(white: 0.5))
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(sending)
                                    
                                    Button(action: { toggleSelection(item.id) }) {
                                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20, weight: .regular))
                                            .foregroundColor(selectedIDs.contains(item.id) ? Color(red: 0.13, green: 0.56, blue: 0.95) : Color(white: 0.72))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(sending)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
                
                HStack(spacing: 10) {
                    Text("已选 \(selectedIDs.count) 项")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.45))
                    Spacer()
                    Button(action: { Task { await sendSelected() } }) {
                        Text(sending ? "转发中..." : "发送")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(selectedIDs.isEmpty || sending ? Color(white: 0.72) : Color(red: 0.12, green: 0.56, blue: 0.95))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIDs.isEmpty || sending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
            }
            .navigationTitle("选择转发会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
            }
            .task { await loadTargets() }
        }
    }
    
    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
    
    private func sendSingle(_ target: ForwardConversationTarget) async {
        guard !sending else { return }
        sending = true
        let result = await onForward([target])
        sending = false
        if result.failed == 0 {
            dismiss()
        } else {
            statusText = "转发失败，请稍后重试"
        }
    }
    
    private func sendSelected() async {
        guard !sending else { return }
        let picked = targets.filter { selectedIDs.contains($0.id) }
        guard !picked.isEmpty else { return }
        sending = true
        let result = await onForward(picked)
        sending = false
        if result.failed == 0 {
            dismiss()
        } else {
            statusText = "转发完成：成功\(result.success)个，失败\(result.failed)个"
        }
    }
    
    private func loadTargets() async {
        loading = true
        statusText = nil
        let running = containers.filter {
            ($0.state ?? "").lowercased() == "running"
            && !($0.instanceIdForApi).isEmpty
            && !($0.boxIP ?? "").isEmpty
        }
        var unique: [String: ForwardConversationTarget] = [:]
        
        // 先回填缓存，让首屏能快速展示最近会话。
        for container in running {
            let cached = await AppCacheStore.shared.loadChats(instanceId: container.instanceIdForApi, maxAge: nil) ?? []
            for item in buildForwardTargets(chats: cached, container: container) {
                unique[item.id] = item
            }
        }
        targets = sortedForwardTargets(unique)
        
        // 再并发拉取全量会话：用于搜索命中更完整，但默认列表仍只显示前 50 条。
        var remoteAll: [ForwardConversationTarget] = []
        await withTaskGroup(of: [ForwardConversationTarget].self) { group in
            for container in running {
                group.addTask {
                    let instanceId = container.instanceIdForApi
                    let boxIP = container.boxIP ?? ""
                    guard !instanceId.isEmpty, !boxIP.isEmpty else { return [] }
                    do {
                        let chats = try await ChatService.shared.getChats(instanceId: instanceId, boxIP: boxIP)
                        await AppCacheStore.shared.saveChats(instanceId: instanceId, chats: chats)
                        return chats.compactMap { chat -> ForwardConversationTarget? in
                            guard let jid = chat.jid?.trimmingCharacters(in: .whitespacesAndNewlines), !jid.isEmpty else { return nil }
                            let id = "\(instanceId)_\(jid)"
                            if id == excludedConversationID { return nil }
                            let title = forwardTitle(chat)
                            let subtitle = "\(formatInstanceName(container.scrmRemark ?? container.name ?? "")) · \(maskedPhoneOrJid(chat.phone ?? jid))"
                            let ts = chat.last_message?.timestamp ?? 0
                            return ForwardConversationTarget(
                                id: id,
                                title: title,
                                subtitle: subtitle,
                                jid: jid,
                                instanceID: instanceId,
                                containerName: container.name ?? "",
                                boxIP: boxIP,
                                index: container.index ?? 1,
                                appType: container.appType,
                                lastTimestamp: ts
                            )
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await chunk in group {
                remoteAll.append(contentsOf: chunk)
            }
        }
        for item in remoteAll {
            unique[item.id] = item
        }
        targets = sortedForwardTargets(unique)
        loading = false
        statusText = nil
    }
    
    private func buildForwardTargets(chats: [Chat], container: Instance) -> [ForwardConversationTarget] {
        let instanceId = container.instanceIdForApi
        let boxIP = container.boxIP ?? ""
        return chats.compactMap { chat -> ForwardConversationTarget? in
            guard let jid = chat.jid?.trimmingCharacters(in: .whitespacesAndNewlines), !jid.isEmpty else { return nil }
            let id = "\(instanceId)_\(jid)"
            if id == excludedConversationID { return nil }
            let title = forwardTitle(chat)
            let subtitle = "\(formatInstanceName(container.scrmRemark ?? container.name ?? "")) · \(maskedPhoneOrJid(chat.phone ?? jid))"
            let ts = chat.last_message?.timestamp ?? 0
            return ForwardConversationTarget(
                id: id,
                title: title,
                subtitle: subtitle,
                jid: jid,
                instanceID: instanceId,
                containerName: container.name ?? "",
                boxIP: boxIP,
                index: container.index ?? 1,
                appType: container.appType,
                lastTimestamp: ts
            )
        }
    }
    
    private func sortedForwardTargets(_ unique: [String: ForwardConversationTarget]) -> [ForwardConversationTarget] {
        unique.values.sorted {
            if $0.lastTimestamp == $1.lastTimestamp {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.lastTimestamp > $1.lastTimestamp
        }
    }
    
    private func forwardTitle(_ chat: Chat) -> String {
        let remark = (chat.remark_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !remark.isEmpty { return remark }
        let name = (chat.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return maskedPhoneOrJid(name) }
        let phone = (chat.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !phone.isEmpty { return maskedPhoneOrJid(phone) }
        let jid = (chat.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !jid.isEmpty { return maskedPhoneOrJid(jid) }
        return "未命名会话"
    }
    
    private func maskedPhoneOrJid(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let base: String = {
            if let at = raw.firstIndex(of: "@") {
                return String(raw[..<at])
            }
            return raw
        }()
        let digits = base.filter(\.isNumber)
        guard digits.count >= 7 else { return base }
        let prefix = String(digits.prefix(4))
        let suffix = String(digits.suffix(4))
        return "\(prefix)****\(suffix)"
    }
}

// MARK: - 相册选择器（PHPickerViewController，iOS 14+，无需相册全权限）
struct PhotoPickerView: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerView
        
        init(_ parent: PhotoPickerView) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard let result = results.first else { return }
            let provider = result.itemProvider
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    DispatchQueue.main.async {
                        self?.parent.selectedImage = object as? UIImage
                    }
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.parent.selectedImage = image
                    }
                }
            }
        }
    }
}

private struct RecentMediaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSend: ([UIImage]) async -> Void
    
    private let imageManager = PHCachingImageManager()
    // 预览网格固定规格：每行 4 张，统一尺寸，避免长宽图导致布局抖动
    private let gridColumnCount = 4
    private let gridSpacing: CGFloat = 4
    private let gridHorizontalPadding: CGFloat = 8
    
    @State private var assets: [PHAsset] = []
    @State private var thumbByID: [String: UIImage] = [:]
    @State private var importedImageByID: [String: UIImage] = [:]
    @State private var editedImageByID: [String: UIImage] = [:]
    @State private var fullImageByID: [String: UIImage] = [:]
    @State private var selectedOrder: [String] = []
    @State private var authDenied = false
    @State private var showSystemAlbumPicker = false
    @State private var showCameraPicker = false
    @State private var capturedImage: UIImage?
    @State private var editingAssetID: String?
    @State private var editingImage: UIImage?
    @State private var showImageEditor = false
    @State private var sending = false
    
    private var canEdit: Bool { selectedOrder.count == 1 && !sending }
    private var canSend: Bool { !selectedOrder.isEmpty && !sending }
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.82))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 8)
            
            HStack(spacing: 10) {
                Button(action: onTapCamera) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                        Text("照片")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                
                Button(action: { showSystemAlbumPicker = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("相册")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            
            if authDenied {
                VStack(spacing: 8) {
                    Text("请在系统设置中授权相册访问")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button("我知道了") { dismiss() }
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let side = gridItemSide(for: geo.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(side), spacing: gridSpacing), count: gridColumnCount),
                            spacing: gridSpacing
                        ) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                recentAssetCell(asset, side: side)
                            }
                        }
                        .padding(.horizontal, gridHorizontalPadding)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                }
                .background(Color.black.opacity(0.02))
            }
            
            HStack(spacing: 10) {
                Button(action: onTapEditSelected) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("编辑")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(canEdit ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(white: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                
                Button(action: onTapSendSelected) {
                    HStack(spacing: 6) {
                        if sending {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(sending ? "发送中..." : "发送\(selectedOrder.isEmpty ? "" : "(\(selectedOrder.count))")")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(red: 0.13, green: 0.59, blue: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Color.white)
        }
        .applyRecentMediaSheetPresentationStyle()
        .onAppear {
            Task { await requestPermissionAndLoadRecentAssets() }
        }
        .sheet(isPresented: $showSystemAlbumPicker) {
            SystemAlbumMultiPickerView(
                isPresented: $showSystemAlbumPicker,
                onPicked: { images in
                    mergeImportedImages(images)
                }
            )
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraImagePickerView(
                isPresented: $showCameraPicker,
                selectedImage: $capturedImage
            )
        }
        .onChange(of: capturedImage) { image in
            guard let image else { return }
            mergeImportedImages([image])
            capturedImage = nil
        }
        .sheet(isPresented: $showImageEditor) {
            if let image = editingImage {
                ImageEditSheet(
                    originalImage: image,
                    onCancel: { showImageEditor = false },
                    onApply: { edited in
                        if let id = editingAssetID {
                            editedImageByID[id] = edited
                            fullImageByID[id] = edited
                            thumbByID[id] = edited.normalizedForEditing().squareThumbnail(side: 220)
                        }
                        showImageEditor = false
                    }
                )
            } else {
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func recentAssetCell(_ asset: PHAsset, side: CGFloat) -> some View {
        let id = asset.localIdentifier
        let selectedIndex = selectedOrder.firstIndex(of: id).map { $0 + 1 }
        let cellImage = previewImageForGrid(id: id)
        
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color(white: 0.92))
            if let thumb = cellImage {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().scaleEffect(0.75)
            }
            
            if let selectedIndex {
                Text("\(selectedIndex)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(red: 0.12, green: 0.56, blue: 0.98))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 2, x: 0, y: 1)
                    .padding(.bottom, 6)
                    .padding(.trailing, 10)
            }
            
            if editedImageByID[id] != nil {
                Text("已编辑")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.leading, 6)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay {
            if selectedIndex != nil {
                RoundedRectangle(cornerRadius: 0)
                    .stroke(Color(red: 0.13, green: 0.59, blue: 0.95), lineWidth: 3)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection(for: id)
        }
        .task {
            await loadThumbnailIfNeeded(for: asset)
        }
    }
    
    private func gridItemSide(for availableWidth: CGFloat) -> CGFloat {
        let safeWidth = safeDimension(availableWidth, fallback: 360, min: 120, max: 2000)
        let totalSpacing = CGFloat(gridColumnCount - 1) * gridSpacing + gridHorizontalPadding * 2
        let raw = (safeWidth - totalSpacing) / CGFloat(gridColumnCount)
        // 限定单元格尺寸区间，保证不同设备下视觉稳定
        let side = max(72, min(110, floor(raw)))
        return safeDimension(side, fallback: 88, min: 72, max: 110)
    }
    
    private func previewImageForGrid(id: String) -> UIImage? {
        if let edited = editedImageByID[id] { return edited.squareThumbnail(side: 220) }
        if let imported = importedImageByID[id] { return imported.squareThumbnail(side: 220) }
        return thumbByID[id]
    }
    
    private func onTapCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCameraPicker = UIImagePickerController.isSourceTypeAvailable(.camera)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCameraPicker = UIImagePickerController.isSourceTypeAvailable(.camera)
                    }
                }
            }
        default:
            break
        }
    }
    
    private func onTapEditSelected() {
        guard selectedOrder.count == 1, let id = selectedOrder.first else { return }
        Task {
            let image = await resolveImage(for: id, forEditing: true)
            await MainActor.run {
                editingAssetID = id
                if let image {
                    editingImage = image
                    showImageEditor = true
                } else {
                    showImageEditor = false
                }
            }
        }
    }
    
    private func onTapSendSelected() {
        guard !selectedOrder.isEmpty, !sending else { return }
        sending = true
        Task {
            var images: [UIImage] = []
            for id in selectedOrder {
                if let image = await resolveImage(for: id, forEditing: false) {
                    images.append(image)
                }
            }
            await onSend(images)
            await MainActor.run {
                sending = false
                dismiss()
            }
        }
    }
    
    private func toggleSelection(for id: String) {
        if let idx = selectedOrder.firstIndex(of: id) {
            selectedOrder.remove(at: idx)
        } else {
            selectedOrder.append(id)
        }
    }
    
    private func mergeImportedImages(_ images: [UIImage]) {
        for raw in images {
            let image = raw.normalizedForEditing()
            let id = "imported_\(UUID().uuidString)"
            importedImageByID[id] = image
            fullImageByID[id] = image
            selectedOrder.append(id)
        }
    }
    
    private func requestPermissionAndLoadRecentAssets() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = current
        }
        await MainActor.run {
            authDenied = !(status == .authorized || status == .limited)
        }
        guard status == .authorized || status == .limited else { return }
        
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 180
        let fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        
        var list: [PHAsset] = []
        list.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            list.append(asset)
        }
        await MainActor.run {
            assets = list
        }
    }
    
    private func loadThumbnailIfNeeded(for asset: PHAsset) async {
        let id = asset.localIdentifier
        if thumbByID[id] != nil { return }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale
        let target = CGSize(width: 110 * scale, height: 110 * scale)
        imageManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                if thumbByID[id] == nil {
                    thumbByID[id] = image
                }
            }
        }
    }
    
    private func resolveImage(for id: String, forEditing: Bool) async -> UIImage? {
        if let edited = editedImageByID[id] { return edited }
        if let imported = importedImageByID[id] { return imported }
        if let full = fullImageByID[id] { return full }
        guard let asset = assets.first(where: { $0.localIdentifier == id }) else { return nil }
        let image = await requestImage(
            for: asset,
            targetMaxPixel: 0, // 0 代表原图尺寸（PHImageManagerMaximumSize）
            allowDegradedWhenAvailable: false
        )
        if let image {
            await MainActor.run {
                fullImageByID[id] = image
            }
        }
        return image
    }
    
    private func requestImage(
        for asset: PHAsset,
        targetMaxPixel: Int,
        allowDegradedWhenAvailable: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = allowDegradedWhenAvailable ? .opportunistic : .highQualityFormat
            options.resizeMode = allowDegradedWhenAvailable ? .fast : .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            let target: CGSize
            if targetMaxPixel <= 0 {
                target = PHImageManagerMaximumSize
            } else {
                let maxSide = max(1, targetMaxPixel)
                let srcW = max(1, asset.pixelWidth)
                let srcH = max(1, asset.pixelHeight)
                let scale = min(1.0, Double(maxSide) / Double(max(srcW, srcH)))
                target = CGSize(
                    width: max(1, CGFloat(Double(srcW) * scale)),
                    height: max(1, CGFloat(Double(srcH) * scale))
                )
            }
            var hasResumed = false
            let resumeLock = NSLock()
            imageManager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // PHImageManager 在部分场景会回调多次（如先回 degraded 再回高清），
                // continuation 只能 resume 一次，否则会触发运行时 abort。
                resumeLock.lock()
                if hasResumed {
                    resumeLock.unlock()
                    return
                }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    hasResumed = true
                    resumeLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let error = info?[PHImageErrorKey] as? NSError {
                    debugLog("[MediaPicker] requestImage error: \(error.localizedDescription)")
                    hasResumed = true
                    resumeLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded && !allowDegradedWhenAvailable {
                    // 等高清图回调，避免提前用低清图恢复 continuation。
                    resumeLock.unlock()
                    return
                }
                hasResumed = true
                resumeLock.unlock()
                continuation.resume(returning: image?.normalizedForEditing())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                resumeLock.lock()
                if hasResumed {
                    resumeLock.unlock()
                    return
                }
                hasResumed = true
                resumeLock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }
}

private struct SystemAlbumMultiPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: ([UIImage]) -> Void
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SystemAlbumMultiPickerView
        
        init(_ parent: SystemAlbumMultiPickerView) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard !results.isEmpty else { return }
            let group = DispatchGroup()
            var images: [UIImage] = []
            let lock = NSLock()
            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let image = object as? UIImage {
                            lock.lock()
                            images.append(image)
                            lock.unlock()
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        if let data, let image = UIImage(data: data) {
                            lock.lock()
                            images.append(image)
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                self.parent.onPicked(images)
            }
        }
    }
}

private struct CameraImagePickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedImage: UIImage?
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePickerView
        
        init(_ parent: CameraImagePickerView) {
            self.parent = parent
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImage = image
            }
            parent.isPresented = false
        }
    }
}

private extension View {
    @ViewBuilder
    func applyRecentMediaSheetPresentationStyle() -> some View {
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        } else {
            self
        }
    }
}

private struct ImageComposeSheet: View {
    let image: UIImage
    let isSending: Bool
    let onCancel: () -> Void
    let onEdit: () -> Void
    let onSend: () -> Void
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.96).ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                }
                .frame(maxHeight: .infinity)
                
                HStack(spacing: 12) {
                    Button(action: onEdit) {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                            Text("编辑")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onSend) {
                        HStack(spacing: 6) {
                            if isSending {
                                ProgressView().scaleEffect(0.85)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text(isSending ? "发送中..." : "发送")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color(red: 0.13, green: 0.59, blue: 0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .background(Color.black.opacity(0.94))
            }
            .navigationTitle("发送图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
    }
}

private struct ImageEditSheet: View {
    let originalImage: UIImage
    let onCancel: () -> Void
    let onApply: (UIImage) -> Void
    
    private enum MarkupTool: String {
        case brush = "画笔"
        case rect = "框选"
        case arrow = "箭头"
        case text = "文字"
    }
    
    private struct StrokePath: Identifiable {
        let id = UUID()
        var points: [CGPoint] // 归一化坐标
        var colorHex: String
    }
    
    private struct RectMark: Identifiable {
        let id = UUID()
        var start: CGPoint // 归一化坐标
        var end: CGPoint   // 归一化坐标
        var colorHex: String
    }
    
    private struct TextMark: Identifiable {
        let id = UUID()
        var text: String
        var anchor: CGPoint // 归一化坐标
        var colorHex: String
    }

    private struct ArrowMark: Identifiable {
        let id = UUID()
        var start: CGPoint // 归一化坐标
        var end: CGPoint   // 归一化坐标
        var colorHex: String
    }
    
    @State private var workingImage: UIImage
    @State private var activeTool: MarkupTool? = nil
    @State private var strokePaths: [StrokePath] = []
    @State private var rectMarks: [RectMark] = []
    @State private var arrowMarks: [ArrowMark] = []
    @State private var textMarks: [TextMark] = []
    @State private var liveStrokePoints: [CGPoint] = []
    @State private var liveRect: RectMark?
    @State private var liveArrow: ArrowMark?
    @State private var canvasImageRect: CGRect = .zero
    @State private var pendingTextAnchor: CGPoint?
    @State private var pendingTextValue = ""
    @State private var showTextInputAlert = false
    @State private var showDiscardConfirm = false
    @State private var activeMarkupColorHex: String = "#FF3B30"
    @State private var imageTransformDirty = false
    @State private var showColorSelector = false
    @State private var customMarkupColor: Color = Color(red: 1, green: 0.231, blue: 0.188)
    
    private let markupPaletteHexes: [String] = [
        "#FF3B30", "#FF9500", "#FFD60A", "#34C759", "#00C853", "#30B0C7",
        "#0A84FF", "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93", "#FFFFFF", "#000000"
    ]
    
    init(originalImage: UIImage, onCancel: @escaping () -> Void, onApply: @escaping (UIImage) -> Void) {
        self.originalImage = originalImage.normalizedForEditing()
        self.onCancel = onCancel
        self.onApply = onApply
        _workingImage = State(initialValue: originalImage.normalizedForEditing())
    }

    private var hasMarkupEdits: Bool {
        !strokePaths.isEmpty || !rectMarks.isEmpty || !arrowMarks.isEmpty || !textMarks.isEmpty
    }

    private var hasAnyEdits: Bool {
        hasMarkupEdits || imageTransformDirty
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.92).ignoresSafeArea()
                        let contentRect = CGRect(x: 16, y: 16, width: max(1, geo.size.width - 32), height: max(1, geo.size.height - 32))
                        let imageRect = aspectFitRect(imageSize: workingImage.size, in: contentRect)
                        let safeImageWidth = (imageRect.width.isFinite && !imageRect.width.isNaN) ? max(1, imageRect.width) : 1
                        let safeImageHeight = (imageRect.height.isFinite && !imageRect.height.isNaN) ? max(1, imageRect.height) : 1
                        
                        Image(uiImage: workingImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: safeImageWidth, height: safeImageHeight)
                            .position(x: imageRect.midX, y: imageRect.midY)
                        
                        overlayMarks(in: imageRect)
                    }
                    .contentShape(Rectangle())
                    .gesture(markupGesture())
                    .onAppear {
                        let contentRect = CGRect(x: 16, y: 16, width: max(1, geo.size.width - 32), height: max(1, geo.size.height - 32))
                        canvasImageRect = aspectFitRect(imageSize: workingImage.size, in: contentRect)
                    }
                    .onChange(of: geo.size) { _ in
                        let contentRect = CGRect(x: 16, y: 16, width: max(1, geo.size.width - 32), height: max(1, geo.size.height - 32))
                        canvasImageRect = aspectFitRect(imageSize: workingImage.size, in: contentRect)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    imageEditSideButton(
                        title: "撤销",
                        systemName: "arrow.uturn.backward",
                        active: hasAnyEdits,
                        action: handleUndoTap
                    )
                    Spacer()
                    imageEditSideButton(
                        title: "重置",
                        systemName: "arrow.counterclockwise",
                        active: hasAnyEdits,
                        action: resetAllEdits
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)

                if activeTool != nil, showColorSelector {
                    colorChooserPopupPanel()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        toolButton(.brush, systemName: "pencil.tip")
                        toolButton(.rect, systemName: "rectangle.dashed")
                        toolButton(.arrow, systemName: "arrow.up.right")
                        toolButton(.text, systemName: "textformat")
                        if activeTool != nil {
                            colorDropdownControl()
                        }
                        editButton("旋转90°", systemName: "rotate.right") {
                            activeTool = nil
                            showColorSelector = false
                            workingImage = workingImage.rotatedClockwise90()
                            imageTransformDirty = true
                            clearMarkup()
                        }
                        editButton("镜像", systemName: "flip.horizontal") {
                            activeTool = nil
                            showColorSelector = false
                            workingImage = workingImage.mirroredHorizontally()
                            imageTransformDirty = true
                            clearMarkup()
                        }
                        editButton("1:1", systemName: "square") {
                            activeTool = nil
                            showColorSelector = false
                            workingImage = workingImage.centerCropped(aspectRatio: 1)
                            imageTransformDirty = true
                            clearMarkup()
                        }
                        editButton("4:3", systemName: "rectangle") {
                            activeTool = nil
                            showColorSelector = false
                            workingImage = workingImage.centerCropped(aspectRatio: 4.0 / 3.0)
                            imageTransformDirty = true
                            clearMarkup()
                        }
                        editButton("16:9", systemName: "rectangle.wide") {
                            activeTool = nil
                            showColorSelector = false
                            workingImage = workingImage.centerCropped(aspectRatio: 16.0 / 9.0)
                            imageTransformDirty = true
                            clearMarkup()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(Color.white)
            }
            .navigationTitle("编辑图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if hasAnyEdits {
                            showDiscardConfirm = true
                        } else {
                            onCancel()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { onApply(renderMergedImage()) }
                }
            }
            .alert("输入文字", isPresented: $showTextInputAlert) {
                TextField("请输入文字", text: $pendingTextValue)
                Button("取消", role: .cancel) {
                    pendingTextValue = ""
                    pendingTextAnchor = nil
                }
                Button("确定") {
                    let text = pendingTextValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let anchor = pendingTextAnchor, !text.isEmpty {
                        textMarks.append(TextMark(text: text, anchor: anchor, colorHex: activeMarkupColorHex))
                    }
                    pendingTextValue = ""
                    pendingTextAnchor = nil
                }
            }
            .confirmationDialog("放弃本次编辑？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) {
                    onCancel()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("你有未保存的修改，确认要退出吗？")
            }
        }
    }
    
    @ViewBuilder
    private func overlayMarks(in imageRect: CGRect) -> some View {
        ZStack {
            ForEach(strokePaths) { path in
                Path { p in
                    guard let first = path.points.first else { return }
                    p.move(to: denormalize(first, in: imageRect))
                    for point in path.points.dropFirst() {
                        p.addLine(to: denormalize(point, in: imageRect))
                    }
                }
                .stroke(colorFromHex(path.colorHex), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            }
            if !liveStrokePoints.isEmpty {
                Path { p in
                    guard let first = liveStrokePoints.first else { return }
                    p.move(to: denormalize(first, in: imageRect))
                    for point in liveStrokePoints.dropFirst() {
                        p.addLine(to: denormalize(point, in: imageRect))
                    }
                }
                .stroke(colorFromHex(activeMarkupColorHex), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            }
            ForEach(rectMarks) { rect in
                Rectangle()
                    .path(in: denormalizeRect(start: rect.start, end: rect.end, in: imageRect))
                    .stroke(colorFromHex(rect.colorHex), lineWidth: 2.4)
            }
            if let liveRect {
                Rectangle()
                    .path(in: denormalizeRect(start: liveRect.start, end: liveRect.end, in: imageRect))
                    .stroke(colorFromHex(activeMarkupColorHex), style: StrokeStyle(lineWidth: 2.4, dash: [6, 4]))
            }
            ForEach(arrowMarks) { arrow in
                Path { p in
                    addArrowPath(
                        to: &p,
                        start: denormalize(arrow.start, in: imageRect),
                        end: denormalize(arrow.end, in: imageRect),
                        headLength: 16,
                        headAngle: .pi / 8
                    )
                }
                .stroke(colorFromHex(arrow.colorHex), style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round))
            }
            if let liveArrow {
                Path { p in
                    addArrowPath(
                        to: &p,
                        start: denormalize(liveArrow.start, in: imageRect),
                        end: denormalize(liveArrow.end, in: imageRect),
                        headLength: 16,
                        headAngle: .pi / 8
                    )
                }
                .stroke(colorFromHex(activeMarkupColorHex), style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round))
            }
            ForEach(textMarks) { mark in
                Text(mark.text)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(colorFromHex(mark.colorHex))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(5)
                    .position(denormalize(mark.anchor, in: imageRect))
            }
        }
    }
    
    private func markupGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let normalized = normalize(value.location, in: canvasImageRect) else { return }
                switch activeTool {
                case .brush?:
                    liveStrokePoints.append(normalized)
                case .rect?:
                    if liveRect == nil {
                        liveRect = RectMark(start: normalized, end: normalized, colorHex: activeMarkupColorHex)
                    } else {
                        liveRect?.end = normalized
                        liveRect?.colorHex = activeMarkupColorHex
                    }
                case .arrow?:
                    if liveArrow == nil {
                        liveArrow = ArrowMark(start: normalized, end: normalized, colorHex: activeMarkupColorHex)
                    } else {
                        liveArrow?.end = normalized
                        liveArrow?.colorHex = activeMarkupColorHex
                    }
                case .text?:
                    break
                default:
                    break
                }
            }
            .onEnded { value in
                let movement = hypot(value.translation.width, value.translation.height)
                switch activeTool {
                case .brush?:
                    if !liveStrokePoints.isEmpty {
                        strokePaths.append(StrokePath(points: liveStrokePoints, colorHex: activeMarkupColorHex))
                    }
                    liveStrokePoints = []
                case .rect?:
                    if let rect = liveRect {
                        rectMarks.append(rect)
                    }
                    liveRect = nil
                case .arrow?:
                    if let arrow = liveArrow {
                        arrowMarks.append(arrow)
                    }
                    liveArrow = nil
                case .text?:
                    guard movement < 8 else { return }
                    if let normalized = normalize(value.location, in: canvasImageRect) {
                        pendingTextAnchor = normalized
                        pendingTextValue = ""
                        showTextInputAlert = true
                    }
                default:
                    break
                }
            }
    }
    
    private func toolButton(_ tool: MarkupTool, systemName: String) -> some View {
        Button(action: {
            activeTool = tool
            if activeTool == nil {
                showColorSelector = false
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                Text(tool.rawValue)
                    .font(.system(size: 11))
            }
            .foregroundColor(activeTool == tool ? Color(red: 0.08, green: 0.55, blue: 0.95) : Color(white: 0.2))
            .frame(width: 68, height: 46)
            .background(activeTool == tool ? Color(red: 0.08, green: 0.55, blue: 0.95).opacity(0.12) : Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    
    private func colorDropdownControl() -> some View {
        Button(action: {
            customMarkupColor = colorFromHex(activeMarkupColorHex)
            withAnimation(.easeInOut(duration: 0.18)) {
                showColorSelector.toggle()
            }
        }) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(colorFromHex(activeMarkupColorHex))
                    .frame(width: 24, height: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white.opacity(0.9), lineWidth: 0.8)
                    )
                Image(systemName: showColorSelector ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Color(white: 0.2))
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func colorChooserPopupPanel() -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(markupPaletteHexes, id: \.self) { hex in
                        colorSwatchButton(hex)
                    }
                }
                .padding(.horizontal, 2)
            }
            ColorPicker("", selection: $customMarkupColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24, height: 24)
                .onChange(of: customMarkupColor) { newValue in
                    activeMarkupColorHex = hexFromColor(newValue)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 7, x: 0, y: 3)
    }
    
    private func colorSwatchButton(_ hex: String) -> some View {
        Button(action: {
            activeMarkupColorHex = hex
            customMarkupColor = colorFromHex(hex)
        }) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(colorFromHex(hex))
                .frame(width: 28, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(activeMarkupColorHex == hex ? Color.blue : Color.black.opacity(0.15), lineWidth: activeMarkupColorHex == hex ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func imageEditSideButton(
        title: String,
        systemName: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(active ? .white : Color(white: 0.62))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(active ? Color(red: 0.11, green: 0.58, blue: 0.96) : Color(white: 0.9))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!active)
    }
    
    private func editButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(Color(white: 0.2))
            .frame(width: 64, height: 46)
            .background(Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    
    private func clearMarkup() {
        strokePaths = []
        rectMarks = []
        arrowMarks = []
        textMarks = []
        liveStrokePoints = []
        liveRect = nil
        liveArrow = nil
    }
    
    private func undoLastMarkup() {
        if !textMarks.isEmpty {
            _ = textMarks.removeLast()
            return
        }
        if !arrowMarks.isEmpty {
            _ = arrowMarks.removeLast()
            return
        }
        if !rectMarks.isEmpty {
            _ = rectMarks.removeLast()
            return
        }
        if !strokePaths.isEmpty {
            _ = strokePaths.removeLast()
        }
    }

    private func resetAllEdits() {
        activeTool = nil
        showColorSelector = false
        workingImage = originalImage
        imageTransformDirty = false
        clearMarkup()
    }

    private func handleUndoTap() {
        if hasMarkupEdits {
            undoLastMarkup()
            return
        }
        if imageTransformDirty {
            resetAllEdits()
        }
    }
    
    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        let y = min(1, max(0, (point.y - rect.minY) / rect.height))
        return CGPoint(x: x, y: y)
    }
    
    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
    
    private func denormalizeRect(start: CGPoint, end: CGPoint, in rect: CGRect) -> CGRect {
        let s = denormalize(start, in: rect)
        let e = denormalize(end, in: rect)
        return CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(s.x - e.x), height: abs(s.y - e.y))
    }

    private func addArrowPath(
        to path: inout Path,
        start: CGPoint,
        end: CGPoint,
        headLength: CGFloat,
        headAngle: CGFloat
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.01 else { return }
        let ux = dx / length
        let uy = dy / length
        let adaptedHead = min(max(headLength, 10), max(12, length * 0.35))
        let angle = atan2(dy, dx)
        let shaftEnd = CGPoint(x: end.x - ux * (adaptedHead * 0.35), y: end.y - uy * (adaptedHead * 0.35))
        let left = CGPoint(
            x: end.x - adaptedHead * cos(angle - headAngle),
            y: end.y - adaptedHead * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - adaptedHead * cos(angle + headAngle),
            y: end.y - adaptedHead * sin(angle + headAngle)
        )
        path.move(to: start)
        path.addLine(to: shaftEnd)
        path.move(to: end)
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)
    }
    
    private func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let imageRatio = imageSize.width / imageSize.height
        let boundsRatio = bounds.width / bounds.height
        if imageRatio > boundsRatio {
            let w = bounds.width
            let h = w / imageRatio
            return CGRect(x: bounds.minX, y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
        } else {
            let h = bounds.height
            let w = h * imageRatio
            return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY, width: w, height: h)
        }
    }
    
    private func renderMergedImage() -> UIImage {
        let base = workingImage.normalizedForEditing()
        let size = base.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))
            
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            
            cg.setLineWidth(3.2 * max(1, min(size.width, size.height) / 1080))
            for stroke in strokePaths {
                cg.setStrokeColor(uiColorFromHex(stroke.colorHex).cgColor)
                guard let first = stroke.points.first else { continue }
                cg.beginPath()
                cg.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for p in stroke.points.dropFirst() {
                    cg.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
                cg.strokePath()
            }
            
            cg.setLineWidth(2.4 * max(1, min(size.width, size.height) / 1080))
            for rect in rectMarks {
                cg.setStrokeColor(uiColorFromHex(rect.colorHex).cgColor)
                let x1 = rect.start.x * size.width
                let y1 = rect.start.y * size.height
                let x2 = rect.end.x * size.width
                let y2 = rect.end.y * size.height
                let rr = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x1 - x2), height: abs(y1 - y2))
                cg.stroke(rr)
            }

            cg.setLineWidth(3.0 * max(1, min(size.width, size.height) / 1080))
            for arrow in arrowMarks {
                let start = CGPoint(x: arrow.start.x * size.width, y: arrow.start.y * size.height)
                let end = CGPoint(x: arrow.end.x * size.width, y: arrow.end.y * size.height)
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = max(1, hypot(dx, dy))
                let ux = dx / length
                let uy = dy / length
                let headLength = min(28, max(12, length * 0.2))
                let headAngle = CGFloat.pi / 8
                let angle = atan2(dy, dx)
                let left = CGPoint(
                    x: end.x - headLength * cos(angle - headAngle),
                    y: end.y - headLength * sin(angle - headAngle)
                )
                let right = CGPoint(
                    x: end.x - headLength * cos(angle + headAngle),
                    y: end.y - headLength * sin(angle + headAngle)
                )

                cg.setStrokeColor(uiColorFromHex(arrow.colorHex).cgColor)
                cg.beginPath()
                cg.move(to: start)
                cg.addLine(to: CGPoint(x: end.x - ux * (headLength * 0.35), y: end.y - uy * (headLength * 0.35)))
                cg.strokePath()

                cg.beginPath()
                cg.move(to: end)
                cg.addLine(to: left)
                cg.move(to: end)
                cg.addLine(to: right)
                cg.strokePath()
            }
            
            for mark in textMarks {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(16, min(size.width, size.height) * 0.038), weight: .semibold),
                    .foregroundColor: uiColorFromHex(mark.colorHex),
                    .backgroundColor: UIColor.black.withAlphaComponent(0.45)
                ]
                let point = CGPoint(x: mark.anchor.x * size.width, y: mark.anchor.y * size.height)
                let text = NSString(string: mark.text)
                let textSize = text.size(withAttributes: attrs)
                let origin = CGPoint(x: max(0, min(size.width - textSize.width, point.x - textSize.width / 2)),
                                     y: max(0, min(size.height - textSize.height, point.y - textSize.height / 2)))
                text.draw(at: origin, withAttributes: attrs)
            }
        }
    }
    
    private func colorFromHex(_ hex: String) -> Color {
        Color(uiColor: uiColorFromHex(hex))
    }

    private func hexFromColor(_ color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        }
        var white: CGFloat = 0
        if ui.getWhite(&white, alpha: &a) {
            let v = Int(round(white * 255))
            return String(format: "#%02X%02X%02X", v, v, v)
        }
        return activeMarkupColorHex
    }
    
    private func uiColorFromHex(_ hex: String) -> UIColor {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard s.count == 6, let v = Int(s, radix: 16) else { return .red }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

private extension UIImage {
    func normalizedForEditing() -> UIImage {
        if imageOrientation == .up { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
    
    func rotatedClockwise90() -> UIImage {
        let base = normalizedForEditing()
        let newSize = CGSize(width: base.size.height, height: base.size.width)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cg.rotate(by: .pi / 2)
            cg.translateBy(x: -base.size.width / 2, y: -base.size.height / 2)
            base.draw(in: CGRect(origin: .zero, size: base.size))
        }
    }
    
    func mirroredHorizontally() -> UIImage {
        let base = normalizedForEditing()
        let renderer = UIGraphicsImageRenderer(size: base.size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: base.size.width, y: 0)
            cg.scaleBy(x: -1, y: 1)
            base.draw(in: CGRect(origin: .zero, size: base.size))
        }
    }
    
    func centerCropped(aspectRatio ratio: CGFloat) -> UIImage {
        let base = normalizedForEditing()
        guard ratio > 0 else { return base }
        let width = base.size.width
        let height = base.size.height
        let current = width / height
        
        var cropRect: CGRect
        if current > ratio {
            let targetWidth = height * ratio
            cropRect = CGRect(x: (width - targetWidth) / 2, y: 0, width: targetWidth, height: height)
        } else {
            let targetHeight = width / ratio
            cropRect = CGRect(x: 0, y: (height - targetHeight) / 2, width: width, height: targetHeight)
        }
        guard let cg = base.cgImage?.cropping(to: cropRect.integral) else { return base }
        return UIImage(cgImage: cg, scale: base.scale, orientation: .up)
    }
    
    func squareThumbnail(side: CGFloat) -> UIImage {
        let base = normalizedForEditing()
        let edge = max(1, side)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        return renderer.image { _ in
            let src = base.size
            let scale = max(edge / max(1, src.width), edge / max(1, src.height))
            let w = src.width * scale
            let h = src.height * scale
            let rect = CGRect(x: (edge - w) / 2, y: (edge - h) / 2, width: w, height: h)
            base.draw(in: rect)
        }
    }
}
    private func safeDimension(_ value: CGFloat, fallback: CGFloat, min minValue: CGFloat = 0, max maxValue: CGFloat = 10_000) -> CGFloat {
        guard value.isFinite, !value.isNaN else { return fallback }
        return Swift.max(minValue, Swift.min(maxValue, value))
    }
