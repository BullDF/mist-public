import Combine
import Foundation
import SwiftUI

@MainActor final class DrifterHomeModel: ObservableObject {
    /// The home draft belongs to the process, never to a chat or a saved record.
    static var draft = AgentComposerDraft()

    let store: AgentChatStore
    weak var state: BrowserState?
    var tabId: Int = -1
    @Published private(set) var ongoing: [DrifterHomeChat] = []
    @Published private(set) var schedules: [DrifterSchedule] = []
    @Published private(set) var history: [AgentChatHistory.Chat] = []
    @Published var query = "" {
        didSet { if query != oldValue { historyLimit = DrifterHomeList.historyPageSize } }
    }
    @Published var historyLimit = DrifterHomeList.historyPageSize
    @Published var focusSearch = false

    private let historyReader: DrifterHomeHistoryReader
    private var rawHistory: [AgentChatHistory.Chat] = []
    private var historyGeneration: UInt64 = 0
    private var appeared = false
    /// The page shows the lists' current members, so a change to them animates: false until the first refresh and
    /// the first history load after the page appears, which replace whatever it showed before.
    private var ongoingShown = false
    private var historyShown = false
    private var observedIDs: Set<UUID>?
    private var excludedIDs: Set<UUID>?
    private var subscriptions = Set<AnyCancellable>()
    private var conversationSubscriptions = Set<AnyCancellable>()
    private let changes = PassthroughSubject<Void, Never>()

    init(store: AgentChatStore) {
        self.store = store
        historyReader = DrifterHomeHistoryReader(route: store.route)
    }

    var visibleHistory: (rows: [AgentChatHistory.Chat], hasMore: Bool) {
        DrifterHomeList.history(history, query: query, limit: historyLimit)
    }

    func appear() {
        disappear()
        appeared = true
        changes.throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        store.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.changes.send() }.store(in: &subscriptions)
        state?.$tabs.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.changes.send() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: DrifterScheduleStore.didChange, object: DrifterScheduleStore.shared)
            .sink { [weak self] _ in self?.refreshSchedules(animated: true) }.store(in: &subscriptions)
        refreshSchedules(animated: false)
        refresh()
    }

    private func refreshSchedules(animated: Bool) {
        let latest = (try? DrifterScheduleStore.shared.list()) ?? []
        guard schedules != latest else { return }
        MistMotion.changeList(animated: animated && schedules.map(\.id) != latest.map(\.id)) {
            schedules = latest
        }
    }

    func disappear() {
        appeared = false
        ongoingShown = false
        historyShown = false
        subscriptions.removeAll()
        conversationSubscriptions.removeAll()
        observedIDs = nil
        excludedIDs = nil
        historyGeneration &+= 1
    }

    private func refresh() {
        guard appeared else { return }
        let listed = store.agentChats()
        let ids = Set(listed)
        if observedIDs != ids {
            observedIDs = ids
            conversationSubscriptions.removeAll()
            // Empty open chats are observed too: their first message adds them to Ongoing.
            for id in listed {
                guard let chat = store.conversation(for: id) else { continue }
                Publishers.Merge5(chat.$status.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                                  chat.$title.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                                  chat.$items.map { _ in () }.eraseToAnyPublisher(),
                                  chat.$backgroundTasks.map(\.isEmpty).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                                  chat.$handOff.map { $0 == nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
                    .dropFirst(5).receive(on: DispatchQueue.main)
                    .sink { [weak self] in self?.changes.send() }.store(in: &conversationSubscriptions)
            }
        }
        let now = Date()
        let rows = listed.compactMap { id -> DrifterHomeChat? in
            guard !store.isEmpty(id), let entry = store.entry(for: id) else { return nil }
            let conversation = entry.conversation
            let working = [.starting, .running, .awaitingPermission].contains(conversation.status)
            let finished = working ? nil : conversation.items.reversed().lazy.compactMap { item -> Date? in
                if case let .turnEnd(_, finishedAt, _) = item.kind { return finishedAt }
                return nil
            }.first
            let modified = working || finished != nil ? nil :
                (try? FileManager.default.attributesOfItem(atPath: store.route.recordURL(for: id).path))?[.modificationDate] as? Date
            let time = working ? conversation.turnStartedAt : finished ?? modified ?? conversation.turnStartedAt
            return DrifterHomeChat(id: id, title: conversation.title,
                                  lastLine: AgentChatTranscriptText.lastLine(conversation.items),
                                  status: DrifterHomeStatus(conversation.status, hasBackgroundTasks: !conversation.backgroundTasks.isEmpty,
                                                            waitsForUser: conversation.handOff != nil),
                                  engine: entry.config.engine,
                                  time: time, sortDate: working ? now : time)
        }
        let snapshot = DrifterHomeList.ongoing(rows, parent: store.parent)
        let excluded = Set(rows.map(\.id))
        let reload = excludedIDs != excluded
        excludedIDs = excluded
        // A chat joining Ongoing leaves History in the same change; one leaving joins it when the reload lands. A chat
        // starting or finishing a turn moves, which slides it; streamed lines, titles and times never animate.
        let rearranged = DrifterHomeList.arrangement(snapshot) != DrifterHomeList.arrangement(ongoing)
        MistMotion.changeList(animated: ongoingShown && rearranged) {
            if ongoing != snapshot { ongoing = snapshot }
            updateHistoryTitles()
        }
        ongoingShown = true
        if reload { loadHistory(excluding: excluded) }
    }

    private func loadHistory(excluding ids: Set<UUID>) {
        historyGeneration &+= 1
        let generation = historyGeneration
        historyReader.load(excluding: ids) { [weak self] rows in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.appeared, self.historyGeneration == generation else { return }
                self.rawHistory = rows
                let rows = self.historyRows()
                MistMotion.changeList(animated: self.historyShown && Set(rows.map(\.id)) != Set(self.history.map(\.id))) {
                    if self.history != rows { self.history = rows }
                }
                self.historyShown = true
            }
        }
    }

    private func updateHistoryTitles() {
        let rows = historyRows()
        if history != rows { history = rows }
    }

    private func historyRows() -> [AgentChatHistory.Chat] {
        rawHistory.filter { excludedIDs?.contains($0.id) != true }.map { row in
            AgentChatHistory.Chat(id: row.id, title: store.conversation(for: row.id)?.title ?? row.title,
                                  lastLine: row.lastLine, engine: row.engine, lastActivity: row.lastActivity)
        }
    }

    func openChat(_ id: UUID) {
        guard let state, !state.isIncognito else { return }
        let route = store.route
        if let tab = state.tabs.first(where: { route.conversationId(for: $0.url) == id }) {
            if let wrapper = tab.webContentWrapper { wrapper.setAsActiveTab() }
            else { state.focusTabWithTabId(tab.guid) }
            return
        }
        for controller in SpaceSessionControllersManager.shared.getAllWindows() where controller.browserType == .normal {
            if let tab = controller.browserState.tabs.first(where: { route.conversationId(for: $0.url) == id }) {
                controller.selectTab(tab)
                return
            }
        }
        let url = route.placeholderURL(for: id).absoluteString
        if let entry = store.entry(for: id), entry.tabId < 0 { store.bindNextTab(id, in: state, url: url) }
        state.createTab(url, focusAfterCreate: true)
    }
}

/// The scanner's mutable cache is accessed only on this reader's serial queue. It never escapes the reader.
private final class DrifterHomeHistoryReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mist.DrifterHome.history", qos: .utility)
    private let scanner: AgentChatHistory

    init(route: AgentChatRoute) { scanner = AgentChatHistory(route: route) }

    func load(excluding ids: Set<UUID>, completion: @escaping @Sendable ([AgentChatHistory.Chat]) -> Void) {
        queue.async { [self] in completion(scanner.chats(excluding: ids)) }
    }
}
