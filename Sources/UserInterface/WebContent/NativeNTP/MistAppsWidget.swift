import AppKit
import Combine
import SwiftUI

/// The app tiles' hosting view: a kit hosting view, which sets the tiles' pointing hand itself (AppKit sends
/// `cursorUpdate` to the hosting view, never to a subview), and never takes focus from the composer.
final class MistAppsWidgetHostingView: MistKitHostingView {
    override var acceptsFirstResponder: Bool { false }
}

/// The New Tab Page's app tiles: one centered row of kit launcher tiles, every app in registry order.
struct MistAppsWidget: View {
    static let spacing: CGFloat = 12
    static var width: CGFloat {
        let count = CGFloat(MistApps.all.count)
        return count * MistLauncherTile.size.width + max(0, count - 1) * spacing
    }
    static let height = MistLauncherTile.size.height
    let apps: [any MistApp]
    let open: (MistAppID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(apps, id: \.id) { app in
                MistAppTile(app: app) { open(app.id) }
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: NSLocalizedString("browser.newTabPage.apps.accessibilityLabel", value: "Apps", comment: "New tab page - Accessibility label for the row of app tiles")))
    }
}

private struct MistAppTile: View {
    let app: any MistApp
    let open: () -> Void
    @State private var badge = 0

    var body: some View {
        MistLauncherTile(content: content, title: app.id.name, badge: MailUnreadPill.text(for: badge), action: open)
            .onReceive(app.badge ?? Empty<Int, Never>().eraseToAnyPublisher()) { badge = $0 }
    }

    private var content: MistIconTile.Content {
        if app.id == .drifter { return .logo(NSImage(named: DrifterApp.logo) ?? NSImage()) }
        return .glyph(NSImage(named: "\(app.id.rawValue)-tile") ?? NSImage())
    }
}
