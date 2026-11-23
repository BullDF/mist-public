import AppKit

extension DrifterScheduleStore {
    static let shared = DrifterScheduleStore(
        url: AgentChatStore.shared.route.directory.deletingLastPathComponent().appendingPathComponent("Schedules.json"))

    func cancelFromUI(_ id: String) {
        do { try cancel(id) }
        catch { AppLogInfo("[Drifter schedules] Could not cancel \(id): \(error.localizedDescription)") }
    }
}

@MainActor
final class DrifterScheduleRunner {
    static let shared = DrifterScheduleRunner()

    private let schedules = DrifterScheduleStore.shared
    private let chats = AgentChatStore.shared
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var wakingChats = Set<UUID>()

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Let app launch finish starting the agent transport before the first run.
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    private func check() {
        guard let window = AgentChatStore.externalChatWindow() else { return }
        let due: [DrifterSchedule]
        do {
            let now = Date()
            due = try Array(schedules.list().prefix { $0.nextRun <= now })
        } catch {
            AppLogInfo("[Drifter schedules] Could not read schedules: \(error.localizedDescription)")
            return
        }
        var wakes: [UUID: [DrifterSchedule]] = [:]
        for schedule in due {
            switch schedule.target {
            case .thisChat: wakes[schedule.owner, default: []].append(schedule)
            case let .newChat(config):
                guard let run = takeDue(schedule) else { continue }
                startChat(run, config: config, in: window.browserState)
            }
        }
        for (owner, batch) in wakes where wakingChats.insert(owner).inserted {
            Task { await wakeChat(owner, schedules: batch) }
        }
    }

    private func takeDue(_ schedule: DrifterSchedule) -> DrifterSchedule.Run? {
        do { return try schedules.takeDue(schedule.id) }
        catch {
            AppLogInfo("[Drifter schedules] Could not advance \(schedule.id): \(error.localizedDescription)")
            return nil
        }
    }

    private func sender(for run: DrifterSchedule.Run) -> AgentMessageSender {
        var sender = AgentMessageSender(id: run.schedule.id, title: run.schedule.title, kind: .schedule)
        sender.note = run.header(label: sender.label, timeZone: .current)
        return sender
    }

    private func startChat(_ run: DrifterSchedule.Run, config saved: DrifterConfig, in state: BrowserState) {
        var config = saved
        config.model = DrifterModel.offered(config.model, engine: config.engine)
        config.effort = DrifterModel.forSpawn(config, models: []).effort(config.effort)
        config.folder = DrifterHome.current.folder
        do {
            let chat = try chats.launchBrowserChat(prompt: run.schedule.prompt, attachments: [], mentions: [],
                config: config, in: state, tabId: -1, createBackgroundTab: true, sender: sender(for: run))
            chats.closeTabsWhenIdle([chat.id])
            chat.manualTitle = run.schedule.title
            try chats.updateTitle(run.schedule.title, for: chat.id)
            chats.saveRecord(chat.id)
        } catch {
            AppLogInfo("[Drifter schedules] Could not start chat for \(run.schedule.id): \(error.localizedDescription)")
        }
    }

    private func wakeChat(_ owner: UUID, schedules batch: [DrifterSchedule]) async {
        defer { wakingChats.remove(owner) }
        for schedule in batch {
            guard let window = AgentChatStore.externalChatWindow() else { return }
            guard let run = takeDue(schedule) else { continue }
            let (opened, createdTab) = await withCheckedContinuation { continuation in
                chats.openChatInBackground(owner, in: window.browserState) { opened, createdTab in
                    continuation.resume(returning: (opened, createdTab))
                }
            }
            guard opened else {
                AppLogInfo("[Drifter schedules] Could not reopen the chat for \(schedule.id)")
                continue
            }
            let message = AgentQueuedMessage(text: schedule.prompt, sender: sender(for: run))
            if !(await chats.deliverExternalMessage(message, to: owner)) {
                AppLogInfo("[Drifter schedules] Chat could not take the prompt for \(schedule.id)")
            }
            if createdTab { chats.closeTabsWhenIdle([owner]) }
        }
    }
}
