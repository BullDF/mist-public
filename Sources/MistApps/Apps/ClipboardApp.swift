import AppKit
import Combine

@MainActor struct ClipboardApp: MistApp {
    let id = MistAppID.clipboard
    let keywords = ["paste"]
    let openCommand = CommandWrapper.PHI_OPEN_CLIPBOARD
    func icon(_ instance: UUID?) -> MistAppIcon { MistAppIcon(asset: "clipboard-favicon", isTemplate: true) }
    func addressIcon(_ instance: UUID?) -> MistAppIcon { icon(instance) }
    func title(_ instance: UUID?) -> String { id.name }
    func addressTitle(_ instance: UUID?) -> String? { nil }
    let placeholderIconAsset: String? = "clipboard-page-favicon"
    var badge: AnyPublisher<Int, Never>? { nil }
    func makePage(_ address: MistAppAddress) -> NSViewController & MistAppPage { ClipboardPageViewController() }
}
