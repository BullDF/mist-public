import Combine
import Foundation

/// Owns one restricted CLI and the capability issued solely for this chat.
@MainActor
final class DrifterSession {
    let settings: DrifterSettings
    private(set) var engine: (any AgentChatSession)?
    private let conversation: AgentConversation
    private let invalidate: () -> Void
    private var startup: Task<Void, Never>?
    private var statusSubscription: AnyCancellable?
    private var queueSubscription: AnyCancellable?
    let backgroundTasks: DrifterBackgroundTasks?
    var onWake: ((AgentQueuedMessage) async -> Bool)?
    private var closed = false
    private var skills: DrifterSkills?
    /// What the agent was last told about skills; a later change rides the next message (`DrifterSkills.agentText`).
    private var announcedSkills: [DrifterSkill]?
    private let repoSkills = DrifterRepoSkills()
    private let request: DrifterLaunchRequest
    var resumeId: String? { engine.map { $0.resumeId } ?? request.resume?.sessionId }
    var windowId: Int { request.windowId }

    /// A restart passes the chat's existing settings, which its views stay bound to.
    init(request: DrifterLaunchRequest, conversation: AgentConversation, folder: URL, tasksFolder: URL,
         resources: URL, bundleId: String, capability: String, settings: DrifterSettings? = nil,
         bindProcess: @escaping (Int32) -> Void, invalidate: @escaping () -> Void,
         environment: @escaping @Sendable () async -> ClaudeCodeEnvironment = { await ClaudeCodeEnvironment.shared.value }) {
        self.conversation = conversation; self.invalidate = invalidate; self.request = request
        backgroundTasks = request.config.engine != .claude ? DrifterBackgroundTasks(folder: folder, outputFolder: tasksFolder) : nil
        if let resume = request.resume { conversation.update(items: resume.items, status: .starting) }
        self.settings = settings ?? DrifterSettings(config: request.config, running: true)
        self.settings.isEnabled = false
        backgroundTasks?.onChange = { [weak conversation] in conversation?.updateDrifterTasks($0) }
        backgroundTasks?.onEnded = { [weak self] id, summary, status in
            (self?.engine as? any DrifterBackgroundTaskSession)?.backgroundTaskEnded(taskId: id, summary: summary, status: status)
        }
        backgroundTasks?.onWake = { [weak self] message in await self?.onWake?(message) ?? false }
        backgroundTasks?.isQueued = { [weak conversation] id in conversation?.queue.contains { $0.id == id } == true }
        if let backgroundTasks {
            conversation.onStopTask = { [weak backgroundTasks] id in backgroundTasks?.stop(id) }
            queueSubscription = conversation.$queue.map { Set($0.map(\.id)) }.removeDuplicates().sink { [weak backgroundTasks] ids in
                backgroundTasks?.queueChanged(ids)
            }
        }
        conversation.onClose = { [weak self] in self?.close() }
        self.settings.onChange = { [weak self] config in self?.apply(config) }
        // Every streamed update republishes the status, and each isEnabled write rebuilds the composer's launch row.
        statusSubscription = conversation.$status.removeDuplicates().sink { [weak self] status in
            guard let self else { return }
            switch status {
            case .starting: self.settings.isEnabled = false
            case .ended, .failed:
                self.settings.isEnabled = false; self.backgroundTasks?.stopAll(immediately: false); self.invalidate()
            default: self.settings.isEnabled = true
            }
        }
        startup = Task { [weak self] in
            let captured = await environment()
            guard let self, !self.closed, !Task.isCancelled else { return }
            await self.settings.refreshModels()
            guard !self.closed, !Task.isCancelled else { return }
            let home: DrifterHome
            do {
                #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
                let appData = AgentChatRoute.current.directory.deletingLastPathComponent().deletingLastPathComponent()
                #else
                let appData = folder.deletingLastPathComponent().deletingLastPathComponent()
                #endif
                home = try DrifterHome.resolve(home: FileManager.default.homeDirectoryForCurrentUser, bundleId: bundleId, appData: appData)
            } catch { self.fail(error.localizedDescription); return }
            let memory = DrifterMemory(home: home)
            let skills = DrifterSkills(folder: home.skills, repository: home.isRepository ? home.folder : nil,
                repoFolders: conversation.skillFolders.filter { $0.lastPathComponent == "skills" && $0.deletingLastPathComponent().lastPathComponent == ".claude" })
            self.skills = skills
            self.announcedSkills = skills.scan()
            self.conversation.memoryFolders = [memory.folder]
            self.conversation.skillFolders = skills.repoFolders + [skills.folder]
            var request = DrifterLaunchRequest(prompt: request.prompt, attachments: request.attachments,
                config: self.settings.config, windowId: request.windowId, mentions: request.mentions, sender: request.sender, parent: request.parent, slackThread: request.slackThread, chatId: conversation.id, resume: request.resume, memory: memory, skills: skills)
            request.home = home
            if bundleId == "com.bulldf.mist", home.isRepository, request.config.engine != .codex {
                let userHome = FileManager.default.homeDirectoryForCurrentUser
                let file: URL
                if request.config.engine == .gemini { file = userHome.appendingPathComponent(".gemini/GEMINI.md") }
                else {
                    let config = captured.variables["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        ?? userHome.appendingPathComponent(".claude")
                    file = config.appendingPathComponent("CLAUDE.md")
                }
                request.globalInstructions = await Task.detached(priority: .utility) {
                    DrifterInstructionIncludes.expand(file, home: userHome)
                }.value
            }
            guard let node = ClaudeCodeEnvironment.findExecutable(name: "node", environment: captured.variables,
                home: FileManager.default.homeDirectoryForCurrentUser) else {
                self.fail(NSLocalizedString("browser.agent.nodeMissing", value: "Node.js wasn't found. Install Node.js 22 or newer, then try again.", comment: "Browser Agent - Node runtime required"))
                return
            }
            let server = DrifterLaunchRequest.server(node: node, resources: resources, bundleId: bundleId,
                windowId: request.windowId, capability: capability)
            // Browser agents use subscription credentials, never inherited API keys.
            let variables = ClaudeCodeEnvironment.subscriptionVariables(captured.variables)
            self.backgroundTasks?.environment = request.config.engine == .gemini ? GeminiEnvironment.sanitized(variables) : variables
            let environment: @Sendable () async -> ClaudeCodeEnvironment = {
                ClaudeCodeEnvironment(variables: variables, executable: captured.executable)
            }
            if bundleId == "com.bulldf.mist", request.config.engine == .claude {
                let connectors = await ClaudeCodeConnectorCatalog.shared.load(environment: await environment())
                guard !self.closed, !Task.isCancelled else { return }
                #if MIST_CLAUDE_CODE_HOSTLESS_TESTS
                let mistSlackConfigured = false
                #else
                let mistSlackConfigured = MistSlackService.shared.isConfigured
                #endif
                request.cliServers = .init(userServers: DrifterCLIServers.userServers(environment: captured.variables),
                    connectors: DrifterCLIServers.connectors(connectors, mistSlackConfigured: mistSlackConfigured))
            }
            request.inheritsCLIServers = bundleId == "com.bulldf.mist"
            let engine: any AgentChatSession
            switch request.config.engine {
            case .claude:
                #if MIST_CLAUDE_CODE_HOSTLESS_TESTS
                let archiver: ClaudeCodeRemoteControlArchiver? = nil
                #else
                let archiver: ClaudeCodeRemoteControlArchiver? = .shared
                #endif
                engine = ClaudeCodeSession(request: request.claude(folder: folder, server: server), conversation: conversation, environment: environment, archiver: archiver)
            case .codex:
                let codex = CodexSession(request: request.codex(folder: folder, server: server), conversation: conversation, environment: environment)
                codex.allowsFileChange = { memory.allowsFileChanges($0, cwd: folder) || skills.allowsFileChanges($0, cwd: folder) }
                engine = codex
            case .gemini:
                let cliHome = tasksFolder.deletingLastPathComponent().appendingPathComponent("Gemini", isDirectory: true)
                let preload = resources.appendingPathComponent("gemini-preload.mjs")
                let gemini = GeminiSession(request: request.gemini(folder: folder, server: server, cliHome: cliHome, preload: preload),
                                           conversation: conversation, environment: environment)
                gemini.allowsFileChange = { memory.allowsFileChanges($0, cwd: folder) || skills.allowsFileChanges($0, cwd: folder) }
                engine = gemini
            }
            self.engine = engine
            engine.agentTextTransform = { [weak self] text in
                guard let self, let skills = self.skills else { return text }
                return skills.agentText(text, announced: &self.announcedSkills)
            }
            engine.onToolPaths = { [weak self] paths in
                guard let self else { return }
                Task {
                    let folders = await self.repoSkills.detect(paths, cwd: folder, home: home.folder)
                    guard !self.closed, !folders.isEmpty else { return }
                    var seen = Set<String>()
                    let repos = (folders + (self.skills?.repoFolders ?? [])).filter { seen.insert($0.path).inserted }
                    guard repos != self.skills?.repoFolders else { return }
                    self.skills?.repoFolders = repos
                    self.conversation.skillFolders = repos + [home.skills]
                }
            }
            engine.onStarted = bindProcess
            engine.onEnded = invalidate
            engine.automaticallyAllows = { [weak self] tool, interaction in
                self?.settings.config.confirmation.automaticallyAllows(tool: tool, requiresInteraction: interaction) == true
            }
            conversation.onClose = { [weak self] in self?.close() }
        }
    }

    private func apply(_ config: DrifterConfig) {
        if let claude = engine as? ClaudeCodeSession {
            if let model = ClaudeCodeModel(rawValue: config.model), claude.settings.config.model != model {
                claude.settings.change(.model(model))
            }
            if let effort = ClaudeCodeEffort(rawValue: config.effort), claude.settings.config.effort != effort {
                claude.settings.change(.effort(effort))
            }
        } else if let codex = engine as? CodexSession {
            codex.model = config.model; codex.effort = config.effort
        } else if let gemini = engine as? GeminiSession {
            gemini.model = config.model; gemini.effort = config.effort
        }
        engine?.approvePendingBrowserTools()
    }

    private func fail(_ message: String) {
        invalidate()
        conversation.update(items: conversation.items + [.init(id: UUID().uuidString, kind: .notice(text: AgentChatStrings.failureNotice(message), level: .error))], status: .failed(message))
    }

    func close() {
        guard !closed else { return }
        closed = true; startup?.cancel(); backgroundTasks?.stopAll(immediately: false); invalidate(); engine?.close()
    }
    func terminateNow() {
        closed = true; startup?.cancel(); backgroundTasks?.stopAll(immediately: true); invalidate(); engine?.terminateNow()
    }
    deinit { startup?.cancel(); invalidate() }
}
