import AppKit
import Combine

@MainActor final class MistAppPlaceholders {
    static let shared = MistAppPlaceholders()
    private var observers = Set<AnyCancellable>()
    private var written: [URL: String] = [:]
    private var icons: [String: String] = [:]

    var background: String {
        let manager = ThemeManager.shared
        let color = manager.currentTheme.color(for: .windowBackground, appearance: manager.currentAppearance).usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        return String(format: "#%02x%02x%02x", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    func iconPNGBase64(_ asset: String) -> String? {
        if let cached = icons[asset] { return cached }
        let icon = NSImage(named: asset)?.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }?.base64EncodedString()
        icons[asset] = icon
        return icon
    }

    func start() {
        writePages()
        guard observers.isEmpty else { return }
        for name in [Notification.Name.themeDidChange, .appearanceDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.writePages() }.store(in: &observers)
        }
    }

    private func writePages() {
        let route = MistAppRoute.current
        for app in MistApps.all {
            let icon = app.placeholderIconAsset.flatMap(iconPNGBase64)
            let html = MistAppPlaceholder.html(title: app.title(nil), background: background, iconPNGBase64: icon, app: app.id)
            var urls = [route.url(app.id)]
            if let legacy = route.legacyURL(app.id), FileManager.default.fileExists(atPath: legacy.path) { urls.append(legacy) }
            for url in urls {
                guard written[url] != html else { continue }
                if (try? String(contentsOf: url, encoding: .utf8)) == html { written[url] = html; continue }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    written[url] = html
                } catch { AppLogError("[MistApps] Could not write placeholder: \(error)") }
            }
        }
        AgentChatStore.shared.rewriteLivePlaceholders()
    }
}
