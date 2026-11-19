import AppKit
import Combine

@MainActor struct MailApp: MistApp {
    let id = MistAppID.mail
    let keywords = ["email", "inbox"]
    let openCommand = CommandWrapper.PHI_OPEN_MAIL
    func icon(_ instance: UUID?) -> MistAppIcon { MistAppIcon(asset: "mail-favicon", isTemplate: true) }
    func addressIcon(_ instance: UUID?) -> MistAppIcon { icon(instance) }
    func title(_ instance: UUID?) -> String { id.name }
    func addressTitle(_ instance: UUID?) -> String? { nil }
    let placeholderIconAsset: String? = "mail-page-favicon"
    var badge: AnyPublisher<Int, Never>? {
        MistMailService.shared.$unreadCounts.map(\.unifiedInbox).removeDuplicates().eraseToAnyPublisher()
    }
    func makePage(_ address: MistAppAddress) -> NSViewController & MistAppPage { MailPageViewController() }
}
