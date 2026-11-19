import AppKit
import Combine

@MainActor struct DrifterApp: MistApp {
    private let injectedStore: AgentChatStore?
    private var store: AgentChatStore { injectedStore ?? .shared }
    init(store: AgentChatStore? = nil) { injectedStore = store }
    let id = MistAppID.drifter
    let keywords = ["agent", "chat"]
    let openCommand = CommandWrapper.PHI_OPEN_DRIFTER
    static let logo = "drifter-logo"
    let placeholderIconAsset: String? = DrifterApp.logo
    var badge: AnyPublisher<Int, Never>? { nil }
    func icon(_ instance: UUID?) -> MistAppIcon {
        guard let instance else { return addressIcon(nil) }
        let icon = AgentChatIcon.resolve(engine: store.agent(for: instance))
        return MistAppIcon(asset: icon.rawValue, isTemplate: icon.isTemplate, scale: Double(icon.scale))
    }
    func addressIcon(_ instance: UUID?) -> MistAppIcon { MistAppIcon(asset: Self.logo, isTemplate: false) }
    func title(_ instance: UUID?) -> String { addressTitle(instance) ?? id.name }
    func addressTitle(_ instance: UUID?) -> String? {
        guard let instance else { return nil }
        return store.conversation(for: instance)?.title ?? store.route.storedTitle(for: instance)
    }
    func makePage(_ address: MistAppAddress) -> NSViewController & MistAppPage {
        if address.instance == nil { return DrifterHomeViewController(store: store) }
        return AgentChatViewController(store: store)
    }
}
