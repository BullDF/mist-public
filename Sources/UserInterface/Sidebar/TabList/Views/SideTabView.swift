// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
// MARK: - SideTabView

struct SideTabView: View {
    static let trailingHoverDeadZoneWidth: CGFloat = 6
    static let leadingContentInset: CGFloat = 6

    var model: TabViewModel
    var onClose: (() -> Void)? = nil
    /// Peeked page's view model for the trailing indicator; only read while
    /// `model.showsPeek` is set.
    var peekModel: TabViewModel? = nil
    var onClosePeek: (() -> Void)? = nil

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private var backgroundColor: Color {
        if model.isActive {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if model.isMultiSelected {
            return ThemedColor.tabSubSelectionBackground.swiftUIColor(
                theme: theme,
                appearance: appearance
            )
        }
        if model.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        if model.isActive && appearance == .dark {
            return .white.opacity(0.2)
        }
        return .clear
    }

    private var borderWidth: CGFloat {
        model.isActive ? 1 : 0
    }

    private var cornerRadius: CGFloat { 8 }

    private var dropShadowOpacity: Double {
        model.isActive ? 0.15 : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            UnifiedTabFaviconView(viewModel: model)
                .frame(width: 16, height: 16)

            if model.isCurrentlyAudible || model.isMuted {
                UnifiedTabMuteButton(viewModel: model)
            }

            UnifiedTabTitleView(viewModel: model)
                .opacity(model.isRenaming ? 0 : 1)
                .themedForeground(model.isEndedAgentChat ? .textTertiary : .textPrimary)

            if model.showsPeek, let peekModel {
                SidebarPeekIndicatorView(viewModel: peekModel,
                                         onClose: { onClosePeek?() })
            }

            AgentSidebarStatusView(status: model.agentSidebarStatus)

            // While a peek is attached, the row's only close affordance is
            // the peek indicator's "minus" (same rule as the bookmark row).
            if model.isHovered, !model.showsPeek {
                UnifiedTabCloseButton { onClose?() }
            }
        }
//        .debugBorder(.green)
        .help(model.showsTabPreview ? "" : model.displayTitle)
        .padding(.leading, Self.leadingContentInset)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: .black.opacity(dropShadowOpacity), radius: 1, x: 0, y: 1)
        .overlay(alignment: .topTrailing) {
            TabCornerBadgeView(
                model: model.status,
                isSuppressed: model.showsPeek
            )
            .offset(
                x: TabCornerBadgeMetrics.overhang,
                y: -TabCornerBadgeMetrics.overhang
            )
        }
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, model.isInGroup ? 2 : WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(model.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.08), value: model.isPressed)
        .onHover { hovering in
            model.setHovered(hovering)
        }
//        .debugBorder(.red)
    }
}

struct AgentSidebarStatusView: View {
    /// The working spinner's side: close to a chat favicon's glyph, never past its 16 pt slot.
    static let spinnerSize: CGFloat = 12

    let status: AgentSidebarStatus

    var body: some View {
        switch status {
        case .none: EmptyView()
        case .running:
            ProgressView().controlSize(.small).scaleEffect(Self.spinnerSize / 16)
                .frame(width: Self.spinnerSize, height: Self.spinnerSize)
                .accessibilityLabel(Text(NSLocalizedString("mist.sidebar.agents.status.running", value: "Running", comment: "Agent sidebar - Running status accessibility label")))
        case .background:
            // A static ring, never the spinner: the agent's turn ended, but its background work still runs.
            MistDot(color: .themeColor, isHollow: true)
                .accessibilityLabel(Text(NSLocalizedString("mist.sidebar.agents.status.background", value: "Running in background", comment: "Agent sidebar - Accessibility label for an idle chat whose background task or monitor still runs")))
        case .needsInput:
            dot(.orange, label: NSLocalizedString("mist.sidebar.agents.status.needsInput", value: "Needs input", comment: "Agent sidebar - Needs input status accessibility label"))
        case .done:
            dot(.green, label: NSLocalizedString("mist.sidebar.agents.status.done", value: "Done", comment: "Agent sidebar - Unseen completion status accessibility label"))
        case .failed:
            dot(.red, label: NSLocalizedString("mist.sidebar.agents.status.failed", value: "Failed", comment: "Agent sidebar - Failed status accessibility label"))
        }
    }

    private func dot(_ color: Color, label: String) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityLabel(Text(label))
    }
}

// MARK: - Previews

#Preview("Normal Tabs") {
    VStack(spacing: 6) {
        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = "PhiBrowser"
                vm.url = "https://phibrowser.com"
                vm.isActive = true
                return vm
            }()
        )
        .frame(height: 32)

        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = ""
                vm.url = "https://example.com/some/really/long/path/to/test/truncation"
                vm.isActive = false
                return vm
            }()
        )
        .frame(height: 32)
    }
    .padding(12)
    .frame(width: 320)
}
