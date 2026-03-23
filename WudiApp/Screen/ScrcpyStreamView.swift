//
//  ScrcpyStreamView.swift
//  WudiApp
//
//  原生投屏：WebSocket 连接与 H5 相同协议，解析 scrcpy 二进制（跳过 initial/device 消息），H.264 解码后由 AVSampleBufferDisplayLayer 显示。
//

import SwiftUI
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit
import CoreImage
import QuartzCore

// 调试开关：上线/稳定后关闭 Scrcpy 调试日志
private let SCRCPY_DEBUG_LOGS = false

// 本文件内统一拦截 print，便于一键关闭调试输出
private func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    guard SCRCPY_DEBUG_LOGS else { return }
    let line = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(line, terminator: terminator)
}

// H5 投屏解码方式（screen-web）：URL 中 player=mse 时使用 MsePlayer，内部用 h264-converter 的
// VideoConverter.appendRawData() 把 Annex B 转成 fMP4 喂给 MSE，由浏览器原生解码并播放在 <video> 上。
// 即：解码由浏览器/系统完成。iOS 端用 AVSampleBufferDisplayLayer 也是系统解码，若仍无画面可改为
// 先用 VTDecompressionSession 显式解码为 CVPixelBuffer，再转 CMSampleBuffer 入队显示，以排查是否为合成 PPS 导致不解码。

// MARK: - WebSocket URL（与 H5 一致：streamUrl 为 http 代理，连接时用 ws）
func streamWebSocketURL(from streamURL: String) -> URL? {
    var ws = streamURL
    if ws.hasPrefix("https://") { ws = "wss" + ws.dropFirst(5) }
    else if ws.hasPrefix("http://") { ws = "ws" + ws.dropFirst(4) }
    return URL(string: ws)
}

// MARK: - 投屏流视图：WebSocket 收包 + H264 解析显示
struct ScrcpyStreamView: View {
    let streamURL: String
    let onClose: () -> Void
    
    @StateObject private var model: ScrcpyStreamModel
    @State private var touchActive = false
    @State private var inputText: String = ""
    @State private var showClipboardPanel: Bool = false
    @State private var keyboardMappingEnabled: Bool = false
    @State private var keyboardInputBuffer: String = ""
    @State private var lastKeyboardInputBuffer: String = ""
    @State private var sidePanelOffset: CGSize = .zero
    @State private var sidePanelDragStartOffset: CGSize = .zero
    @State private var sidePanelDragging = false
    @FocusState private var keyboardInputFocused: Bool
    
    init(streamURL: String, onClose: @escaping () -> Void) {
        self.streamURL = streamURL
        self.onClose = onClose
        _model = StateObject(wrappedValue: ScrcpyStreamModel(streamURL: streamURL))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button("关闭") {
                    model.disconnect()
                    onClose()
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.96))
            
            ZStack {
                Color.black
                if let coordinator = model.coordinator {
                    ScrcpyVideoLayerView(coordinator: coordinator)
                        .id(coordinator.id)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    let phase: ScrcpyTouchPhase = touchActive ? .move : .down
                                    touchActive = true
                                    model.sendTouch(at: value.location, in: geo.size, phase: phase)
                                }
                                .onEnded { value in
                                    if touchActive {
                                        model.sendTouch(at: value.location, in: geo.size, phase: .up)
                                    }
                                    touchActive = false
                                }
                        )
                }
                if showClipboardPanel {
                    clipboardInputPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(3)
                }
                rightControlPanel
                if keyboardMappingEnabled {
                    keyboardActivatorButton
                        .zIndex(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onDisappear { model.disconnect() }
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            model.connect()
        }
        .onChange(of: keyboardInputBuffer) { value in
            guard keyboardMappingEnabled else {
                lastKeyboardInputBuffer = value
                return
            }
            if value.count > lastKeyboardInputBuffer.count {
                let added = String(value.dropFirst(lastKeyboardInputBuffer.count))
                if !added.isEmpty { model.sendText(added) }
            } else if value.count < lastKeyboardInputBuffer.count {
                let delCount = lastKeyboardInputBuffer.count - value.count
                for _ in 0..<delCount { model.sendDeleteKey() }
            }
            lastKeyboardInputBuffer = value
        }
    }
    
    private func sendInputText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.sendClipboard(text, paste: true)
        inputText = ""
    }
    
    private var rightControlPanel: some View {
        GeometryReader { geo in
            let container = geo.size
            let panelSize = sidePanelSize
            let margin: CGFloat = 10
            let center = panelCenter(in: container, panelSize: panelSize, margin: margin)
            VStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !sidePanelDragging {
                                    sidePanelDragging = true
                                    sidePanelDragStartOffset = sidePanelOffset
                                }
                                let proposed = CGSize(
                                    width: sidePanelDragStartOffset.width + value.translation.width,
                                    height: sidePanelDragStartOffset.height + value.translation.height
                                )
                                sidePanelOffset = clampedSidePanelOffset(
                                    proposed,
                                    in: container,
                                    panelSize: panelSize,
                                    margin: margin
                                )
                            }
                            .onEnded { _ in
                                sidePanelDragging = false
                                let snapped = snappedSidePanelOffset(
                                    sidePanelOffset,
                                    in: container,
                                    panelSize: panelSize,
                                    margin: margin,
                                    snapThreshold: 24
                                )
                                withAnimation(.easeOut(duration: 0.12)) {
                                    sidePanelOffset = snapped
                                }
                                sidePanelDragStartOffset = snapped
                            }
                    )
                
                VStack(spacing: 12) {
                    sideControlButton(icon: "doc.on.clipboard", title: "剪贴板") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showClipboardPanel.toggle()
                        }
                    }
                    sideControlButton(icon: "house", title: "主页") {
                        model.sendHomeKey()
                    }
                    sideControlButton(icon: "square.stack.3d.up", title: "任务") {
                        model.sendAppSwitchKey()
                    }
                    sideControlButton(icon: "arrow.uturn.backward", title: "返回") {
                        model.sendBackKey()
                    }
                    sideControlButton(
                        icon: "keyboard",
                        title: "键盘映射",
                        highlighted: keyboardMappingEnabled
                    ) {
                        keyboardMappingEnabled.toggle()
                        if keyboardMappingEnabled {
                            model.statusText = "键盘映射已开启"
                        } else {
                            keyboardInputFocused = false
                            model.statusText = "键盘映射已关闭"
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .position(x: center.x, y: center.y)
        }
        .padding(.vertical, 12)
    }
    
    private var sidePanelSize: CGSize {
        let buttonCount: CGFloat = 5
        let buttonSize: CGFloat = 36
        let buttonSpacing: CGFloat = 12
        let handleSize: CGFloat = 28
        let handleGap: CGFloat = 10
        let verticalPadding: CGFloat = 12
        let horizontalPadding: CGFloat = 8
        let controlsHeight = buttonCount * buttonSize + (buttonCount - 1) * buttonSpacing
        let height = controlsHeight + handleSize + handleGap + verticalPadding * 2
        let width = buttonSize + horizontalPadding * 2
        return CGSize(width: width, height: height)
    }
    
    private func panelCenter(in container: CGSize, panelSize: CGSize, margin: CGFloat) -> CGPoint {
        let defaultX = container.width - panelSize.width / 2 - margin
        let defaultY = container.height / 2
        return CGPoint(
            x: defaultX + sidePanelOffset.width,
            y: defaultY + sidePanelOffset.height
        )
    }
    
    private func clampedSidePanelOffset(_ offset: CGSize, in container: CGSize, panelSize: CGSize, margin: CGFloat) -> CGSize {
        let defaultX = container.width - panelSize.width / 2 - margin
        let defaultY = container.height / 2
        let minX = panelSize.width / 2 + margin
        let maxX = container.width - panelSize.width / 2 - margin
        let minY = panelSize.height / 2 + margin
        let maxY = container.height - panelSize.height / 2 - margin
        
        let x = min(max(defaultX + offset.width, minX), maxX)
        let y = min(max(defaultY + offset.height, minY), maxY)
        
        return CGSize(width: x - defaultX, height: y - defaultY)
    }
    
    private func snappedSidePanelOffset(_ offset: CGSize, in container: CGSize, panelSize: CGSize, margin: CGFloat, snapThreshold: CGFloat) -> CGSize {
        let clamped = clampedSidePanelOffset(offset, in: container, panelSize: panelSize, margin: margin)
        
        let defaultX = container.width - panelSize.width / 2 - margin
        let defaultY = container.height / 2
        let minX = panelSize.width / 2 + margin
        let maxX = container.width - panelSize.width / 2 - margin
        let minY = panelSize.height / 2 + margin
        let maxY = container.height - panelSize.height / 2 - margin
        
        var x = defaultX + clamped.width
        var y = defaultY + clamped.height
        
        if abs(x - minX) <= snapThreshold { x = minX }
        if abs(x - maxX) <= snapThreshold { x = maxX }
        if abs(y - minY) <= snapThreshold { y = minY }
        if abs(y - maxY) <= snapThreshold { y = maxY }
        
        return CGSize(width: x - defaultX, height: y - defaultY)
    }
    
    private func sideControlButton(icon: String, title: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(highlighted ? Color(red: 0.32, green: 0.73, blue: 0.95) : .white)
                .frame(width: 36, height: 36)
                .background(highlighted ? Color(red: 0.32, green: 0.73, blue: 0.95).opacity(0.22) : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityLabel(title)
        .buttonStyle(.plain)
    }
    
    private var clipboardInputPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入文本，发送到安卓剪贴板", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .foregroundColor(.black)
                    .onSubmit { sendInputText() }
                Button("发送") { sendInputText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10)
            Spacer()
        }
        .padding(.top, 8)
    }
    
    private var keyboardActivatorButton: some View {
        VStack {
            Spacer()
            Button(action: {
                keyboardInputFocused = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                    Text("打开系统键盘")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
            }
            .padding(.bottom, 14)
        }
        .overlay {
            TextField("", text: $keyboardInputBuffer)
                .focused($keyboardInputFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 状态与连接
final class ScrcpyStreamModel: ObservableObject {
    let streamURL: String
    @Published var statusText: String = "正在连接…"
    /// 一开始就创建，保证 makeUIView 时 setLayer 已可调用，避免首帧到达时 layer 还未绑定
    @Published var coordinator: ScrcpyVideoCoordinator?
    
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var timeoutWorkItem: DispatchWorkItem?
    private var didReceiveAnyMessage = false
    private var receiveLoopCallCount = 0
    private var remoteScreenSize: CGSize?
    private var remoteVideoSize: CGSize?
    private var touchMoveLogCounter = 0
    private var lastTouchMoveSentAt: CFTimeInterval = 0
    private var lastTouchMovePoint: CGPoint = .zero
    private let touchSendQueue = DispatchQueue(label: "scrcpy.touch.send")
    private var touchSendInFlight = false
    private var pendingMovePayload: Data?
    private var hasSentInitialVideoSettings = false
    private var lastVideoSettingsSignature: String?
    private var lastVideoSettingsSentAt: TimeInterval = 0
    private var suppressedInitialCount = 0
    /// 关闭高频视频包日志，保留关键状态与交互日志
    private let verboseVideoStreamLogs = false
    private let magicInitial = "scrcpy_initial".data(using: .utf8)!
    private let magicMessage = "scrcpy_message".data(using: .utf8)!
    private lazy var wsCallbackQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "scrcpy.ws.callback"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    
    init(streamURL: String) {
        self.streamURL = streamURL
        let c = ScrcpyVideoCoordinator()
        c.onDecodedVideoSize = { [weak self] size in
            guard let self = self else { return }
            self.remoteVideoSize = size
            print("[Scrcpy][touch] decoded video size: \(Int(size.width))x\(Int(size.height))")
        }
        self.coordinator = c
    }
    
    func connect() {
        guard let url = streamWebSocketURL(from: streamURL) else {
            print("[Scrcpy] connect failed: invalid streamURL=\(streamURL.prefix(120))...")
            statusText = "无效的投屏地址"
            return
        }
        print("[Scrcpy] connect url=\(url.absoluteString.prefix(150))...")
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(APIConfig.host, forHTTPHeaderField: "Origin")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("no-cache", forHTTPHeaderField: "cache-control")
        request.setValue("no-cache", forHTTPHeaderField: "pragma")
        request.setValue("permessage-deflate; client_max_window_bits", forHTTPHeaderField: "sec-websocket-extensions")
        request.setValue("13", forHTTPHeaderField: "sec-websocket-version")
        request.setValue("\(APIConfig.host)/", forHTTPHeaderField: "Referer")
        if let token = APIClient.shared.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-token")
        }
        session?.invalidateAndCancel()
        let s = URLSession(configuration: .default, delegate: nil, delegateQueue: wsCallbackQueue)
        session = s
        task = s.webSocketTask(with: request)
        task?.resume()
        startConnectionTimeout()
        receiveLoop()
    }
    
    func disconnect() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        coordinator?.stop()
        coordinator = nil
        remoteVideoSize = nil
        hasSentInitialVideoSettings = false
        lastVideoSettingsSignature = nil
        lastVideoSettingsSentAt = 0
        suppressedInitialCount = 0
        touchSendQueue.async { [weak self] in
            self?.touchSendInFlight = false
            self?.pendingMovePayload = nil
        }
    }
    
    private func startConnectionTimeout() {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.didReceiveAnyMessage else { return }
            print("[Scrcpy] connection timeout (no message received)")
            DispatchQueue.main.async {
                self.statusText = "连接超时，请检查网络或稍后重试"
            }
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    
    private func receiveLoop() {
        receiveLoopCallCount += 1
        if verboseVideoStreamLogs && (receiveLoopCallCount <= 3 || receiveLoopCallCount % 50 == 0) {
            print("[Scrcpy] receiveLoop() call #\(receiveLoopCallCount) waiting...")
        }
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.didReceiveAnyMessage = true
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                switch message {
                case .data(let data):
                    self.onBinary(data)
                case .string(let text):
                    self.onString(text)
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let err):
                let ns = err as NSError
                print("[Scrcpy] receive failure: \(err)")
                print("[Scrcpy] NSError domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("[Scrcpy] underlying: domain=\(underlying.domain) code=\(underlying.code) userInfo=\(underlying.userInfo)")
                }
                let hint = (ns.domain == NSPOSIXErrorDomain && ns.code == 57)
                    ? "（通常表示代理无法连到云机内网，请在同一 WiFi 下使用或检查代理配置）"
                    : ""
                DispatchQueue.main.async {
                    self.statusText = "连接失败: \(err.localizedDescription)\(hint)"
                }
            }
        }
    }
    
    private func onBinary(_ data: Data) {
        if data.count < magicInitial.count {
            if verboseVideoStreamLogs {
                print("[Scrcpy] onBinary short len=\(data.count) -> treat as H264")
            }
            tryTreatAsH264(data)
            return
        }
        let prefix = data.prefix(magicInitial.count)
        if prefix == magicInitial {
            if let screen = parseInitialDisplaySize(data) {
                remoteScreenSize = screen
                print("[Scrcpy] initial display size: \(Int(screen.width))x\(Int(screen.height))")
            }
            maybeSendSetVideoSettingsForInitial(packetLength: data.count)
            DispatchQueue.main.async { self.statusText = "已连接，等待画面…" }
            return
        }
        if data.count >= magicMessage.count && data.prefix(magicMessage.count) == magicMessage {
            if verboseVideoStreamLogs {
                print("[Scrcpy] onBinary scrcpy_message len=\(data.count)")
            }
            return
        }
        if verboseVideoStreamLogs {
            print("[Scrcpy] onBinary video len=\(data.count) first4=\(data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        tryTreatAsH264(data)
    }
    
    func sendTouch(at localPoint: CGPoint, in localSize: CGSize, phase: ScrcpyTouchPhase) {
        guard let task = task else { return }
        guard localSize.width > 1, localSize.height > 1 else { return }
        // 优先使用解码后真实视频尺寸（与 H5 screenInfo.videoSize 语义更接近）
        let screen = remoteVideoSize ?? remoteScreenSize ?? localSize
        let mappedPoint = mapTouchPointToVideo(localPoint: localPoint, viewSize: localSize, videoSize: screen)
        guard mappedPoint.valid else {
            // 与 H5 一致：触点在黑边区域时不发送 down/move，避免无效坐标扰动服务端状态
            if phase != .up { return }
            return
        }
        let x = max(0, min(screen.width - 1, mappedPoint.x))
        let y = max(0, min(screen.height - 1, mappedPoint.y))
        let action: UInt8
        let pressure: UInt16
        let buttons: UInt32
        switch phase {
        case .down:
            action = 0 // MotionEvent.ACTION_DOWN
            pressure = 0xFFFF
            buttons = 1 // BUTTON_PRIMARY
            lastTouchMoveSentAt = CACurrentMediaTime()
            lastTouchMovePoint = CGPoint(x: x, y: y)
            print("[Scrcpy][touch] DOWN local=(\(Int(localPoint.x)),\(Int(localPoint.y))) remote=(\(Int(x)),\(Int(y))) screen=\(Int(screen.width))x\(Int(screen.height))")
        case .move:
            let now = CACurrentMediaTime()
            let dx = x - lastTouchMovePoint.x
            let dy = y - lastTouchMovePoint.y
            let dist2 = dx * dx + dy * dy
            // 节流 move 频率，降低触控与网络抖动（目标约 60Hz）
            if (now - lastTouchMoveSentAt) < (1.0 / 60.0), dist2 < 4.0 {
                return
            }
            lastTouchMoveSentAt = now
            lastTouchMovePoint = CGPoint(x: x, y: y)
            action = 2 // MotionEvent.ACTION_MOVE
            pressure = 0xFFFF
            buttons = 1
            touchMoveLogCounter += 1
            if touchMoveLogCounter % 20 == 0 {
                print("[Scrcpy][touch] MOVE remote=(\(Int(x)),\(Int(y)))")
            }
        case .up:
            action = 1 // MotionEvent.ACTION_UP
            pressure = 0
            buttons = 0
            lastTouchMoveSentAt = 0
            print("[Scrcpy][touch] UP local=(\(Int(localPoint.x)),\(Int(localPoint.y))) remote=(\(Int(x)),\(Int(y)))")
            touchMoveLogCounter = 0
        }
        var payload = Data(capacity: 29)
        payload.append(2) // ControlMessage.TYPE_TOUCH
        payload.append(action)
        payload.append(contentsOf: [0, 0, 0, 0]) // pointerId high 32 bits
        payload.append(contentsOf: be32(0)) // pointerId low 32 bits
        payload.append(contentsOf: be32(UInt32(x)))
        payload.append(contentsOf: be32(UInt32(y)))
        payload.append(contentsOf: be16(UInt16(screen.width)))
        payload.append(contentsOf: be16(UInt16(screen.height)))
        payload.append(contentsOf: be16(pressure))
        payload.append(contentsOf: be32(buttons))
        enqueueTouchPayload(payload, isMove: phase == .move)
    }
    
    private func enqueueTouchPayload(_ payload: Data, isMove: Bool) {
        touchSendQueue.async { [weak self] in
            guard let self = self else { return }
            if isMove {
                if self.touchSendInFlight {
                    // move 在途时仅保留最后一帧，避免触控发送队列积压导致拖动“发黏”
                    self.pendingMovePayload = payload
                    return
                }
                self.touchSendInFlight = true
                self.sendTouchPayloadLocked(payload)
                return
            }
            // down/up 优先发送，不与 move 合并
            self.sendTouchPayloadLocked(payload)
        }
    }
    
    private func sendTouchPayloadLocked(_ payload: Data) {
        guard let task = task else {
            touchSendInFlight = false
            pendingMovePayload = nil
            return
        }
        task.send(.data(payload)) { [weak self] err in
            guard let self = self else { return }
            if let err = err {
                print("[Scrcpy] send touch failed: \(err)")
            }
            self.touchSendQueue.async {
                self.touchSendInFlight = false
                if let next = self.pendingMovePayload {
                    self.pendingMovePayload = nil
                    self.touchSendInFlight = true
                    self.sendTouchPayloadLocked(next)
                }
            }
        }
    }
    
    private func mapTouchPointToVideo(localPoint: CGPoint, viewSize: CGSize, videoSize: CGSize) -> (x: CGFloat, y: CGFloat, valid: Bool) {
        guard viewSize.width > 1, viewSize.height > 1, videoSize.width > 1, videoSize.height > 1 else {
            return (0, 0, false)
        }
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height
        var drawRect = CGRect(origin: .zero, size: viewSize)
        if viewAspect > videoAspect {
            let drawW = viewSize.height * videoAspect
            drawRect = CGRect(x: (viewSize.width - drawW) * 0.5, y: 0, width: drawW, height: viewSize.height)
        } else {
            let drawH = viewSize.width / videoAspect
            drawRect = CGRect(x: 0, y: (viewSize.height - drawH) * 0.5, width: viewSize.width, height: drawH)
        }
        guard drawRect.contains(localPoint) else {
            return (0, 0, false)
        }
        let nx = (localPoint.x - drawRect.minX) / drawRect.width
        let ny = (localPoint.y - drawRect.minY) / drawRect.height
        return (nx * videoSize.width, ny * videoSize.height, true)
    }
    
    private func parseInitialDisplaySize(_ data: Data) -> CGSize? {
        // scrcpy_initial + deviceName(64) + displaysCount(int32) + DisplayInfo(24)
        let magicLen = magicInitial.count
        let base = magicLen + 64
        guard data.count >= base + 4 else { return nil }
        let displaysCount = readBEInt32(data, at: base)
        guard displaysCount > 0 else { return nil }
        let firstDisplay = base + 4
        guard data.count >= firstDisplay + 12 else { return nil }
        let w = readBEInt32(data, at: firstDisplay + 4)
        let h = readBEInt32(data, at: firstDisplay + 8)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
    
    private func readBEInt32(_ data: Data, at offset: Int) -> Int {
        guard data.count >= offset + 4 else { return 0 }
        return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }
    
    private func be16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    
    private func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
    
    /// 与 H5 KeyCodeControlMessage 对齐：TYPE_KEYCODE(0) + action + keycode + repeat + metaState
    private func sendKeyCode(_ keyCode: UInt32) {
        guard let task = task else { return }
        func send(action: UInt8) {
            var payload = Data()
            payload.append(0) // ControlMessage.TYPE_KEYCODE
            payload.append(action) // 0 down / 1 up
            payload.append(contentsOf: be32(keyCode))
            payload.append(contentsOf: be32(0)) // repeat
            payload.append(contentsOf: be32(0)) // metaState
            task.send(.data(payload)) { err in
                if let err = err {
                    print("[Scrcpy] send keyCode=\(keyCode) action=\(action) failed: \(err)")
                }
            }
        }
        send(action: 0)
        send(action: 1)
    }
    
    func sendBackKey() {
        sendKeyCode(4) // KEYCODE_BACK
    }
    
    func sendHomeKey() {
        sendKeyCode(3) // KEYCODE_HOME
    }
    
    func sendAppSwitchKey() {
        sendKeyCode(187) // KEYCODE_APP_SWITCH
    }
    
    func sendDeleteKey() {
        sendKeyCode(67) // KEYCODE_DEL
    }
    
    /// 与 H5 TextControlMessage 对齐：TYPE_TEXT(1) + uint32 length + utf8 bytes
    func sendText(_ text: String) {
        guard let task = task else { return }
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        let utf8 = Array(trimmed.utf8)
        var payload = Data()
        payload.append(1) // ControlMessage.TYPE_TEXT
        payload.append(contentsOf: be32(UInt32(utf8.count)))
        payload.append(contentsOf: utf8)
        task.send(.data(payload)) { err in
            if let err = err {
                print("[Scrcpy] send text failed: \(err)")
            } else {
                print("[Scrcpy] send text ok len=\(utf8.count)")
            }
        }
    }
    
    /// 与 H5 createSetClipboardCommand 对齐：TYPE_SET_CLIPBOARD(9) + paste(1) + uint32 len + utf8
    func sendClipboard(_ text: String, paste: Bool = true) {
        guard let task = task else { return }
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        let utf8 = Array(trimmed.utf8)
        var payload = Data()
        payload.append(9) // ControlMessage.TYPE_SET_CLIPBOARD
        payload.append(paste ? 1 : 0)
        payload.append(contentsOf: be32(UInt32(utf8.count)))
        payload.append(contentsOf: utf8)
        task.send(.data(payload)) { [weak self] err in
            if let err = err {
                print("[Scrcpy] send clipboard failed: \(err)")
            } else {
                print("[Scrcpy] send clipboard ok len=\(utf8.count) paste=\(paste)")
                DispatchQueue.main.async {
                    self?.statusText = paste ? "剪贴板已发送（可直接粘贴）" : "剪贴板已同步"
                }
            }
        }
    }
    
    private func onString(_ text: String) {
        // 部分代理可能将二进制以 base64 文本下发
        guard let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if !decoded.isEmpty { onBinary(decoded) }
    }
    
    private func tryTreatAsH264(_ data: Data) {
        guard let coord = coordinator else { return }
        coord.pushH264(data)
    }
    
    /// 与 H5 一致：收到 scrcpy_initial 后发送「设置视频参数」(type=101)，服务端才会开始推视频
    private func sendSetVideoSettingsCommand() {
        let typeChangeStream: UInt8 = 101
        var payload = Data()
        payload.append(typeChangeStream)
        payload.append(contentsOf: buildVideoSettingsPayload())
        task?.send(.data(payload)) { [weak self] err in
            if let e = err {
                print("[Scrcpy] sendSetVideoSettings failed: \(e)")
            } else {
                print("[Scrcpy] sendSetVideoSettings ok")
            }
        }
    }
    
    private func maybeSendSetVideoSettingsForInitial(packetLength: Int) {
        let size = remoteScreenSize ?? remoteVideoSize ?? CGSize(width: 720, height: 1280)
        let signature = "\(Int(size.width))x\(Int(size.height))#\(packetLength)"
        let now = Date().timeIntervalSince1970
        let minInterval: TimeInterval = 0.8
        
        if !hasSentInitialVideoSettings {
            hasSentInitialVideoSettings = true
            lastVideoSettingsSignature = signature
            lastVideoSettingsSentAt = now
            print("[Scrcpy] onBinary scrcpy_initial -> send setVideoSettings (first)")
            sendSetVideoSettingsCommand()
            return
        }
        
        let changed = signature != lastVideoSettingsSignature
        let cooledDown = (now - lastVideoSettingsSentAt) > minInterval
        if changed && cooledDown {
            lastVideoSettingsSignature = signature
            lastVideoSettingsSentAt = now
            suppressedInitialCount = 0
            print("[Scrcpy] onBinary scrcpy_initial -> send setVideoSettings (display changed)")
            sendSetVideoSettingsCommand()
            return
        }
        
        suppressedInitialCount += 1
        if suppressedInitialCount <= 3 || suppressedInitialCount % 20 == 0 {
            print("[Scrcpy] suppress duplicate scrcpy_initial x\(suppressedInitialCount)")
        }
    }
    
    /// VideoSettings.toBuffer() 最小格式：与 H5 一致，默认参数让服务端开始推流
    private func buildVideoSettingsPayload() -> [UInt8] {
        let bitrate: Int32 = 524_288
        let maxFps: Int32 = 24
        // 对齐 H5 MSE 默认值，86/87 节点对参数更敏感
        let iFrameInterval: Int8 = 10
        let width: Int16
        let height: Int16
        if let screen = remoteScreenSize {
            width = Int16(max(0, min(Int(screen.width), Int(Int16.max))))
            height = Int16(max(0, min(Int(screen.height), Int(Int16.max))))
        } else {
            width = 720
            height = 720
        }
        let left: Int16 = 0, top: Int16 = 0, right: Int16 = 0, bottom: Int16 = 0
        let sendFrameMeta: Int8 = 0
        let lockedVideoOrientation: Int8 = -1
        let displayId: Int32 = 0
        let codecOptionsLen: Int32 = 0, encoderNameLen: Int32 = 0
        // 与 H5 VideoSettings.BASE_BUFFER_LENGTH 严格一致：35 字节
        var buf = [UInt8](repeating: 0, count: 35)
        var o = 0
        buf[o] = UInt8((bitrate >> 24) & 0xFF); buf[o+1] = UInt8((bitrate >> 16) & 0xFF); buf[o+2] = UInt8((bitrate >> 8) & 0xFF); buf[o+3] = UInt8(bitrate & 0xFF); o += 4
        buf[o] = UInt8((maxFps >> 24) & 0xFF); buf[o+1] = UInt8((maxFps >> 16) & 0xFF); buf[o+2] = UInt8((maxFps >> 8) & 0xFF); buf[o+3] = UInt8(maxFps & 0xFF); o += 4
        buf[o] = UInt8(bitPattern: iFrameInterval); o += 1
        buf[o] = UInt8((width >> 8) & 0xFF); buf[o+1] = UInt8(width & 0xFF); o += 2
        buf[o] = UInt8((height >> 8) & 0xFF); buf[o+1] = UInt8(height & 0xFF); o += 2
        buf[o] = UInt8((left >> 8) & 0xFF); buf[o+1] = UInt8(left & 0xFF); o += 2
        buf[o] = UInt8((top >> 8) & 0xFF); buf[o+1] = UInt8(top & 0xFF); o += 2
        buf[o] = UInt8((right >> 8) & 0xFF); buf[o+1] = UInt8(right & 0xFF); o += 2
        buf[o] = UInt8((bottom >> 8) & 0xFF); buf[o+1] = UInt8(bottom & 0xFF); o += 2
        buf[o] = UInt8(bitPattern: sendFrameMeta); o += 1
        buf[o] = UInt8(bitPattern: lockedVideoOrientation); o += 1
        buf[o] = UInt8((displayId >> 24) & 0xFF); buf[o+1] = UInt8((displayId >> 16) & 0xFF); buf[o+2] = UInt8((displayId >> 8) & 0xFF); buf[o+3] = UInt8(displayId & 0xFF); o += 4
        buf[o] = UInt8((codecOptionsLen >> 24) & 0xFF); buf[o+1] = UInt8((codecOptionsLen >> 16) & 0xFF); buf[o+2] = UInt8((codecOptionsLen >> 8) & 0xFF); buf[o+3] = UInt8(codecOptionsLen & 0xFF); o += 4
        buf[o] = UInt8((encoderNameLen >> 24) & 0xFF); buf[o+1] = UInt8((encoderNameLen >> 16) & 0xFF); buf[o+2] = UInt8((encoderNameLen >> 8) & 0xFF); buf[o+3] = UInt8(encoderNameLen & 0xFF)
        return buf
    }
}

enum ScrcpyTouchPhase {
    case down
    case move
    case up
}

// MARK: - H.264 参数集辅助（从 SPS 解析 seq_parameter_set_id，合成最小 PPS）
private func readUEV(from data: Data, byteOffset: inout Int, bitOffset: inout Int) -> Int? {
    let bytes = [UInt8](data)
    let totalBits = bytes.count * 8
    var bitIndex = byteOffset * 8 + bitOffset
    guard bitIndex < totalBits else { return nil }
    var leadingZeros = -1
    var b = 0
    while b == 0 && bitIndex < totalBits {
        let byte = bytes[bitIndex / 8]
        let bit = (byte >> (7 - (bitIndex % 8))) & 1
        b = Int(bit)
        leadingZeros += 1
        bitIndex += 1
    }
    guard b == 1 else { return nil }
    var value = 0
    for i in 0..<leadingZeros {
        guard bitIndex < totalBits else { return nil }
        let byte = bytes[bitIndex / 8]
        let bit = (byte >> (7 - (bitIndex % 8))) & 1
        value = (value << 1) | Int(bit)
        bitIndex += 1
    }
    byteOffset = bitIndex / 8
    bitOffset = bitIndex % 8
    return (1 << leadingZeros) - 1 + value
}

/// 从 SPS NAL 中解析 seq_parameter_set_id（H.264 表 7-1：profile_idc 后为 constraint_set、level_idc，再后为 ue(v) seq_parameter_set_id）
private func parseSeqParameterSetId(from spsNAL: Data) -> Int? {
    guard spsNAL.count >= 5 else { return nil }
    var byteOffset = 4
    var bitOffset = 0
    return readUEV(from: spsNAL, byteOffset: &byteOffset, bitOffset: &bitOffset)
}

/// 合成最小 PPS NAL（仅含 NAL 头 + 最小 RBSP），用于与 SPS 一起创建 formatDescription。seqParameterSetId 需与 SPS 一致。
private func buildMinimalPPS(seqParameterSetId: Int) -> Data? {
    // 最小 PPS：pic_parameter_set_id=0, seq_parameter_set_id=*, entropy_coding_mode=0, 等；Baseline 常用 seq_id=0
    if seqParameterSetId == 0 {
        return Data([0x68, 0xcb, 0x83, 0xcb, 0x20])
    }
    if seqParameterSetId == 1 {
        return Data([0x68, 0xce, 0x38, 0x80])
    }
    return Data([0x68, 0xce, 0x38, 0x80])
}

// MARK: - 视频层协调器：H.264 → [VT 解码] → CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer
final class ScrcpyVideoCoordinator: NSObject {
    let id = UUID()
    private var displayLayer: AVSampleBufferDisplayLayer?
    private weak var fallbackImageView: UIImageView?
    private var formatDescription: CMFormatDescription?
    private var spsNAL: Data?
    private var ppsNAL: Data?
    private var decompressionSession: VTDecompressionSession?
    private let queue = DispatchQueue(label: "scrcpy.h264")
    private var buffer = Data()
    private let startCode = Data([0x00, 0x00, 0x00, 0x01])
    private let startCodeShort = Data([0x00, 0x00, 0x01])
    private var frameCount: Int64 = 0
    /// 与 H5 WebCodecs 一致：收到 IDR 后才开始入队，避免无参考帧的 P 帧导致不显示
    private var hadIDR = false
    private var decodedFrameCount: Int64 = 0
    private var decodedPTS: Int64 = 0
    /// NAL 明细日志量很大，默认关闭
    private let verboseNALLogs = false
    var onDecodedVideoSize: ((CGSize) -> Void)?
    private var lastDecodedVideoSize: CGSize = .zero
    
    func setLayer(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
    }
    
    func setFallbackImageView(_ imageView: UIImageView) {
        fallbackImageView = imageView
    }
    
    private static let vtDecodeCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, pts, _ in
        guard status == noErr, let img = imageBuffer, let refCon = refCon else {
            if status != noErr { print("[Scrcpy] VT decode callback status=\(status)") }
            return
        }
        let coord = Unmanaged<ScrcpyVideoCoordinator>.fromOpaque(refCon).takeUnretainedValue()
        coord.enqueueDecodedPixelBuffer(img, pts: pts)
    }
    
    private func makeDecompressionSession(formatDescription fd: CMFormatDescription) -> VTDecompressionSession? {
        var session: VTDecompressionSession?
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.vtDecodeCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let err = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &record,
            decompressionSessionOut: &session
        )
        if err != noErr {
            print("[Scrcpy] VTDecompressionSessionCreate failed: \(err)")
            return nil
        }
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }
    
    private func rebuildDecompressionSessionIfPossible(reason: String) {
        guard let fd = formatDescription else { return }
        if let old = decompressionSession {
            VTDecompressionSessionInvalidate(old)
            decompressionSession = nil
        }
        decompressionSession = makeDecompressionSession(formatDescription: fd)
        if decompressionSession != nil {
            print("[Scrcpy] VTDecompressionSession rebuilt (\(reason))")
        } else {
            print("[Scrcpy] VTDecompressionSession rebuild failed (\(reason))")
        }
    }
    
    private func enqueueDecodedPixelBuffer(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        guard let layer = displayLayer else { return }
        let pixelW = CVPixelBufferGetWidth(imageBuffer)
        let pixelH = CVPixelBufferGetHeight(imageBuffer)
        let currentSize = CGSize(width: pixelW, height: pixelH)
        if currentSize != lastDecodedVideoSize {
            lastDecodedVideoSize = currentSize
            DispatchQueue.main.async { [weak self] in
                self?.onDecodedVideoSize?(currentSize)
            }
        }
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return }
        var sampleBuffer: CMSampleBuffer?
        // 使用本地单调 PTS，避免 VT 回调时间戳在部分设备上异常导致 display layer 不显示
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: decodedPTS, timescale: 30),
            decodeTimeStamp: .invalid
        )
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard err == noErr, let sb = sampleBuffer else { return }
        // 与编码样本一致：实时流立即显示，避免 timebase/PTS 导致可解码但不出图
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dic = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dic, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        decodedFrameCount += 1
        decodedPTS += 1
        
        DispatchQueue.main.async {
            if self.decodedFrameCount <= 3 || self.decodedFrameCount % 30 == 0 {
                print("[Scrcpy] decoded callback #\(self.decodedFrameCount) vtPts=\(pts.value)/\(pts.timescale) layer=\(layer.bounds.width)x\(layer.bounds.height)")
            }
            self.fallbackImageView?.isHidden = true
            layer.isHidden = false
            layer.opacity = 1.0
            layer.enqueue(sb)
            if layer.status == .failed {
                print("[Scrcpy] displayLayer failed after decoded enqueue: \(layer.error?.localizedDescription ?? "unknown")")
                layer.flushAndRemoveImage()
            }
        }
    }
    
    func pushH264(_ data: Data) {
        queue.async { [weak self] in
            self?.appendAndDecode(data)
        }
    }
    
    func stop() {
        queue.async { [weak self] in
            if let s = self?.decompressionSession {
                VTDecompressionSessionInvalidate(s)
                self?.decompressionSession = nil
            }
            self?.buffer.removeAll()
            self?.formatDescription = nil
        }
    }
    
    private var nalProcessedCount = 0
    private func appendAndDecode(_ data: Data) {
        buffer.append(data)
        var n = 0
        while let (nal, rest) = nextNAL() {
            buffer = rest
            processNAL(nal)
            n += 1
        }
        if verboseNALLogs && n > 0 {
            print("[Scrcpy] NALs from chunk: \(n) total=\(nalProcessedCount) bufferRemain=\(buffer.count)")
        }
    }
    
    /// 最大 NAL 长度（避免异常数据）
    private let maxNALLength = 2 * 1024 * 1024
    
    private func nextNAL() -> (Data, Data)? {
        let len = buffer.count
        guard len >= 3 else { return nil }
        
        // Annex B 起始：优先按 Annex B 解析，避免 0x00 0x00 0x00 0x01 被误当 AVCC length=1
        if buffer.prefix(4) == startCode || buffer.prefix(3) == startCodeShort {
            return nextNALAnnexB()
        }
        
        // 非 Annex B 起始时尝试 AVCC：4 字节大端长度 + NAL（与 H5 WebCodecsPlayer 一致）
        if len >= 4 {
            let lenVal = (Int(buffer[0]) << 24) | (Int(buffer[1]) << 16) | (Int(buffer[2]) << 8) | Int(buffer[3])
            if lenVal >= 1, lenVal <= maxNALLength, len >= 4 + lenVal {
                let nalStart = buffer.startIndex + 4
                let nalEnd = buffer.index(nalStart, offsetBy: lenVal)
                let nal = Data(buffer[nalStart..<nalEnd])
                let rest = nalEnd < buffer.endIndex ? Data(buffer[nalEnd...]) : Data()
                return (nal, rest)
            }
        }
        
        // 缓冲不足或格式不明时，丢弃到下一个 Annex B 起始或等待更多数据
        if let idx = buffer.range(of: startCode)?.lowerBound ?? buffer.range(of: startCodeShort)?.lowerBound {
            buffer = Data(buffer[idx...])
        }
        return nil
    }
    
    private func nextNALAnnexB() -> (Data, Data)? {
        let len = buffer.count
        let drop: Int
        if buffer.prefix(4) == startCode { drop = 4 }
        else if buffer.prefix(3) == startCodeShort { drop = 3 }
        else { return nil }
        guard len > drop else { return nil }
        let after = buffer.index(buffer.startIndex, offsetBy: drop)
        var nextStart: Data.Index?
        for i in drop..<(len - 2) {
            let idx = buffer.index(buffer.startIndex, offsetBy: i)
            if i + 4 <= len, buffer[idx..<buffer.index(idx, offsetBy: 4)] == startCode {
                nextStart = idx
                break
            }
            if i + 3 <= len, buffer[idx..<buffer.index(idx, offsetBy: 3)] == startCodeShort {
                nextStart = idx
                break
            }
        }
        if let end = nextStart {
            let nal = Data(buffer[after..<end])
            // 不能跳过下一个 start code；否则后续 NAL 边界会错位，导致类型异常/黑屏
            let rest = end < buffer.endIndex ? Data(buffer[end...]) : Data()
            return (nal, rest)
        }
        return nil
    }
    
    private func processNAL(_ nal: Data) {
        guard nal.count > 0 else { return }
        let type = (nal.first! & 0x1F)
        let idx = nalProcessedCount
        nalProcessedCount += 1
        if verboseNALLogs && idx < 30 {
            let firstHex = nal.prefix(2).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[Scrcpy] NAL #\(idx) type=\(type) len=\(nal.count) first=\(firstHex)")
        }
        if type == 7 {
            spsNAL = nal
            print("[Scrcpy] got SPS len=\(nal.count)")
            if formatDescription == nil {
                formatDescription = createFormatDescription(sps: nal, pps: nil)
                if formatDescription != nil {
                    print("[Scrcpy] formatDescription created from SPS only")
                } else {
                    let seqIdsToTry = [parseSeqParameterSetId(from: nal), 0, 1].compactMap { $0 }
                    for seqId in seqIdsToTry {
                        guard let syntheticPPS = buildMinimalPPS(seqParameterSetId: seqId) else { continue }
                        formatDescription = createFormatDescription(sps: nal, pps: syntheticPPS)
                        if formatDescription != nil {
                            print("[Scrcpy] formatDescription created with synthetic PPS (seq_parameter_set_id=\(seqId))")
                            break
                        }
                    }
                    if formatDescription == nil {
                        print("[Scrcpy] SPS-only and synthetic PPS all failed")
                    }
                }
                if let fd = formatDescription, decompressionSession == nil {
                    decompressionSession = makeDecompressionSession(formatDescription: fd)
                    if decompressionSession != nil { print("[Scrcpy] VTDecompressionSession created") }
                }
            }
            return
        }
        if type == 8 {
            ppsNAL = nal
            if let sps = spsNAL, let pps = ppsNAL {
                formatDescription = createFormatDescription(sps: sps, pps: pps)
                if formatDescription != nil {
                    print("[Scrcpy] got PPS, formatDescription created")
                    // 关键：真实 PPS 到达后必须重建 session，不能继续沿用 synthetic PPS 创建的旧 session
                    rebuildDecompressionSessionIfPossible(reason: "real PPS")
                } else {
                    print("[Scrcpy] got PPS but createFormatDescription failed")
                }
            } else {
                print("[Scrcpy] got PPS but missing SPS")
            }
            return
        }
        if type != 1 && type != 5 { return }
        if type == 5 { hadIDR = true }
        if !hadIDR { return }
        guard let fd = formatDescription else {
            if frameCount < 5 { print("[Scrcpy] drop slice: no formatDescription yet (type=\(type))") }
            return
        }
        guard let layer = displayLayer else {
            if frameCount < 3 { print("[Scrcpy] drop slice: displayLayer nil") }
            return
        }
        let pts = frameCount
        frameCount += 1
        guard let encodedBuffer = createSampleBuffer(nal: nal, formatDescription: fd, presentationTime: pts) else {
            if frameCount <= 2 { print("[Scrcpy] createSampleBuffer failed") }
            return
        }
        if pts == 0 { print("[Scrcpy] decode first frame (IDR) pts=0") }
        if pts % 30 == 0 { print("[Scrcpy] decode frame pts=\(pts)") }
        if let session = decompressionSession {
            // iOS 15+ 也走显式 VT 解码，避免仅 enqueue 编码帧在合成 PPS 场景下不出图
            var infoFlags: VTDecodeInfoFlags = []
            let err = VTDecompressionSessionDecodeFrame(session, sampleBuffer: encodedBuffer, flags: [], frameRefcon: nil, infoFlagsOut: &infoFlags)
            if err != noErr, (pts < 3 || pts % 30 == 0) {
                print("[Scrcpy] VTDecompressionSessionDecodeFrame err=\(err) pts=\(pts)")
            } else if infoFlags.contains(.frameDropped), (pts < 3 || pts % 30 == 0) {
                print("[Scrcpy] VT decode frame dropped pts=\(pts)")
            }
            return
        }
        DispatchQueue.main.async {
            let w = layer.bounds.width, h = layer.bounds.height
            if pts == 0 { print("[Scrcpy] layer bounds when first frame: \(w)x\(h)") }
            if w <= 0 || h <= 0 { print("[Scrcpy] warn: layer bounds zero") }
            layer.isHidden = false
            layer.opacity = 1.0
            layer.enqueue(encodedBuffer)
            if layer.status == .failed {
                print("[Scrcpy] displayLayer failed after encoded enqueue: \(layer.error?.localizedDescription ?? "unknown")")
                layer.flushAndRemoveImage()
            }
        }
    }
    
    private func createFormatDescription(sps: Data, pps: Data?) -> CMFormatDescription? {
        var fd: CMFormatDescription?
        guard sps.count > 0 else { return nil }
        let err: OSStatus
        if let pps = pps, pps.count > 0 {
            err = sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    var f: CMFormatDescription?
                    let e = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: [spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)],
                        parameterSetSizes: [sps.count, pps.count],
                        // createSampleBuffer 使用的是 4 字节 AVCC 长度头，需与此保持一致
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &f
                    )
                    fd = f
                    return e
                }
            }
        } else {
            err = sps.withUnsafeBytes { spsPtr in
                var f: CMFormatDescription?
                let e = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 1,
                    parameterSetPointers: [spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)],
                    parameterSetSizes: [sps.count],
                    // createSampleBuffer 使用的是 4 字节 AVCC 长度头，需与此保持一致
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &f
                )
                fd = f
                return e
            }
        }
        return err == noErr ? fd : nil
    }
    
    private func createSampleBuffer(nal: Data, formatDescription: CMFormatDescription, presentationTime: Int64 = 0) -> CMSampleBuffer? {
        var lenBe = UInt32(nal.count).bigEndian
        var block: CMBlockBuffer?
        let totalLen = 4 + nal.count
        let err = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLen,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLen,
            flags: 0,
            blockBufferOut: &block
        )
        guard err == noErr, let b = block else { return nil }
        CMBlockBufferReplaceDataBytes(with: &lenBe, blockBuffer: b, offsetIntoDestination: 0, dataLength: 4)
        nal.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CMBlockBufferReplaceDataBytes(with: base, blockBuffer: b, offsetIntoDestination: 4, dataLength: nal.count)
            }
        }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: presentationTime, timescale: 30),
            decodeTimeStamp: .invalid
        )
        let sampleSize = totalLen
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: b,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &sampleBuffer
        )
        guard let sb = sampleBuffer else { return nil }
        // 实时流：立即显示，不依赖 PTS 与 timebase
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dic = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dic, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

// MARK: - 容器 View：在 layoutSubviews 中设置 AVSampleBufferDisplayLayer 的 frame，保证有尺寸后再显示
private final class ScrcpyVideoContainerView: UIView {
    let videoLayer = AVSampleBufferDisplayLayer()
    let fallbackImageView = UIImageView()
    /// SwiftUI 首帧时可能尚未 layout，bounds 为 .zero，导致 layer 无显示区域；给一个默认尺寸
    private static let fallbackSize = CGSize(width: 720, height: 1280)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
        fallbackImageView.backgroundColor = .black
        fallbackImageView.contentMode = .scaleAspectFit
        fallbackImageView.isHidden = true
        addSubview(fallbackImageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        let layerFrame: CGRect
        if size.width > 0, size.height > 0 {
            layerFrame = bounds
        } else {
            layerFrame = CGRect(origin: .zero, size: Self.fallbackSize)
        }
        if videoLayer.frame != layerFrame {
            videoLayer.frame = layerFrame
        }
        if fallbackImageView.frame != layerFrame {
            fallbackImageView.frame = layerFrame
        }
    }
}

// MARK: - UIViewRepresentable 包装 AVSampleBufferDisplayLayer
struct ScrcpyVideoLayerView: UIViewRepresentable {
    let coordinator: ScrcpyVideoCoordinator
    
    func makeUIView(context: Context) -> UIView {
        let v = ScrcpyVideoContainerView()
        coordinator.setLayer(v.videoLayer)
        coordinator.setFallbackImageView(v.fallbackImageView)
        return v
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let v = uiView as? ScrcpyVideoContainerView else { return }
        let size = v.bounds.size
        let layerFrame = (size.width > 0 && size.height > 0) ? v.bounds : CGRect(origin: .zero, size: CGSize(width: 720, height: 1280))
        if v.videoLayer.frame != layerFrame {
            v.videoLayer.frame = layerFrame
        }
    }
}
