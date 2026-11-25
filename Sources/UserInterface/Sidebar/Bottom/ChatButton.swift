// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

// MARK: - SwiftUI ChatButton

/// Chat button that opens the AI Chat sidebar.
struct ChatButton: View {
    let action: () -> Void
    /// Minimum width for contexts that reserve a fixed toolbar slot.
    var contentWidth: CGFloat? = nil
    var contentHeight: CGFloat? = nil
    var systemName: String? = nil

    static var preferredContentWidth: CGFloat {
        let titleWidth = (localizedTitle as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        ).width
        return ceil(titleWidth) + Constants.iconSize + Constants.spacing + Constants.trailingPadding
    }

    @State private var isHovering = false
    @Environment(\.phiAppearance) private var appearance
    
    // MARK: - Constants
    
    private enum Constants {
        /// Button background color.
        static let backgroundColor: ThemedColor = .themeButtonBackground
        /// Icon and label color.
        static let foregroundColor: ThemedColor = .themeButtonForeground
        /// Border color in dark appearance.
        static let borderColor = Color.white.opacity(0.4)
        /// Border width.
        static let borderWidth: CGFloat = 0
        /// Vertical padding.
        static let verticalPadding: CGFloat = 0
        /// Trailing padding.
        static let trailingPadding: CGFloat = 8
        /// Leading padding.
        static let leadingPadding: CGFloat = 0
        /// Spacing between the icon and label.
        static let spacing: CGFloat = 2
        /// Icon size.
        static let iconSize: CGFloat = 22
        /// SF Symbol width. Symbol layouts pad both sides equally and keep the asset layout's total width.
        static let symbolSize: CGFloat = 14
        static let symbolSpacing: CGFloat = 4
        static let symbolHorizontalPadding: CGFloat = (iconSize + spacing + trailingPadding - symbolSize - symbolSpacing) / 2
    }

    private static var localizedTitle: String {
        NSLocalizedString(
            "sidebar.chatButton.title",
            value: "Chat",
            comment: "Sidebar bottom chat button title"
        )
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: systemName == nil ? Constants.spacing : Constants.symbolSpacing) {
                (systemName.map { Image(systemName: $0) } ?? Image(.sidebarChat))
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: systemName == nil ? Constants.iconSize : Constants.symbolSize, height: Constants.iconSize)
                    .themedForeground(Constants.foregroundColor)

                Text(Self.localizedTitle)
                    .font(.system(size: 11, weight: .medium))
                    .themedForeground(Constants.foregroundColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, systemName == nil ? Constants.leadingPadding : Constants.symbolHorizontalPadding)
            .padding(.trailing, systemName == nil ? Constants.trailingPadding : Constants.symbolHorizontalPadding)
            .padding(.vertical, Constants.verticalPadding)
            .frame(
                minWidth: contentWidth,
                minHeight: contentHeight,
                maxHeight: contentHeight
            )
            .background(Color.black.opacity(isHovering ? 0.12 : 0))
            .themedBackground(Constants.backgroundColor)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Constants.borderColor, lineWidth: Constants.borderWidth)
                    .opacity(appearance.isDark ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .customTooltip(Self.localizedTitle)
        .accessibilityLabel(Self.localizedTitle)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preview

#Preview("ChatButton") {
    ChatButton {
        print("Chat button clicked")
    }
    .frame(width: 61, height: 24)
}
