import AppKit
import Combine
import SwiftUI

final class DrifterHomeViewController: NSViewController, MistAppPage {
    let model: DrifterHomeModel
    let composer = AgentChatComposer()
    private var defaultsSubscription: AnyCancellable?

    init(store: AgentChatStore? = nil) {
        model = DrifterHomeModel(store: store ?? .shared)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = AgentChatBackgroundView()
        composer.configureLaunch(saved: DrifterLaunchSettings())
        composer.onClearWithoutChat = {}
        composer.onLaunch = { [weak self] in self?.launch(text: $0, attachments: $1, mentions: $2) ?? false }
        composer.onLaunchDraftChange = { DrifterHomeModel.draft = $0 }
        composer.applyLaunchDraft(DrifterHomeModel.draft)
        composer.browserLaunchRow?.refreshModels()
        let hosting = MistKitHostingView(rootView: DrifterHomeView(model: model, composer: composer))
        hosting.sizingOptions = []
        view.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func show(_ address: MistAppAddress, tab: Tab, state: BrowserState) {
        model.state = state
        model.tabId = tab.guid
        composer.editor.mentionTabs = { [weak state, weak tab] in state?.tabs.filter { $0.guid != tab?.guid } ?? [] }
        composer.editor.mentionGroups = { [weak state] in state?.agentMentionGroups ?? [] }
        composer.editor.currentTab = { [weak state] in state?.lastActiveWebTab }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.pageWillShow()
        composer.applyLaunchDraft(DrifterHomeModel.draft)
        reloadSettings()
        defaultsSubscription = NotificationCenter.default.publisher(for: .drifterLaunchSettingsDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reloadSettings() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.appear()
        focusContent()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.disappear()
        model.pageDidHide()
        defaultsSubscription = nil
    }

    private func reloadSettings() {
        composer.browserLaunchRow?.settings.reloadSaved()
        composer.browserLaunchRow?.reload()
    }

    func focusContent() {
        model.focusSearch = false
        view.window?.makeFirstResponder(composer.editor.textView)
    }

    func performPageCommand(_ command: CommandWrapper) -> Bool {
        guard command == .IDC_FIND else { return false }
        model.focusSearch = true
        return true
    }

    private func launch(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention]) -> Bool {
        guard let state = model.state, !state.isIncognito, !state.isAgentSpace,
              let row = composer.browserLaunchRow else { return false }
        do {
            let chat = try model.store.launchBrowserChat(prompt: text, attachments: attachments, mentions: mentions,
                                                       config: row.settings.config, in: state, tabId: -1)
            let url = model.store.route.placeholderURL(for: chat.id).absoluteString
            model.store.bindNextTab(chat.id, in: state, url: url)
            state.createTab(url, focusAfterCreate: true)
            DrifterHomeModel.draft = AgentComposerDraft()
            row.settings.resetToSaved()
            return true
        } catch {
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
            return false
        }
    }
}
