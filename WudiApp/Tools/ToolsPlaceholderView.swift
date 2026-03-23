//
//  ToolsPlaceholderView.swift
//  WudiApp
//
//  工具页：仅保留翻译、AI对话、话术模板三项
//

import SwiftUI
import UIKit

#if DEBUG
private let aiPanelLogEnabled = false
@inline(__always) private func aiPanelLog(_ message: @autoclosure () -> String) {
    guard aiPanelLogEnabled else { return }
    print("[AIChatPanel] \(message())")
}
#else
@inline(__always) private func aiPanelLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - 工具项（按当前需求仅保留 3 个）
private let toolsList: [(key: String, title: String, icon: String)] = [
    ("translation", "精准翻译", "character.book.closed"),
    ("chat", "AI对话", "bubble.left.and.bubble.right"),
    ("template", "话术模板", "doc.text"),
]

struct ToolsPlaceholderView: View {
    @ObservedObject var appState: AppState
    var storageScopeKey: String = "global"
    var onTranslationInputFocusChanged: ((Bool) -> Void)? = nil
    var onFillTranslationToChatInput: ((String) -> Void)? = nil
    var onTranslationActionTriggered: (() -> Void)? = nil
    var showTranslationButtonGuide: Bool = false
    var showTranslationEnterGuide: Bool = false
    @State private var selectedKey: String = "translation"
    
    private var currentTitle: String {
        toolsList.first(where: { $0.key == selectedKey })?.title ?? "工具"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("工具")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(white: 0.12))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color.white)
            
            HStack(spacing: 8) {
                ForEach(toolsList, id: \.key) { tool in
                    Button(action: { selectedKey = tool.key }) {
                        HStack(spacing: 6) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 14, height: 14)
                            Text(tool.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                        }
                        .foregroundColor(selectedKey == tool.key ? .white : Color(white: 0.25))
                        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                        .background(selectedKey == tool.key ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color.white)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(white: 0.9), lineWidth: selectedKey == tool.key ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.96, green: 0.96, blue: 0.96))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(currentTitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(white: 0.28))
                        Spacer()
                    }
                    toolsBodyContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.white)
                .cornerRadius(12)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.96, green: 0.96, blue: 0.96))
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
    }
    
    @ViewBuilder
    private var toolsBodyContent: some View {
        switch selectedKey {
        case "translation":
            TranslationPanel(
                appState: appState,
                storageScopeKey: storageScopeKey,
                onInputFocusChanged: onTranslationInputFocusChanged,
                onFillTranslationToChatInput: onFillTranslationToChatInput,
                onTranslationActionTriggered: onTranslationActionTriggered,
                showTranslateGuide: showTranslationButtonGuide,
                showEnterGuide: showTranslationEnterGuide
            )
        case "chat":
            AIChatPanel(appState: appState, storageScopeKey: storageScopeKey)
        case "template":
            ScriptTemplatePanel()
        default:
            TranslationPanel(
                appState: appState,
                storageScopeKey: storageScopeKey,
                onInputFocusChanged: onTranslationInputFocusChanged,
                onFillTranslationToChatInput: onFillTranslationToChatInput,
                onTranslationActionTriggered: onTranslationActionTriggered,
                showTranslateGuide: showTranslationButtonGuide,
                showEnterGuide: showTranslationEnterGuide
            )
        }
    }
}

// MARK: - 精准翻译（与 H5 Translation.vue 一致：需带 box-ip 头，否则服务端返回 500）
private struct TranslationPanel: View {
    @ObservedObject var appState: AppState
    let storageScopeKey: String
    var onInputFocusChanged: ((Bool) -> Void)? = nil
    var onFillTranslationToChatInput: ((String) -> Void)? = nil
    var onTranslationActionTriggered: (() -> Void)? = nil
    var showTranslateGuide: Bool = false
    var showEnterGuide: Bool = false
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var comparisonText = ""
    @State private var targetLanguage = "en"
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var didRestoreState = false
    @FocusState private var inputEditorFocused: Bool
    
    private var translationStateStorageKey: String {
        let uid = appState.userID.map(String.init) ?? "guest"
        return "translation_panel_state_v1_\(uid)_\(storageScopeKey)"
    }
    
    /// 与 H5 一致：翻译接口需要 box-ip 头，优先当前容器 → 运行中实例 → 任意实例
    private var preferredBoxIP: String? {
        appState.currentContainer?.boxIP
            ?? appState.accountInstances.first(where: { ($0.state ?? "").lowercased() == "running" })?.boxIP
            ?? appState.accountInstances.first?.boxIP
    }
    
    private let languages: [(value: String, label: String)] = [
        ("", "自动检测"),
        ("zh", "中文"),
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("de", "德语"),
        ("fr", "法语"),
        ("nl", "荷兰语"),
        ("fi", "芬兰语"),
        ("de-AT", "奥地利语"),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请输入要翻译的文本...")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $inputText)
                .font(.body)
                .focused($inputEditorFocused)
                .frame(minHeight: 100)
                .padding(8)
                .background(Color(white: 0.98))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.9), lineWidth: 1))
            
            HStack(spacing: 12) {
                Picker("目标语言", selection: $targetLanguage) {
                    ForEach(languages, id: \.value) { lang in
                        Text(lang.label).tag(lang.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
                Button(action: doTranslate) {
                    if loading {
                        ProgressView().scaleEffect(0.9).tint(.white)
                    } else {
                        Text("翻译")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(red: 0.09, green: 0.47, blue: 1.0))
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(loading || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .overlay(alignment: .topTrailing) {
                    if showTranslateGuide {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("点这里翻译")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color(white: 0.86), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .offset(x: -8, y: -32)
                    }
                }
            }
            .padding(10)
            .background(Color(white: 0.97))
            .cornerRadius(8)
            
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            
            outputSection(label: "翻译结果", text: $outputText)
            outputSection(label: "对照翻译", text: $comparisonText)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if inputEditorFocused {
                inputEditorFocused = false
            }
        }
        .onChange(of: inputEditorFocused) { focused in
            onInputFocusChanged?(focused)
        }
        .onAppear {
            guard !didRestoreState else { return }
            didRestoreState = true
            restoreState()
        }
        .onChange(of: inputText) { _ in persistState() }
        .onChange(of: outputText) { _ in persistState() }
        .onChange(of: comparisonText) { _ in persistState() }
        .onChange(of: targetLanguage) { _ in persistState() }
    }
    
    private func outputSection(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline).foregroundColor(Color(white: 0.4))
                Spacer()
                Button(action: {
                    let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    onFillTranslationToChatInput?(value)
                }) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.caption)
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .overlay(alignment: .topTrailing) {
                    if showEnterGuide && label == "翻译结果" {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("点回车回填")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color(white: 0.86), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .offset(x: -2, y: -30)
                    }
                }
                Button(action: { UIPasteboard.general.string = text.wrappedValue }) {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .disabled(text.wrappedValue.isEmpty)
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 80)
                .padding(8)
                .background(Color(white: 0.97))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.9), lineWidth: 1))
                .disabled(true)
        }
    }
    
    private func doTranslate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !targetLanguage.isEmpty else { return }
        guard let boxIP = preferredBoxIP, !boxIP.isEmpty else {
            errorMessage = "请先在账号页选择云机并加载实例后再使用翻译"
            return
        }
        onTranslationActionTriggered?()
        loading = true
        errorMessage = nil
        outputText = ""
        comparisonText = ""
        Task {
            defer { Task { @MainActor in loading = false } }
            do {
                let result = try await ChatService.shared.translateTextWithTargetLang(text: text, targetLang: targetLanguage, boxIP: boxIP)
                await MainActor.run {
                    outputText = result
                    if targetLanguage != "zh" {
                        Task { await doComparison(firstResult: result, boxIP: boxIP) }
                    }
                }
            } catch {
                await MainActor.run { errorMessage = "翻译失败：\(error.localizedDescription)" }
            }
        }
    }
    
    private func doComparison(firstResult: String, boxIP: String) async {
        do {
            let comp = try await ChatService.shared.translateTextWithTargetLang(text: firstResult, targetLang: "zh", boxIP: boxIP)
            await MainActor.run {
                comparisonText = comp
                persistState()
            }
        } catch {
            await MainActor.run {
                comparisonText = ""
                persistState()
            }
        }
    }
    
    private struct PersistedState: Codable {
        var inputText: String
        var outputText: String
        var comparisonText: String
        var targetLanguage: String
    }
    
    private func persistState() {
        let payload = PersistedState(
            inputText: inputText,
            outputText: outputText,
            comparisonText: comparisonText,
            targetLanguage: targetLanguage
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: translationStateStorageKey)
        }
    }
    
    private func restoreState() {
        guard let data = UserDefaults.standard.data(forKey: translationStateStorageKey),
              let saved = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        inputText = saved.inputText
        outputText = saved.outputText
        comparisonText = saved.comparisonText
        if !saved.targetLanguage.isEmpty {
            targetLanguage = saved.targetLanguage
        }
    }
}

// MARK: - AI助手（与 H5 AIChat.vue 一致：消息列表 + 输入框 + 发送 + 清空历史）
private struct AIChatPanel: View {
    @ObservedObject var appState: AppState
    let storageScopeKey: String
    @State private var inputText = ""
    @State private var messages: [AIChatMessage] = []
    @State private var sending = false
    @State private var streamTask: Task<Void, Never>?
    @State private var pickedImage: UIImage?
    @State private var showImagePicker = false
    @FocusState private var inputFieldFocused: Bool
    
    private var storageKey: String {
        let uid = appState.userID.map(String.init) ?? "guest"
        return "ai_chat_messages_v2_\(uid)_\(storageScopeKey)"
    }
    
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { msg in
                                HStack(alignment: .top, spacing: 8) {
                                    if msg.isUser { Spacer(minLength: 40) }
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let dataURL = msg.imageDataURL, let image = imageFromDataURL(dataURL) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(maxWidth: 220)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }
                                        if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(msg.content)
                                                .font(.subheadline)
                                        }
                                        if !msg.isUser && !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            HStack {
                                                Spacer()
                                                Button(action: { copyAIMessage(msg.content) }) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "doc.on.doc")
                                                            .font(.system(size: 10, weight: .semibold))
                                                        Text("复制")
                                                            .font(.system(size: 11, weight: .medium))
                                                    }
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.white.opacity(0.45))
                                                    .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .background(msg.isUser ? Color(red: 0.13, green: 0.59, blue: 0.95) : Color(white: 0.94))
                                    .foregroundColor(msg.isUser ? .white : .primary)
                                    .cornerRadius(12)
                                    if !msg.isUser { Spacer(minLength: 40) }
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if inputFieldFocused {
                            inputFieldFocused = false
                        }
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                
                VStack(spacing: 8) {
                    HStack {
                        Button(action: { messages.removeAll() }) {
                            Text("清空历史记录")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .disabled(messages.isEmpty)
                        if sending {
                            Button(action: stopGenerating) {
                                Text("中断生成")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        Spacer()
                    }
                    if let preview = pickedImage {
                        HStack(spacing: 8) {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("已选择图片")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("移除") { pickedImage = nil }
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 2)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        Button(action: { showImagePicker = true }) {
                            Image(systemName: "photo")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
                                .frame(width: 34, height: 34)
                                .background(Color(red: 0.13, green: 0.59, blue: 0.95).opacity(0.14))
                                .clipShape(Circle())
                        }
                        TextField("输入消息...", text: $inputText)
                            .textFieldStyle(.plain)
                            .focused($inputFieldFocused)
                            .padding(10)
                            .background(Color(white: 0.95))
                            .cornerRadius(20)
                            .lineLimit(6)
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(canSend ? Color(red: 0.13, green: 0.59, blue: 0.95) : .gray)
                        }
                        .disabled(!canSend || sending)
                    }
                }
                .padding(12)
                .background(Color.white)
            }
            .frame(maxWidth: .infinity, minHeight: max(geo.size.height, 420), alignment: .bottom)
        }
        .background(Color(white: 0.97))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .frame(minHeight: 420)
        .contentShape(Rectangle())
        .onTapGesture {
            if inputFieldFocused {
                inputFieldFocused = false
            }
        }
        .sheet(isPresented: $showImagePicker) {
            BasicImagePicker { image in
                pickedImage = image
            }
        }
        .onAppear { loadMessagesFromStorage() }
        .onChange(of: messages) { _ in saveMessagesToStorage() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
    }
    
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pickedImage != nil
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let imageDataURL = pickedImage.flatMap(dataURLFromImage(_:))
        aiPanelLog("send tapped textLen=\(text.count) hasImage=\(imageDataURL != nil) historyCount=\(messages.count)")
        streamTask?.cancel()
        streamTask = nil
        if messages.isEmpty {
            messages = [AIChatMessage(id: "init", role: "system", content: "你好，有什么可以帮助你吗？")]
        }
        messages.append(AIChatMessage(id: UUID().uuidString, role: "user", content: text, imageDataURL: imageDataURL))
        let assistantId = UUID().uuidString
        messages.append(AIChatMessage(id: assistantId, role: "system", content: "请等待..."))
        inputText = ""
        pickedImage = nil
        sending = true
        streamTask = Task {
            do {
                let payload: [[String: Any]] = messages
                    .filter { $0.id != assistantId }
                    .map { msg in
                        if msg.role == "user", let dataURL = msg.imageDataURL {
                            var parts: [[String: Any]] = []
                            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                parts.append(["type": "text", "text": text])
                            }
                            parts.append(["type": "image_url", "image_url": ["url": dataURL]])
                            return ["role": msg.role, "content": parts]
                        }
                        return ["role": msg.role, "content": msg.content]
                    }
                aiPanelLog("stream start payloadCount=\(payload.count)")
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                        messages[idx].content = ""
                    }
                }
                try await ChatService.shared.streamAIChatRaw(messages: payload) { delta in
                    await MainActor.run {
                        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                            messages[idx].content += delta
                        }
                    }
                }
                aiPanelLog("stream finished assistantId=\(assistantId)")
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }),
                       messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages[idx].content = "请求失败，请稍后重试"
                    }
                    sending = false
                    streamTask = nil
                }
            } catch is CancellationError {
                aiPanelLog("stream cancelled")
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }),
                       messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages[idx].content = "请求已取消"
                    }
                    sending = false
                    streamTask = nil
                }
            } catch {
                aiPanelLog("stream failed error=\(error.localizedDescription)")
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                        messages[idx].content = "请求失败，请稍后重试"
                    }
                    sending = false
                    streamTask = nil
                }
            }
        }
    }
    
    private func stopGenerating() {
        streamTask?.cancel()
        streamTask = nil
        sending = false
    }
    
    private func loadMessagesFromStorage() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([AIChatMessage].self, from: data),
           !list.isEmpty {
            messages = list
        } else {
            messages = [AIChatMessage(id: "init", role: "system", content: "你好，有什么可以帮助你吗？")]
        }
    }
    
    private func saveMessagesToStorage() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func dataURLFromImage(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1600
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let jpeg = (resized ?? image).jpegData(compressionQuality: 0.72) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
    
    private func imageFromDataURL(_ dataURL: String) -> UIImage? {
        let marker = "base64,"
        guard let range = dataURL.range(of: marker) else { return nil }
        let b64 = String(dataURL[range.upperBound...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }
    
    private func copyAIMessage(_ text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        UIPasteboard.general.string = content
        appState.presentUserFeedback("已复制", level: .success, duration: 1.2)
    }
}

private struct AIChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String
    var content: String
    var imageDataURL: String? = nil
    var isUser: Bool { role == "user" }
}

private struct BasicImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.image"]
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: BasicImagePicker
        init(parent: BasicImagePicker) { self.parent = parent }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }
    }
}

// MARK: - 话术 + 图片模板（本地存储，按账号隔离）
private struct ScriptTemplatePanel: View {
    @State private var activeType: String = "script"
    @State private var searchKeyword = ""
    @State private var currentCategory = "all"
    @State private var list: [QuickScriptTemplate] = []
    @State private var imageList: [QuickImageTemplate] = []
    @State private var editorVisible = false
    @State private var editingItem: QuickScriptTemplate?
    @State private var formTitle = ""
    @State private var formCategory = "greeting"
    @State private var formContent = ""
    @State private var showImagePicker = false
    @State private var pickedTemplateImage: UIImage?
    @State private var imageTitleEditTarget: QuickImageTemplate?
    @State private var imageTitleText = ""
    
    private let categories: [(value: String, label: String)] = [
        ("all", "全部"),
        ("greeting", "打招呼"),
        ("product", "产品介绍"),
        ("objection", "异议处理"),
        ("close", "促成"),
        ("other", "其他"),
    ]
    
    private var filteredList: [QuickScriptTemplate] {
        var items = list
        if currentCategory != "all" {
            items = items.filter { $0.category == currentCategory }
        }
        if !searchKeyword.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchKeyword.trimmingCharacters(in: .whitespaces).lowercased()
            items = items.filter { $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q) }
        }
        return items
    }
    
    private var filteredImageList: [QuickImageTemplate] {
        let q = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return imageList }
        return imageList.filter { $0.title.lowercased().contains(q) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("模板类型", selection: $activeType) {
                Text("话术模板").tag("script")
                Text("图片模板").tag("image")
            }
            .pickerStyle(.segmented)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.value) { cat in
                        Button(action: { currentCategory = cat.value }) {
                            Text(cat.label)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(currentCategory == cat.value ? Color(red: 0.09, green: 0.47, blue: 1.0) : Color(white: 0.92))
                                .foregroundColor(currentCategory == cat.value ? .white : .primary)
                                .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .opacity(activeType == "script" ? 1 : 0)
            .frame(height: activeType == "script" ? nil : 0)
            
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(activeType == "script" ? "搜索话术标题或内容..." : "搜索图片模板标题...", text: $searchKeyword)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(white: 0.96))
            .cornerRadius(8)
            
            if activeType == "script" && filteredList.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text(searchKeyword.isEmpty && currentCategory == "all" ? "还没有话术模板" : "暂无匹配话术")
                        .font(.subheadline)
                    Text(searchKeyword.isEmpty && currentCategory == "all" ? "新建一条，快速回复客户" : "试试其他关键词或分类")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if searchKeyword.isEmpty && currentCategory == "all" {
                        Button(action: { editingItem = nil; resetForm(); editorVisible = true }) {
                            Label("新建话术", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else if activeType == "script" {
                LazyVStack(spacing: 0) {
                    ForEach(filteredList) { item in
                        templateCard(item)
                    }
                }
            } else if filteredImageList.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("还没有图片模板")
                        .font(.subheadline)
                    Text("添加常用图片，聊天时一键快捷发送")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { showImagePicker = true }) {
                        Label("新建图片模板", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                HStack {
                    Spacer()
                    Button(action: { showImagePicker = true }) {
                        Label("添加图片", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                LazyVStack(spacing: 10) {
                    ForEach(filteredImageList) { item in
                        imageTemplateCard(item)
                    }
                }
            }
        }
        .onAppear { loadTemplates() }
        .sheet(isPresented: $editorVisible) {
            scriptEditorSheet
        }
        .sheet(isPresented: $showImagePicker) {
            PhotoPickerView(selectedImage: $pickedTemplateImage, isPresented: $showImagePicker)
        }
        .onChange(of: pickedTemplateImage) { img in
            guard let image = img else { return }
            addPickedImageTemplate(image)
            pickedTemplateImage = nil
        }
        .alert(
            "图片模板标题",
            isPresented: Binding(
                get: { imageTitleEditTarget != nil },
                set: { if !$0 { imageTitleEditTarget = nil } }
            )
        ) {
            TextField("请输入标题", text: $imageTitleText)
            Button("保存") { saveImageTitleEdit() }
            Button("取消", role: .cancel) {
                imageTitleEditTarget = nil
                imageTitleText = ""
            }
        } message: {
            Text("仅对当前登录账号生效")
        }
    }
    
    private func templateCard(_ item: QuickScriptTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(categoryLabel(item.category))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(item.title)
                .font(.subheadline.weight(.medium))
            Text(previewContent(item.content))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Button(action: { useTemplate(item) }) { Label("使用", systemImage: "paperplane") }
                    .font(.caption)
                Button(action: { editingItem = item; formTitle = item.title; formCategory = item.category; formContent = item.content; editorVisible = true }) { Label("编辑", systemImage: "pencil") }
                    .font(.caption)
                Button(role: .destructive, action: { confirmDelete(item) }) { Label("删除", systemImage: "trash") }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
    }
    
    private func imageTemplateCard(_ item: QuickImageTemplate) -> some View {
        HStack(spacing: 12) {
            if let image = item.uiImage() {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.92))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Button(action: { useImageTemplate(item) }) { Label("使用", systemImage: "paperplane") }
                        .font(.caption)
                    Button(action: {
                        imageTitleEditTarget = item
                        imageTitleText = item.title
                    }) { Label("编辑", systemImage: "pencil") }
                    .font(.caption)
                    Button(role: .destructive, action: { deleteImageTemplate(item) }) { Label("删除", systemImage: "trash") }
                        .font(.caption)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
    }
    
    private var scriptEditorSheet: some View {
        NavigationView {
            Form {
                TextField("标题", text: $formTitle)
                Picker("分类", selection: $formCategory) {
                    ForEach(categories.filter { $0.value != "all" }, id: \.value) { Text($0.label).tag($0.value) }
                }
                TextEditor(text: $formContent)
                    .frame(minHeight: 120)
            }
            .navigationTitle(editingItem == nil ? "新建话术" : "编辑话术")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editorVisible = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveTemplate() } }
            }
        }
        .onDisappear { resetForm() }
    }
    
    private func categoryLabel(_ value: String) -> String {
        categories.first(where: { $0.value == value })?.label ?? value
    }
    
    private func previewContent(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 60 { return t }
        return String(t.prefix(60)) + "..."
    }
    
    private func loadTemplates() {
        list = QuickTemplateStore.loadScriptTemplates().sorted { $0.updatedAt > $1.updatedAt }
        imageList = QuickTemplateStore.loadImageTemplates().sorted { $0.updatedAt > $1.updatedAt }
    }
    
    private func resetForm() {
        formTitle = ""
        formCategory = "greeting"
        formContent = ""
        editingItem = nil
    }
    
    private func saveTemplate() {
        guard !formTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if var item = editingItem {
            item.title = formTitle
            item.category = formCategory
            item.content = formContent
            item.updatedAt = Date()
            QuickTemplateStore.saveScriptTemplate(item)
            if let idx = list.firstIndex(where: { $0.id == item.id }) { list[idx] = item }
        } else {
            let item = QuickScriptTemplate(id: UUID().uuidString, title: formTitle, category: formCategory, content: formContent, updatedAt: Date())
            QuickTemplateStore.saveScriptTemplate(item)
            list.append(item)
        }
        list.sort { $0.updatedAt > $1.updatedAt }
        editorVisible = false
    }
    
    private func useTemplate(_ item: QuickScriptTemplate) {
        UIPasteboard.general.string = item.content
    }
    
    private func confirmDelete(_ item: QuickScriptTemplate) {
        list.removeAll { $0.id == item.id }
        QuickTemplateStore.deleteScriptTemplate(id: item.id)
    }
    
    private func addPickedImageTemplate(_ image: UIImage) {
        let title = "图片模板\(max(1, imageList.count + 1))"
        guard let item = QuickImageTemplate.make(title: title, image: image) else { return }
        QuickTemplateStore.saveImageTemplate(item)
        imageList.insert(item, at: 0)
    }
    
    private func useImageTemplate(_ item: QuickImageTemplate) {
        guard let image = item.uiImage() else { return }
        UIPasteboard.general.image = image
    }
    
    private func deleteImageTemplate(_ item: QuickImageTemplate) {
        imageList.removeAll { $0.id == item.id }
        QuickTemplateStore.deleteImageTemplate(id: item.id)
    }
    
    private func saveImageTitleEdit() {
        guard var target = imageTitleEditTarget else { return }
        let title = imageTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        target.title = title
        target.updatedAt = Date()
        QuickTemplateStore.saveImageTemplate(target)
        if let idx = imageList.firstIndex(where: { $0.id == target.id }) {
            imageList[idx] = target
        }
        imageList.sort { $0.updatedAt > $1.updatedAt }
        imageTitleEditTarget = nil
        imageTitleText = ""
    }
}

#Preview {
    ToolsPlaceholderView(appState: AppState())
}
