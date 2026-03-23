//
//  FloatLogoutButton.swift
//  WudiApp
//
//  参考 H5 主布局中的悬浮退出按钮，可点击退出登录；支持拖动并停留在新位置
//

import SwiftUI
import UIKit

private let buttonSize: CGFloat = 56

struct FloatLogoutButton: View {
    @ObservedObject var appState: AppState
    var containerSize: CGSize = .zero
    var safeAreaBottom: CGFloat = 0
    
    @State private var savedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isTouchActive = false
    @State private var touchBeganAt: Date?
    @State private var countdownStartedAt: Date?
    @State private var countdownProgress: CGFloat = 0
    @State private var holdMonitorTask: Task<Void, Never>?
    @State private var emergencyTriggered = false
    
    private var totalOffset: CGSize {
        CGSize(width: savedOffset.width + dragOffset.width, height: savedOffset.height + dragOffset.height)
    }
    
    private let tapDistanceThreshold: CGFloat = 8
    private let armDelay: TimeInterval = 0.6
    private let triggerDuration: TimeInterval = 3.0
    
    var body: some View {
        ZStack(alignment: .top) {
            buttonCore
            if isInDangerCountdown {
                dangerHint
                    .offset(
                        x: totalOffset.width - 64,
                        y: totalOffset.height - 54
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDisappear {
            holdMonitorTask?.cancel()
            holdMonitorTask = nil
        }
    }
    
    private var buttonCore: some View {
        ZStack {
            Circle()
                .fill(isInDangerCountdown ? Color(red: 0.88, green: 0.18, blue: 0.18) : Color(red: 0.09, green: 0.47, blue: 1.0))
            Circle()
                .stroke(Color.white.opacity(isInDangerCountdown ? 0.96 : 0.32), lineWidth: isInDangerCountdown ? 2.2 : 1.2)
            if isInDangerCountdown {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, countdownProgress)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.8)
            }
            Image(systemName: isInDangerCountdown ? "trash.fill" : "rectangle.portrait.and.arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: buttonSize, height: buttonSize)
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
        .offset(totalOffset)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let movedDistance = hypot(value.translation.width, value.translation.height)
                    if !isTouchActive {
                        isTouchActive = true
                        emergencyTriggered = false
                        touchBeganAt = Date()
                        countdownStartedAt = nil
                        countdownProgress = 0
                        startHoldMonitor()
                    }
                    if movedDistance > tapDistanceThreshold {
                        if !isDragging {
                            isDragging = true
                            cancelDangerCountdown()
                        }
                        dragOffset = value.translation
                    } else if !isDragging {
                        dragOffset = .zero
                    }
                }
                .onEnded { value in
                    let movedDistance = hypot(value.translation.width, value.translation.height)
                    let held = touchBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                    let wasDragging = isDragging
                    let shouldTriggerTapLogout = !emergencyTriggered
                        && !wasDragging
                        && movedDistance <= tapDistanceThreshold
                        && held < armDelay
                    
                    if wasDragging {
                        savedOffset = clampOffset(
                            CGSize(
                                width: savedOffset.width + value.translation.width,
                                height: savedOffset.height + value.translation.height
                            )
                        )
                    } else {
                        savedOffset = savedOffset
                    }
                    dragOffset = .zero
                    isDragging = false
                    isTouchActive = false
                    touchBeganAt = nil
                    holdMonitorTask?.cancel()
                    holdMonitorTask = nil
                    if !emergencyTriggered {
                        cancelDangerCountdown()
                    }
                    if shouldTriggerTapLogout {
                        appState.logout()
                    }
                }
        )
    }
    
    private var isInDangerCountdown: Bool {
        countdownStartedAt != nil && !emergencyTriggered
    }
    
    private var dangerHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("继续按住清除数据")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            Text("剩余 \(max(0.1, triggerDuration * (1 - Double(countdownProgress))), specifier: "%.1f") 秒")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    private func startHoldMonitor() {
        holdMonitorTask?.cancel()
        holdMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                await MainActor.run {
                    guard isTouchActive, !isDragging else { return }
                    guard let touchBeganAt else { return }
                    let now = Date()
                    let touchElapsed = now.timeIntervalSince(touchBeganAt)
                    if countdownStartedAt == nil {
                        if touchElapsed >= armDelay {
                            countdownStartedAt = now
                            countdownProgress = 0.001
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        return
                    }
                    guard let countdownStartedAt else { return }
                    let countdownElapsed = now.timeIntervalSince(countdownStartedAt)
                    let progress = min(1, max(0, countdownElapsed / triggerDuration))
                    countdownProgress = CGFloat(progress)
                    if progress >= 1, !emergencyTriggered {
                        emergencyTriggered = true
                        isTouchActive = false
                        holdMonitorTask?.cancel()
                        holdMonitorTask = nil
                        cancelDangerCountdown()
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        appState.emergencyWipeAndLogout()
                    }
                }
            }
        }
    }
    
    private func cancelDangerCountdown() {
        countdownStartedAt = nil
        countdownProgress = 0
    }
    
    private func clampOffset(_ offset: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return offset }
        let margin: CGFloat = 12
        let rightPadding: CGFloat = 16
        let bottomPadding: CGFloat = 80 + safeAreaBottom
        let defaultLeft = containerSize.width - rightPadding - buttonSize
        let defaultTop = containerSize.height - bottomPadding - buttonSize
        return CGSize(
            width: min(rightPadding - margin, max(margin - defaultLeft, offset.width)),
            height: min(bottomPadding - margin, max(margin - defaultTop, offset.height))
        )
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        FloatLogoutButton(appState: AppState())
    }
}
