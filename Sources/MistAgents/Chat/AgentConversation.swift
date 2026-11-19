import Foundation
import Combine

struct AgentComposerDraft: Equatable {
    var text = ""
    var mentions: [AgentTabMention] = []
    var attachments: [AgentAttachment] = []

    /// Whether the draft is nothing but one mention of a tab in `tabIds`, as a Chat panel inserts for its host tab.
    func isOnlyMention(of tabIds: Set<Int>) -> Bool {
        guard attachments.isEmpty, mentions.count == 1, let mention = mentions.first, !mention.isGroup, tabIds.contains(mention.tabId),
              NSMaxRange(mention.range) <= (text as NSString).length else { return false }
        return (text as NSString).replacingCharacters(in: mention.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepending(_ message: AgentQueuedMessage) -> AgentComposerDraft {
        let prefix = message.draftText + (text.isEmpty || message.draftText.isEmpty ? "" : "\n")
        let messageMentions = message.mentions.map { mention in
            var mention = mention
            mention.range.location += message.draftText.utf16.count - message.text.utf16.count
            return mention
        }
        let shifted = mentions.map { mention in
            var mention = mention
            mention.range.location += prefix.utf16.count
            return mention
        }
        return .init(text: prefix + text, mentions: messageMentions + shifted,
                     attachments: (message.attachments + attachments).cappingImages(at: 10))
    }

    static func mapSelection(_ range: NSRange, from old: String, to new: String) -> NSRange {
        let oldUnits = Array(old.utf16), newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < min(oldUnits.count, newUnits.count), oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldUnits.count - prefix, newUnits.count - prefix),
              oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] { suffix += 1 }
        let oldEnd = oldUnits.count - suffix, newEnd = newUnits.count - suffix
        func map(_ position: Int) -> Int {
            // A caret at the end follows text the other composer appends.
            if position == oldUnits.count { return newUnits.count }
            if position <= prefix { return position }
            if position >= oldEnd { return position + newEnd - oldEnd }
            return newEnd
        }
        let start = map(range.location), end = map(NSMaxRange(range))
        return NSRange(location: start, length: end - start)
    }
}

/// What an agent asked Johnny to do himself with `hand_off`, such as signing in, until he presses Done.
struct AgentHandOff: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var message: String
    /// The title of the tab he should use, when the agent named one.
    var tab: String?
}

@MainActor
final class AgentConversation: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    var autoTitle: String
    var manualTitle: String?
    @Published var pendingSessionTitle: String?
    var onSessionTitleSent: (() -> Void)?
    @Published private(set) var items: [AgentChatItem] = []
    @Published private(set) var markers: [AgentChatMarker] = []
    /// The card above the composer while the agent waits for Johnny; Done or any message he sends closes it.
    @Published private(set) var handOff: AgentHandOff?
    @Published private(set) var status: AgentConversationStatus = .starting
    @Published private(set) var backgroundTasks: [AgentBackgroundTask] = []
    private var engineTasks: [AgentBackgroundTask] = []
    private var drifterTasks: [AgentBackgroundTask] = []
    @Published private(set) var queue: [AgentQueuedMessage] = []
    @Published private(set) var queuePaused = false
    private(set) var draft = AgentComposerDraft() {
        didSet { if draft.text != oldValue.text { onDraftChange?() } }
    }
    let draftChanges = PassthroughSubject<(draft: AgentComposerDraft, source: ObjectIdentifier?), Never>()
    var onDraftChange: (() -> Void)?
    @Published private(set) var turnStartedAt = Date()
    @Published private(set) var outputTokens: Int?
    @Published var contextTokens: Int?
    @Published var contextWindowSize: Int?
    @Published var memoryFolders: [URL] = []
    @Published var skillFolders: [URL] = []
    var usesClaudePresentation = true
    @Published private(set) var workingWord = Int.random(in: 0..<12)

    /// No message sent yet: a chat /clear started, still waiting for its first message.
    var isNew: Bool { status == .dormant && items.isEmpty }

    var showsWorkingIndicator: Bool { status == .starting || status == .running }

    var onSend: ((String, [AgentAttachment], [AgentTabMention]) -> Void)?
    /// Launches a failed or restored chat's agent, then sends the message.
    var onRestart: ((AgentQueuedMessage) -> Void)?
    var onDeliver: ((AgentQueuedMessage) -> Bool)?
    /// A restart's message until the agent takes it.
    private(set) var unsent: AgentQueuedMessage?
    /// The user sent a message, so the transcript shows its end.
    let messageSent = PassthroughSubject<Void, Never>()
    var onQueue: ((String, [AgentAttachment], [AgentTabMention]) -> Void)?
    var onSendQueuedNow: ((String) -> Void)?
    var onRemoveQueued: ((String) -> Void)?
    var onPermissionDecision: ((String, AgentPermissionResponse) -> Void)?
    var onStop: (() -> Void)?
    var onStopTask: ((String) -> Void)?
    var onBackgroundTool: ((String) -> Void)?
    var onMCPServerAction: ((String, ClaudeCodeMCPServerAction) -> Void)?
    var onClose: (() -> Void)?
    var onClear: (() -> Void)?
    var onOpenAttachment: ((AgentAttachment) -> Void)?
    var attachmentsFolder: URL?

    func importAttachments(_ attachments: [AgentAttachment]) throws -> [AgentAttachment] {
        guard let attachmentsFolder else { return attachments }
        return try attachments.imported(into: attachmentsFolder)
    }
    var onOpenLink: ((URL) -> Void)?
    var onTitleGenerated: ((String) -> Void)?

    init(id: UUID = UUID(), firstPrompt: String = "") {
        self.id = id
        let title = Self.defaultTitle(firstPrompt)
        self.title = title
        autoTitle = title
    }

    func setDraft(_ draft: AgentComposerDraft, from source: AnyObject? = nil) {
        guard draft != self.draft else { return }
        self.draft = draft
        draftChanges.send((draft, source.map(ObjectIdentifier.init)))
    }

    @discardableResult
    func toggleMarker(itemId: String, defaultName: String) -> AgentChatMarker? {
        guard items.contains(where: { $0.id == itemId && $0.markerText != nil }) else { return nil }
        var next = markers
        let marker = AgentChatMarkers.toggle(&next, itemId: itemId, defaultName: defaultName, itemIDs: items.map(\.id))
        if next != markers { markers = next }
        return marker
    }

    func renameMarker(itemId: String, to name: String) {
        var next = markers
        AgentChatMarkers.rename(&next, itemId: itemId, to: name)
        if next != markers { markers = next }
    }

    func removeMarker(itemId: String) {
        guard markers.contains(where: { $0.id == itemId }) else { return }
        markers.removeAll { $0.id == itemId }
    }

    func applyGeneratedMarkerName(itemId: String, name: String, replacing defaultName: String) {
        var next = markers
        AgentChatMarkers.applyGeneratedName(&next, itemId: itemId, name: name, replacing: defaultName)
        if next != markers { markers = next }
    }

    func setHandOff(_ handOff: AgentHandOff?) {
        if handOff != self.handOff { self.handOff = handOff }
    }

    /// A follow-up from Johnny refuses plain action cards after his message has been queued.
    func refusePendingPermissions() {
        let requestIDs = items.compactMap { item -> String? in
            guard case let .permissionRequest(request) = item.kind, request.status == .pending,
                  request.questions.isEmpty, request.toolName != "ExitPlanMode" else { return nil }
            return request.requestId
        }
        for id in requestIDs { onPermissionDecision?(id, .deny(message: nil)) }
    }

    /// Johnny pressed Done in Mist: his "Done." wakes the agent. (A Done pressed in Slack arrives as his Slack message.)
    func finishHandOff() {
        guard handOff != nil else { return }
        handOff = nil
        sendFromUser("Done.")
    }

    /// Sends text as Johnny's message, as the composer would: queued while the agent works, launching a failed or
    /// restored chat, else sent at once.
    func sendFromUser(_ text: String) {
        messageSent.send()
        switch status {
        case .starting, .running, .awaitingPermission: onQueue?(text, [], [])
        case .idle: onSend?(text, [], [])
        default: if status.launchesOnSend { restart(text: text, attachments: [], mentions: []) }
        }
    }

    func restoreMarkers(_ saved: [AgentChatMarker]) {
        let next = AgentChatMarkers.ordered(saved, itemIDs: items.filter { $0.markerText != nil }.map(\.id))
        if next != markers { markers = next }
    }

    func update(items: [AgentChatItem], status: AgentConversationStatus, backgroundTasks: [AgentBackgroundTask] = [],
                turnStartedAt: Date? = nil, outputTokens: Int? = nil) {
        if let turnStartedAt, turnStartedAt != self.turnStartedAt {
            self.turnStartedAt = turnStartedAt
            workingWord = Int.random(in: 0..<12)
        } else if status == .running && self.status == .idle || status == .starting && self.status != .starting {
            self.turnStartedAt = Date()
            workingWord = Int.random(in: 0..<12)
        }
        self.outputTokens = outputTokens
        self.items = items
        self.status = status
        switch status {
        case .ended, .failed:
            engineTasks = []; drifterTasks = []
            updateQueue(AgentMessageQueue())
        default: engineTasks = backgroundTasks
        }
        publishTasks()
        if status == .running || status == .awaitingPermission { unsent = nil }
        else if case .failed = status { returnUnsent() }
        if title.isEmpty, let prompt = items.compactMap({ item -> String? in
            if case let .userMessage(text, _) = item.kind { return text }
            return nil
        }).first {
            title = Self.defaultTitle(prompt)
            autoTitle = title
        }
    }

    func updateDrifterTasks(_ tasks: [AgentBackgroundTask]) {
        drifterTasks = tasks
        publishTasks()
    }

    private func publishTasks() {
        let merged = engineTasks + drifterTasks
        if backgroundTasks != merged { backgroundTasks = merged }
    }

    /// Launches a failed or restored chat with the message, which comes back if the launch fails before the agent takes it.
    func restart(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention]) {
        unsent = AgentQueuedMessage(text: text, attachments: attachments, mentions: mentions)
        onRestart?(unsent!)
        if status.launchesOnSend { returnUnsent() }
    }

    private func returnUnsent() {
        guard let message = unsent else { return }
        unsent = nil
        setDraft(draft.prepending(message))
    }

    func deliver(_ message: AgentQueuedMessage) -> Bool {
        if status.launchesOnSend {
            unsent = message
            onRestart?(message)
            if status.launchesOnSend { unsent = nil; return false }
            return true
        }
        if status == .idle || status == .running || status == .awaitingPermission {
            return onDeliver?(message) ?? false
        }
        return false
    }

    func updateQueue(_ queue: AgentMessageQueue) {
        self.queue = queue.messages
        queuePaused = queue.paused
    }

    private static func defaultTitle(_ prompt: String) -> String {
        String((AgentCodeBlocks.firstTitleLine(in: prompt) ?? "").prefix(60))
    }
}
