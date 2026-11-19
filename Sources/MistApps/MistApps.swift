import AppKit
import Combine

extension MistAppRoute {
    static var current: MistAppRoute {
        MistAppRoute(baseDirectory: URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true))
    }
}

@MainActor protocol MistApp {
    var id: MistAppID { get }
    var keywords: [String] { get }
    var openCommand: CommandWrapper { get }
    func icon(_ instance: UUID?) -> MistAppIcon
    func addressIcon(_ instance: UUID?) -> MistAppIcon
    func title(_ instance: UUID?) -> String
    func addressTitle(_ instance: UUID?) -> String?
    var placeholderIconAsset: String? { get }
    var badge: AnyPublisher<Int, Never>? { get }
    func makePage(_ address: MistAppAddress) -> NSViewController & MistAppPage
}

@MainActor protocol MistAppPage: NSViewController {
    func show(_ address: MistAppAddress, tab: Tab, state: BrowserState)
    func focusContent()
    func performPageCommand(_ command: CommandWrapper) -> Bool
    var pageZoom: CGFloat? { get }
}

extension MistAppPage {
    func performPageCommand(_ command: CommandWrapper) -> Bool { false }
    var pageZoom: CGFloat? { nil }
}

enum MistApps {
    @MainActor static let all: [any MistApp] = [ClipboardApp(), DrifterApp(), MailApp()]
    @MainActor static func app(_ id: MistAppID) -> (any MistApp)? { all.first { $0.id == id } }
    static func address(_ url: String?) -> MistAppAddress? { MistAppRoute.current.resolve(url) }
}

extension Tab {
    var appAddress: MistAppAddress? {
        guard SpaceSessionControllersManager.shared.getBrowserState(for: windowId)?.isIncognito != true else { return nil }
        return MistApps.address(url)
    }
}
