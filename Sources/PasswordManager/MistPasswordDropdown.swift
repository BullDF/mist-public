import AppKit
import SwiftUI

private enum Metrics {
    static let inset: CGFloat = 5
    static let twoLineRow: CGFloat = 40
    static let oneLineRow: CGFloat = 28
    static let separator: CGFloat = 9
    static let maxHeight: CGFloat = 340

    static func rowHeight(for login: MistLogin, pageHost: String) -> CGFloat {
        login.host == pageHost ? oneLineRow : twoLineRow
    }

    static func panelHeight(for logins: [MistLogin], emails: [MistEmail], codes: [MistMailCode], pageHost: String) -> CGFloat {
        if !codes.isEmpty { return 2 * inset + CGFloat(codes.count) * twoLineRow }
        return min(maxHeight, 2 * inset + (logins.isEmpty && emails.isEmpty ? oneLineRow : logins.reduce(CGFloat.zero) {
            $0 + rowHeight(for: $1, pageHost: pageHost)
        }) + CGFloat(emails.count) * oneLineRow + (logins.isEmpty || emails.isEmpty ? 0 : separator) + separator + oneLineRow)
    }
}

@MainActor
final class MistPasswordDropdown: ObservableObject {
    enum Choice { case login(MistLogin), email(MistEmail), code(MistMailCode), manage }
    @Published var selected = 0
    @Published private(set) var logins: [MistLogin] = []
    @Published private(set) var emails: [MistEmail] = []
    @Published private(set) var codes: [MistMailCode] = []
    var itemCount: Int { logins.count + emails.count + codes.count }
    private(set) var pageHost = ""
    var choose: ((Choice) -> Void)?
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible == true }

    func show(logins: [MistLogin], emails: [MistEmail], codes: [MistMailCode] = [], pageHost: String, rect: CGRect, dpr: CGFloat, in view: NSView) -> Bool {
        guard let window = view.window, rect.width > 0, rect.height > 0, dpr > 0,
              [rect.minX, rect.minY, rect.width, rect.height, dpr].allSatisfy({ $0.isFinite }) else { return false }
        // With no logins nothing starts selected, so the row doesn't suggest Enter opens settings.
        if self.logins.map(\.id) != logins.map(\.id) || self.emails.map(\.id) != emails.map(\.id) || self.codes != codes ||
            (logins.isEmpty && !isVisible) {
            selected = logins.isEmpty && emails.isEmpty && codes.isEmpty ? -1 : 0
        }
        self.logins = logins
        self.emails = emails
        self.codes = codes
        self.pageHost = pageHost
        let factor = dpr / window.backingScaleFactor
        guard CGRect(x: 0, y: 0, width: view.bounds.width / factor, height: view.bounds.height / factor).intersects(rect) else {
            return false
        }
        let field = CGRect(x: rect.minX * factor, y: view.isFlipped ? rect.maxY * factor : view.bounds.height - rect.maxY * factor,
                           width: rect.width * factor, height: 0)
        let screen = window.convertToScreen(view.convert(field, to: nil))
        let width: CGFloat = max(240, min(360, rect.width * factor))
        let height = Metrics.panelHeight(for: logins, emails: emails, codes: codes, pageHost: pageHost)
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let background = NSVisualEffectView()
            background.material = .menu
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 10
            background.layer?.masksToBounds = true
            let hostingView = NSHostingView(rootView: MistPasswordDropdownView(model: self))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: background.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
            ])
            panel.contentView = background
            self.panel = panel
        }
        guard let panel else { return false }
        let bounds = window.screen?.visibleFrame ?? window.frame
        var origin = NSPoint(x: min(max(screen.minX, bounds.minX), bounds.maxX - width), y: screen.minY - height - 3)
        if origin.y < bounds.minY { origin.y = min(bounds.maxY - height, screen.minY + rect.height * factor + 3) }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.invalidateShadow()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        return true
    }

    func key(_ key: String) {
        let count = itemCount + (codes.isEmpty ? 1 : 0)
        switch key {
        case "ArrowDown": selected = (selected + 1) % count
        case "ArrowUp": selected = (selected + count - 1) % count
        case "Enter":
            guard selected >= 0 else { return }
            if !codes.isEmpty {
                if codes.indices.contains(selected) { choose?(.code(codes[selected])) }
                return
            }
            if selected < logins.count { choose?(.login(logins[selected])) }
            else if selected < itemCount { choose?(.email(emails[selected - logins.count])) }
            else { choose?(.manage) }
        default: break
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel = nil
        logins = []
        emails = []
        codes = []
        choose = nil
    }
}

private struct MistPasswordDropdownView: View {
    @ObservedObject var model: MistPasswordDropdown

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.codes.enumerated()), id: \.element.id) { index, code in
                        Button { model.choose?(.code(code)) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "envelope.open")
                                    .font(.system(size: 12))
                                    .foregroundStyle(model.selected == index ? Color.white : Color.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: code.code)
                                        .font(.system(size: 13)).monospacedDigit()
                                        .foregroundStyle(model.selected == index ? Color.white : Color.primary)
                                    Text(verbatim: code.sender)
                                        .font(.system(size: 11))
                                        .foregroundStyle(model.selected == index ? Color.white.opacity(0.8) : Color.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Metrics.twoLineRow)
                            .padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(model.selected == index ? Color.accentColor : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { if $0 { model.selected = index } }
                            .id(index)
                    }
                    if model.codes.isEmpty {
                        ForEach(Array(model.logins.enumerated()), id: \.element.id) { index, login in
                            Button { model.choose?(.login(login)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "key.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(model.selected == index ? Color.white : Color.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: login.username)
                                            .font(.system(size: 13))
                                            .foregroundStyle(model.selected == index ? Color.white : Color.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if login.host != model.pageHost {
                                            Text(verbatim: login.host)
                                                .font(.system(size: 11))
                                                .foregroundStyle(model.selected == index ? Color.white.opacity(0.8) : Color.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Metrics.rowHeight(for: login, pageHost: model.pageHost))
                                .padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(model.selected == index ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .onHover { if $0 { model.selected = index } }
                                .id(index)
                        }
                        if !model.logins.isEmpty && !model.emails.isEmpty {
                            Divider()
                                .frame(height: 1)
                                .padding(.vertical, (Metrics.separator - 1) / 2)
                                .padding(.horizontal, 8)
                        }
                        ForEach(Array(model.emails.enumerated()), id: \.element.id) { offset, email in
                            let index = model.logins.count + offset
                            Button { model.choose?(.email(email)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "envelope")
                                        .font(.system(size: 12))
                                        .foregroundStyle(model.selected == index ? Color.white : Color.secondary)
                                        .frame(width: 16)
                                    Text(verbatim: email.address)
                                        .font(.system(size: 13))
                                        .foregroundStyle(model.selected == index ? Color.white : Color.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Metrics.oneLineRow)
                                .padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(model.selected == index ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .onHover { if $0 { model.selected = index } }
                                .id(index)
                        }
                        if model.itemCount == 0 {
                            Text(MistPasswordStrings.dropdownEmpty)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Metrics.oneLineRow)
                                .padding(.horizontal, 8)
                        }
                        Divider()
                            .frame(height: 1)
                            .padding(.vertical, (Metrics.separator - 1) / 2)
                            .padding(.horizontal, 8)
                        Button { model.choose?(.manage) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 12))
                                    .foregroundStyle(model.selected == model.itemCount ? Color.white : Color.secondary)
                                    .frame(width: 16)
                                Text(MistPasswordStrings.manage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(model.selected == model.itemCount ? Color.white : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Metrics.oneLineRow)
                                .padding(.horizontal, 8)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(model.selected == model.itemCount ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { if $0 { model.selected = model.itemCount } }
                            .id(model.itemCount)
                    }
                }
            }.onChange(of: model.selected) { _, value in proxy.scrollTo(value) }
        }
        .padding(Metrics.inset)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
