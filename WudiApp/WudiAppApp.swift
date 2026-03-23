//
//  WudiAppApp.swift
//  WudiApp
//
//  iOS 原生 App 入口，参考 H5 设计实现
//

import SwiftUI
import UserNotifications
import UIKit
import Foundation
import AudioToolbox

final class WudiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        APNSPushManager.shared.didRegister(deviceToken: deviceToken)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[APNS] register failed: \(error.localizedDescription)")
    }
}

@main
struct WudiAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(WudiAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @State private var isDisguiseUnlocked = false
    @State private var forceUpdateRequired = false
    @State private var requiredVersionText = ""
    
    init() {
        UNUserNotificationCenter.current().delegate = NewMessageNotificationDelegate.shared
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if isDisguiseUnlocked {
                    if appState.isLoggedIn {
                        MainTabView(appState: appState)
                    } else {
                        LoginView(appState: appState)
                    }
                } else {
                    CalculatorDisguiseView {
                        isDisguiseUnlocked = true
                    }
                }
            }
            .overlay {
                if forceUpdateRequired {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 12) {
                            Text("需要更新")
                                .font(.system(size: 20, weight: .bold))
                            Text(requiredVersionText.isEmpty
                                 ? "当前版本不可用，请更新后继续使用。"
                                 : "当前版本不可用，请更新到 \(requiredVersionText) 后继续使用。")
                                .font(.system(size: 15, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundColor(Color(white: 0.2))
                                .padding(.horizontal, 6)
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 320)
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                }
            }
            .allowsHitTesting(!forceUpdateRequired)
            .onAppear {
                NewMessageNotificationDelegate.shared.bind(appState: appState)
                Task {
                    await EntryCodeService.shared.preloadOnLaunch()
                    await refreshGlobalVersionGuard(forceRefresh: false)
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await refreshGlobalVersionGuard(forceRefresh: false) }
            }
        }
    }

    private func refreshGlobalVersionGuard(forceRefresh: Bool) async {
        let payload = await EntryCodeService.shared.getEntryCode(forceRefresh: forceRefresh)
        let required = payload?.version.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mismatch = !required.isEmpty && !EntryCodeService.isCurrentAppVersion(required)
        await MainActor.run {
            requiredVersionText = required
            forceUpdateRequired = mismatch
        }
    }
}

private struct EntryCodeResponseData: Decodable {
    let entryCode: String
    let version: String?
}

private struct EntryCodeCache: Codable {
    let entryCode: String
    let version: String
    let fetchedAt: TimeInterval
    let expiresAt: TimeInterval
}

private struct EntryCodePayload {
    let entryCode: String
    let version: String
}

private struct LegacyEntryCodeCacheV1: Codable {
    let entryCode: String
    let fetchedAt: TimeInterval
    let expiresAt: TimeInterval
}

private actor EntryCodeService {
    static let shared = EntryCodeService()

    private let cacheKey = "entry_code_cache_v2"
    private let legacyCacheKey = "entry_code_cache_v1"
    /// 入口码有效期：6 小时
    private let ttl: TimeInterval = 6 * 60 * 60
    private var inFlightFetch: Task<EntryCodePayload?, Never>?

    func preloadOnLaunch() async {
        _ = await getEntryCode(forceRefresh: false)
    }

    func getEntryCode(forceRefresh: Bool) async -> EntryCodePayload? {
        if !forceRefresh, let cached = validCachedCode() {
            if !cached.version.isEmpty { return cached }
        }
        if let inFlightFetch { return await inFlightFetch.value }
        let task = Task<EntryCodePayload?, Never> {
            await fetchAndCache()
        }
        inFlightFetch = task
        let value = await task.value
        inFlightFetch = nil
        return value
    }

    private func fetchAndCache() async -> EntryCodePayload? {
        do {
            let result: EntryCodeResponseData = try await APIClient.shared.post(
                baseURL: APIConfig.gvaBaseURL,
                path: "/base/getEntryCode",
                body: nil,
                useToken: false
            )
            let code = result.entryCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return nil }
            let version = result.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let now = Date().timeIntervalSince1970
            let cache = EntryCodeCache(
                entryCode: code,
                version: version,
                fetchedAt: now,
                expiresAt: now + ttl
            )
            if let data = try? JSONEncoder().encode(cache) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
            return EntryCodePayload(entryCode: code, version: version)
        } catch {
            // 仅兜底未过期缓存；过期后必须重新拉取成功才可解锁
            return validCachedCode()
        }
    }

    private func validCachedCode() -> EntryCodePayload? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(EntryCodeCache.self, from: data) else {
            return validLegacyCachedCode()
        }
        let now = Date().timeIntervalSince1970
        guard now < cache.expiresAt else { return nil }
        let code = cache.entryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = cache.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : EntryCodePayload(entryCode: code, version: version)
    }

    private func validLegacyCachedCode() -> EntryCodePayload? {
        guard let data = UserDefaults.standard.data(forKey: legacyCacheKey),
              let cache = try? JSONDecoder().decode(LegacyEntryCodeCacheV1.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince1970 < cache.expiresAt else { return nil }
        let code = cache.entryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : EntryCodePayload(entryCode: code, version: "")
    }

    nonisolated static func isCurrentAppVersion(_ required: String) -> Bool {
        let cleanRequired = required.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanRequired.isEmpty { return true }
        let info = Bundle.main.infoDictionary
        let current = ((info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? ((info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? ""
        return current == cleanRequired
    }
}

private struct CalculatorDisguiseView: View {
    let onUnlock: () -> Void
    
    @State private var expression = ""
    @State private var entryCode: String?
    @State private var entryVersion: String = ""
    @State private var loadingEntryCode = false
    @State private var loadFailed = false
    @State private var requiresUpdate = false
    
    private let buttonRows: [[String]] = [
        ["⌫", "AC", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "-"],
        ["1", "2", "3", "+"],
        ["+/-", "0", ".", "="]
    ]
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            GeometryReader { geo in
                let hPadding: CGFloat = 16
                let spacing: CGFloat = 12
                let rawWidth = geo.size.width
                let safeWidth = (rawWidth.isFinite && !rawWidth.isNaN) ? max(1, rawWidth) : 390
                let baseSize = max(44, floor((safeWidth - (hPadding * 2) - (spacing * 3)) / 4) - 2)

                VStack(spacing: 12) {
                    HStack {
                        topCircleButton(kind: .menu)
                        Spacer()
                        topCircleButton(kind: .calculator)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 0)

                    Spacer()

                    Text(formattedDisplayText())
                        .font(.system(size: 65, weight: .regular, design: .default))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.22)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)

                    if requiresUpdate {
                        Text("当前版本不可用，请先更新 App")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.31))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: spacing) {
                        ForEach(Array(buttonRows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: spacing) {
                                ForEach(Array(row.enumerated()), id: \.offset) { colIndex, title in
                                    let isTopRow = rowIndex == 0
                                    let isRightColumn = colIndex == 3
                                    let keySize = baseSize + (isRightColumn ? 3 : ((isTopRow) ? 2 : 0))
                                    Button(action: { tap(title) }) {
                                        buttonLabel(
                                            title: title,
                                            size: keySize,
                                            emphasize: isTopRow || isRightColumn,
                                            isRightColumn: isRightColumn
                                        )
                                    }
                                    .buttonStyle(CalcKeyButtonStyle())
                                }
                            }
                        }
                    }
                    .padding(.horizontal, hPadding)
                    .padding(.bottom, max(18, geo.safeAreaInsets.bottom + 6))
                }
            }
        }
        .onAppear {
            Task { await refreshEntryCode(forceRefresh: false) }
        }
    }
    
    private func backgroundColor(for title: String) -> Color {
        if ["÷", "×", "-", "+", "="].contains(title) { return Color(red: 1.0, green: 146.0 / 255.0, blue: 1.0 / 255.0) }
        if ["AC", "⌫", "%"].contains(title) { return Color(white: 0.39) }
        return Color(white: 0.20)
    }

    private func foregroundColor(for title: String) -> Color {
        _ = title
        return .white
    }

    private enum TopButtonKind {
        case menu
        case calculator
    }

    private func topCircleButton(kind: TopButtonKind) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0))
                .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 1))
                .frame(width: 42, height: 42)
            if kind == .menu {
                Image(systemName: "list.bullet")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
            } else {
                calculatorGlyph
            }
        }
    }

    private var calculatorGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1.7)
                .frame(width: 15, height: 20)
            VStack(spacing: 1.8) {
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 9, height: 4)
                HStack(spacing: 2) {
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                }
                HStack(spacing: 2) {
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 2.3, height: 2.3)
                }
            }
        }
    }

    private func buttonLabel(title: String, size: CGFloat, emphasize: Bool, isRightColumn: Bool) -> some View {
        let shownTitle = displayButtonTitle(for: title)
        let contentSize: CGFloat = emphasize ? 39 : 34
        return ZStack {
            Circle()
                .fill(backgroundColor(for: title))
            if isRightColumn {
                rightColumnOperatorContent(for: shownTitle)
            } else if shownTitle == "⌫" {
                Image(systemName: "delete.left")
                    .font(.system(size: emphasize ? 33 : 28, weight: .regular))
                    .foregroundColor(foregroundColor(for: title))
            } else if shownTitle == "+/-" {
                Image(systemName: "plus.slash.minus")
                    .font(.system(size: emphasize ? 36 : 31, weight: .regular))
                    .foregroundColor(foregroundColor(for: title))
            } else {
                Text(displayedSymbol(for: shownTitle))
                    .font(.system(size: contentSize, weight: .regular))
                    .foregroundColor(foregroundColor(for: title))
            }
        }
        .frame(width: size, height: size)
    }

    private func rightColumnOperatorContent(for title: String) -> some View {
        Group {
            switch title {
            case "÷":
                Image(systemName: "divide")
            case "×":
                Image(systemName: "multiply")
            case "-":
                Image(systemName: "minus")
            case "+":
                Image(systemName: "plus")
            case "=":
                Image(systemName: "equal")
            default:
                Image(systemName: "equal")
            }
        }
        .font(.system(size: 42, weight: .regular))
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func displayedSymbol(for title: String) -> String {
        if title == "-" { return "−" }
        return title
    }

    private func displayButtonTitle(for title: String) -> String {
        if title == "AC", !expression.isEmpty {
            return "C"
        }
        return title
    }

    private func formattedDisplayText() -> String {
        let shown = expression
            .replacingOccurrences(of: "*", with: "×")
            .replacingOccurrences(of: "/", with: "÷")
        if shown.isEmpty { return "0" }
        return shown
    }
    
    private func tap(_ title: String) {
        playKeyTapFeedback()
        switch title {
        case "AC":
            expression = ""
        case "⌫":
            guard !expression.isEmpty else { return }
            expression.removeLast()
        case "+/-":
            toggleSignForCurrentNumber()
        case "%":
            applyPercentForCurrentNumber()
        case "=":
            let normalized = expression.replacingOccurrences(of: " ", with: "")
            let normalizedEntryCode = entryCode?.replacingOccurrences(of: " ", with: "")
            if let normalizedEntryCode, !normalizedEntryCode.isEmpty, normalized == normalizedEntryCode {
                verifyLatestCodeAndUnlock(typed: normalized)
                return
            }
            requiresUpdate = false
            if normalizedEntryCode == nil {
                Task { await refreshEntryCode(forceRefresh: true) }
            }
            let result = evaluateSimpleExpression(expression)
            expression = result
        case "÷":
            appendOperator("/")
        case "×":
            appendOperator("*")
        case "-", "+":
            appendOperator(title)
        default:
            appendInput(title)
        }
    }

    private func playKeyTapFeedback() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }
    
    private func appendInput(_ input: String) {
        if expression.count >= 32 { return }
        if input == "." {
            let token = currentNumberToken().replacingOccurrences(of: "-", with: "")
            if token.contains(".") { return }
            if token.isEmpty {
                expression += (expression.isEmpty || isOperator(expression.last) ? "0." : ".")
                return
            }
        }
        if expression == "0", input != "." { expression = "" }
        expression.append(input)
    }

    private func appendOperator(_ op: String) {
        guard ["+", "-", "*", "/"].contains(op) else { return }
        if expression.isEmpty {
            if op == "-" { expression = "-" }
            return
        }
        if let last = expression.last, isOperator(last) {
            expression.removeLast()
        }
        expression.append(op)
    }

    private func currentNumberRange() -> Range<String.Index>? {
        guard !expression.isEmpty else { return nil }
        let end = expression.endIndex
        var start = end
        while start > expression.startIndex {
            let prev = expression.index(before: start)
            let ch = expression[prev]
            if ch.isNumber || ch == "." {
                start = prev
            } else {
                break
            }
        }
        guard start < end else { return nil }
        if start > expression.startIndex {
            let minusIdx = expression.index(before: start)
            if expression[minusIdx] == "-" {
                if minusIdx == expression.startIndex {
                    start = minusIdx
                } else {
                    let beforeMinus = expression.index(before: minusIdx)
                    if isOperator(expression[beforeMinus]) {
                        start = minusIdx
                    }
                }
            }
        }
        return start..<end
    }

    private func currentNumberToken() -> String {
        guard let range = currentNumberRange() else { return "" }
        return String(expression[range])
    }

    private func toggleSignForCurrentNumber() {
        guard let range = currentNumberRange() else {
            expression = expression.isEmpty ? "-" : expression
            return
        }
        let token = String(expression[range])
        if token.hasPrefix("-") {
            expression.replaceSubrange(range, with: String(token.dropFirst()))
        } else {
            expression.replaceSubrange(range, with: "-" + token)
        }
    }

    private func applyPercentForCurrentNumber() {
        guard let range = currentNumberRange(),
              let value = Double(String(expression[range])) else { return }
        let percent = value / 100.0
        let text: String
        if percent.truncatingRemainder(dividingBy: 1) == 0 {
            text = String(Int(percent))
        } else {
            text = String(percent)
        }
        expression.replaceSubrange(range, with: text)
    }

    private func isOperator(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return ch == "+" || ch == "-" || ch == "*" || ch == "/"
    }
    
    private func evaluateSimpleExpression(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        guard !text.isEmpty else { return "0" }
        let expr = NSExpression(format: text)
        if let number = expr.expressionValue(with: nil, context: nil) as? NSNumber {
            let value = number.doubleValue
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(Int(value))
            }
            return String(value)
        }
        return "0"
    }

    private func refreshEntryCode(forceRefresh: Bool) async {
        await MainActor.run {
            loadingEntryCode = true
            loadFailed = false
        }
        let payload = await EntryCodeService.shared.getEntryCode(forceRefresh: forceRefresh)
        await MainActor.run {
            entryCode = payload?.entryCode
            entryVersion = payload?.version ?? ""
            loadingEntryCode = false
            loadFailed = (payload == nil)
        }
    }

    private func isVersionMatched() -> Bool {
        let required = entryVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if required.isEmpty { return true }
        return normalizedVersion(currentAppVersion()) == normalizedVersion(required)
    }

    private func currentAppVersion() -> String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        return (info?["CFBundleVersion"] as? String) ?? ""
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func verifyLatestCodeAndUnlock(typed: String) {
        Task {
            let latest = await EntryCodeService.shared.getEntryCode(forceRefresh: false)
            await MainActor.run {
                if let latest {
                    entryCode = latest.entryCode
                    entryVersion = latest.version
                    loadFailed = false
                }
                let latestCode = entryCode?.replacingOccurrences(of: " ", with: "")
                guard let latestCode, !latestCode.isEmpty, latestCode == typed else {
                    requiresUpdate = false
                    expression = evaluateSimpleExpression(expression)
                    return
                }
                guard isVersionMatched() else {
                    requiresUpdate = true
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    return
                }
                requiresUpdate = false
                onUnlock()
            }
        }
    }
}

private struct CalcKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.09 : 1.0)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(response: 0.16, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
