//
//  BottomTabBar.swift
//  WudiApp
//
//  参考 H5 BottomTabBar.vue：4 个 Tab，选中 #1677ff，未选中 #666，可选角标
//

import SwiftUI

struct BottomTabBar: View {
    @Binding var selectedTab: TabItem
    let tabs: [TabItem]
    var unreadCount: Int = 0  // 对话未读数，与 H5 totalUnreadCount 一致
    var onTabTapped: ((TabItem, Bool) -> Void)? = nil
    
    private let activeColor = Color(red: 0.09, green: 0.47, blue: 1.0)
    private let inactiveColor = Color(red: 0.4, green: 0.4, blue: 0.4)
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                TabBarItemView(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    unreadCount: tab == .chat ? unreadCount : 0,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor
                ) {
                    let wasSelected = (selectedTab == tab)
                    selectedTab = tab
                    onTabTapped?(tab, wasSelected)
                }
            }
        }
        .frame(height: 56)
        .padding(.bottom, safeAreaBottom)
        .background(Color.white)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(white: 0.93)),
            alignment: .top
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: -2)
    }
    
    private var safeAreaBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .flatMap { $0.windows.first?.safeAreaInsets.bottom } ?? 0
    }
}

private struct TabBarItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let unreadCount: Int
    let activeColor: Color
    let inactiveColor: Color
    let action: () -> Void
    
    /// 统一图标大小（参考账号按钮）
    private let iconSize: CGFloat = 20
    /// 统一文字高度
    private let labelHeight: CGFloat = 14
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.iconName)
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundColor(isSelected ? activeColor : inactiveColor)
                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
                .frame(height: iconSize + 4)
                Text(tab.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? activeColor : inactiveColor)
                    .lineLimit(1)
                    .frame(height: labelHeight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    BottomTabBar(selectedTab: .constant(.account), tabs: TabItem.allCases)
}
