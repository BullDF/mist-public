import AppKit
import Combine

/// Turns off Chromium's typed-history suggestions, which pop up over Mist's password
/// dropdown. The framework ships no Autofill settings page, so Mist sets the
/// AutofillAddressEnabled policy, which Chromium reads from the app's defaults domain
/// and which also gates those suggestions. It must run before Chromium launches.
final class MistChromiumAutofillPolicy: NSObject {
    @objc static func applyBeforeLaunch() {
        UserDefaults.standard.set(false, forKey: "AutofillAddressEnabled")
    }
}

/// Window-owned integration adapter. Each target serializes its commands because
/// AppDevToolsPageSession deliberately permits only one outstanding command.
@MainActor
final class MistPasswordTabManager {
    @MainActor private final class Entry {
        weak var tab: Tab?
        let target: String
        let session: AppDevToolsPageSession
        var tail: Task<Void, Never>?
        var wrapperObserver: AnyCancellable?
        var lastUsed = Date()
        var mainFrame = ""
        var contexts = Set<Int>()
        var origins: [Int: String] = [:]
        var revision = 0
        var focusRevision = 0
        var closed = false
        var pending: Pending?
        var identifier: Identifier?
        var expiry: Task<Void, Never>?

        init(tab: Tab, target: String, session: AppDevToolsPageSession) {
            self.tab = tab; self.target = target; self.session = session
        }

        func enqueue(_ work: @escaping @MainActor () async -> Void) {
            let previous = tail
            tail = Task { [weak self] in
                await previous?.value
                guard let self, !self.closed, !Task.isCancelled else { return }
                await work()
            }
        }

        func close() {
            closed = true
            tail?.cancel(); tail = nil
            expiry?.cancel(); expiry = nil; pending = nil; identifier = nil
            wrapperObserver = nil
            session.onEvent = nil
            session.close()
        }

        deinit { session.close() }
    }

    private struct Pending {
        let login: MistLogin
        let domain: String
        let context: Int
        let deadline: Date
    }

    private struct Identifier {
        let domain: String
        let username: String
        let expires: Date

        init(domain: String, username: String) {
            self.domain = domain
            self.username = username
            expires = Date().addingTimeInterval(5 * 60)
        }

        func username(for domain: String) -> String? {
            self.domain == domain && expires > Date() ? username : nil
        }
    }

    private struct Suggestion {
        let entry: Entry
        let context: Int
        let field: Int
        let domain: String
        let revision: Int
        let mode: String
        let kind: String
    }

    private struct CodeWatch {
        let message: [String: Any]
        let entry: Entry
        let context: Int
        let revision: Int
    }

    private final class WeakEntry {
        weak var value: Entry?
        init(_ value: Entry) { self.value = value }
    }
    // A weak resource budget, not a second browser state hierarchy.
    private static var live: [WeakEntry] = []
    private weak var browser: BrowserState?
    private var entries: [Int: Entry] = [:]
    private var opening = Set<Int>()
    private var subscriptions = Set<AnyCancellable>()
    private var focusedWrapper: AnyCancellable?
    private let dropdown = MistPasswordDropdown()
    private let prompt = MistPasswordSavePrompt()
    private var suggestion: Suggestion?
    private var codeWatch: CodeWatch?
    private var stopped = false

    init(browserState: BrowserState) {
        browser = browserState
        guard !browserState.isAgentSpace else { return }
        MistMailCodeSource.shared.newMail.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, let watch = self.codeWatch, self.active(watch.entry),
                  watch.entry.focusRevision == watch.revision, MistPasswordPreferences.autofill else { return }
            watch.entry.enqueue { [weak self] in
                guard let self, self.active(watch.entry), watch.entry.focusRevision == watch.revision,
                      MistPasswordPreferences.autofill else { return }
                await self.focus(watch.message, context: watch.context, revision: watch.revision, entry: watch.entry)
            }
        }.store(in: &subscriptions)
        browserState.$focusingTab.receive(on: DispatchQueue.main).sink { [weak self] tab in
            guard let self else { return }
            self.hide(); self.prompt.close()
            self.focusedWrapper = tab?.$webContentWrapper.receive(on: DispatchQueue.main).sink { [weak self, weak tab] _ in
                if let tab { self?.attach(tab) }
            }
            if let tab { self.attach(tab) }
        }.store(in: &subscriptions)
        browserState.$tabs.receive(on: DispatchQueue.main).sink { [weak self] tabs in
            guard let self else { return }
            for (id, entry) in self.entries where !tabs.contains(where: { $0 === entry.tab }) {
                self.remove(id)
            }
        }.store(in: &subscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let self else { return }
                if name == NSApplication.didResignActiveNotification || note.object as? NSWindow === self.browser?.windowController?.window {
                    self.hide()
                    if name == NSWindow.willCloseNotification { self.stop() }
                    if name == NSApplication.didResignActiveNotification { self.prompt.close() }
                }
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            if !MistPasswordPreferences.autofill { self?.hide() }
            if !MistPasswordPreferences.offerToSave {
                self?.prompt.close()
                for entry in self?.entries.values ?? [:].values { entry.pending = nil; entry.expiry?.cancel() }
            }
        }.store(in: &subscriptions)
    }

    static func domain(_ url: String) -> String {
        ChromiumLauncher.sharedInstance().bridge?.contentBlockingSiteExceptionDomain(forURL: url).lowercased() ?? ""
    }

    private func active(_ entry: Entry) -> Bool {
        !stopped && !entry.closed && browser?.isAgentSpace == false && browser?.focusingTab === entry.tab &&
            browser?.windowController?.window?.isKeyWindow == true && NSApp.isActive
    }

    private func attach(_ tab: Tab) {
        guard !stopped, browser?.isAgentSpace == false, browser?.focusingTab === tab,
              let target = tab.webContentWrapper?.devToolsTargetId, !target.isEmpty else { return }
        if let entry = entries[tab.guid] {
            if !entry.closed, entry.target == target { entry.lastUsed = Date(); return }
            remove(tab.guid)
        }
        guard opening.insert(tab.guid).inserted else { return }
        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { self.opening.remove(tab.guid) }
            guard let session = try? await AppDevToolsPageSession.open(targetId: target) else { return }
            guard !self.stopped, self.browser?.isAgentSpace == false,
                  tab.webContentWrapper?.devToolsTargetId == target,
                  self.browser?.tabs.contains(where: { $0 === tab }) == true else { session.close(); return }
            Self.live.removeAll { $0.value == nil || $0.value?.closed == true }
            if Self.live.count >= 20, let oldest = Self.live.compactMap(\.value).min(by: { $0.lastUsed < $1.lastUsed }) {
                oldest.close()
            }
            let entry = Entry(tab: tab, target: target, session: session)
            self.entries[tab.guid] = entry
            Self.live.append(WeakEntry(entry))
            session.onEvent = { [weak self, weak entry] method, params in
                guard let self, let entry, !entry.closed else { return }
                self.event(method, params: params, entry: entry)
            }
            entry.wrapperObserver = tab.$webContentWrapper.receive(on: DispatchQueue.main).sink { [weak self, weak entry] wrapper in
                guard let entry, wrapper?.devToolsTargetId != entry.target else { return }
                self?.remove(tab.guid)
                self?.attach(tab)
            }
            entry.enqueue { [weak self, weak entry] in
                guard let self, let entry else { return }
                do {
                    _ = try await session.command("Page.enable")
                    let tree = try await session.command("Page.getFrameTree")
                    guard let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any],
                          let frameID = frame["id"] as? String else { throw MistPasswordError.unavailable }
                    entry.mainFrame = frameID
                    _ = try await session.command("Runtime.enable")
                    _ = try await session.command("Runtime.addBinding", params: ["name": MistPasswordPageScript.binding,
                        "executionContextName": MistPasswordPageScript.world])
                    _ = try await session.command("Page.addScriptToEvaluateOnNewDocument", params: [
                        "source": MistPasswordPageScript.source, "worldName": MistPasswordPageScript.world])
                    let world = try await session.command("Page.createIsolatedWorld", params: [
                        "frameId": frameID, "worldName": MistPasswordPageScript.world])
                    guard let context = world["executionContextId"] as? Int else { throw MistPasswordError.unavailable }
                    entry.contexts.insert(context)
                    entry.origins[context] = try? await self.pageOrigin(entry)
                    _ = try await self.evaluate(MistPasswordPageScript.source, context: context, entry: entry)
                } catch { self.remove(tab.guid) }
            }
        }
    }

    private func remove(_ id: Int) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if suggestion?.entry === entry || codeWatch?.entry === entry { hide() }
        entry.close()
    }

    private func stop() {
        stopped = true
        hide(); prompt.close()
        for entry in entries.values { entry.close() }
        entries.removeAll()
        focusedWrapper = nil
        subscriptions.removeAll()
    }

    private func pageOrigin(_ entry: Entry) async throws -> String {
        let result = try await entry.session.command("Target.getTargetInfo", params: ["targetId": entry.target])
        guard let info = result["targetInfo"] as? [String: Any], let url = info["url"] as? String,
              let origin = MistPasswordMatching.origin(url) else { throw MistPasswordError.unavailable }
        return origin
    }

    private func evaluate(_ expression: String, context: Int, entry: Entry) async throws -> [String: Any] {
        guard !entry.closed, entry.contexts.contains(context) else { throw MistPasswordError.unavailable }
        return try await entry.session.command("Runtime.evaluate", params: ["expression": expression,
            "contextId": context, "returnByValue": true, "silent": true])
    }

    private func event(_ method: String, params: [String: Any], entry: Entry) {
        switch method {
        case "Runtime.executionContextCreated":
            guard let context = params["context"] as? [String: Any], context["name"] as? String == MistPasswordPageScript.world,
                  let aux = context["auxData"] as? [String: Any], aux["frameId"] as? String == entry.mainFrame,
                  let id = context["id"] as? Int else { return }
            entry.contexts.insert(id)
            let revision = entry.revision
            entry.enqueue { [weak self, weak entry] in
                guard let self, let entry, entry.contexts.contains(id) else { return }
                let origin = try? await self.pageOrigin(entry)
                if entry.revision == revision, entry.contexts.contains(id) { entry.origins[id] = origin }
            }
        case "Runtime.executionContextDestroyed":
            if let id = params["executionContextId"] as? Int {
                entry.contexts.remove(id); entry.origins[id] = nil
                if (suggestion?.entry === entry && suggestion?.context == id) ||
                    (codeWatch?.entry === entry && codeWatch?.context == id) { hide() }
            }
        case "Runtime.executionContextsCleared":
            entry.contexts.removeAll(); entry.origins.removeAll()
            if suggestion?.entry === entry || codeWatch?.entry === entry { hide() }
        case "Page.frameNavigated":
            guard let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            entry.mainFrame = frame["id"] as? String ?? entry.mainFrame
            entry.revision += 1; entry.focusRevision += 1
            if suggestion?.entry === entry || codeWatch?.entry === entry { hide() }
            success(entry)
        case "Runtime.bindingCalled":
            guard params["name"] as? String == MistPasswordPageScript.binding,
                  let context = params["executionContextId"] as? Int, entry.contexts.contains(context),
                  let payload = params["payload"] as? String, payload.utf8.count < 128 * 1024,
                  let bytes = payload.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
            messageReceived(message, context: context, entry: entry)
        default: break
        }
    }

    private func messageReceived(_ message: [String: Any], context: Int, entry: Entry) {
        switch message["type"] as? String {
        case "identifier":
            guard let origin = entry.origins[context], let username = message["username"] as? String,
                  !username.isEmpty else { return }
            let domain = Self.domain(origin)
            guard !domain.isEmpty else { return }
            entry.identifier = Identifier(domain: domain, username: username)
        case "focus":
            entry.focusRevision += 1
            if codeWatch?.entry === entry { codeWatch = nil }
            let revision = entry.focusRevision
            entry.enqueue { [weak self, weak entry] in
                guard let self, let entry, self.active(entry), entry.focusRevision == revision,
                      MistPasswordPreferences.autofill else { return }
                await self.focus(message, context: context, revision: revision, entry: entry)
            }
        case "blur":
            entry.focusRevision += 1
            if suggestion?.entry === entry || codeWatch?.entry === entry { hide() }
        case "key":
            guard suggestion?.entry === entry, suggestion?.context == context, let key = message["key"] as? String else { return }
            if key == "Escape" { entry.focusRevision += 1; hide() } else { dropdown.key(key) }
        case "submitted":
            guard browser?.isIncognito == false, MistPasswordPreferences.offerToSave,
                  let origin = entry.origins[context], var username = message["username"] as? String,
                  let password = message["password"] as? String, !password.isEmpty else { return }
            let domain = Self.domain(origin)
            guard !domain.isEmpty else { return }
            if message["mode"] as? String == "password" {
                if username.isEmpty { username = entry.identifier?.username(for: domain) ?? "" }
                guard !username.isEmpty else { return }
            }
            entry.pending = Pending(login: MistLogin(site: origin, username: username, password: password),
                                    domain: domain, context: context, deadline: Date().addingTimeInterval(30))
            entry.expiry?.cancel()
            entry.expiry = Task { [weak entry] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                entry?.pending = nil
            }
        case "formGone":
            if entry.pending?.context == context { success(entry) }
        default: break
        }
    }

    private func focus(_ message: [String: Any], context: Int, revision: Int, entry: Entry) async {
        guard let field = message["fieldId"] as? Int, let rect = message["rect"] as? [String: Double],
              let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
              let dpr = message["dpr"] as? Double, let mode = message["mode"] as? String,
              let kind = message["kind"] as? String else { return }
        do {
            let page = try await pageOrigin(entry)
            guard active(entry), entry.focusRevision == revision, entry.contexts.contains(context) else { return }
            entry.origins[context] = page
            if mode == "code" {
                guard MistPasswordPreferences.autofill else { return }
                codeWatch = CodeWatch(message: message, entry: entry, context: context, revision: revision)
                let codes = await MistMailCodeSource.shared.candidates(pageDomain: Self.domain(page),
                    expectedLength: message["length"] as? Int ?? 0)
                guard active(entry), entry.focusRevision == revision, entry.contexts.contains(context),
                      MistPasswordPreferences.autofill else { return }
                guard !codes.isEmpty else { hide(keepingCodeWatch: true); return }
                guard let view = entry.tab?.webContentWrapper?.nativeView,
                      dropdown.show(logins: [], emails: [], codes: codes, pageHost: URL(string: page)?.host ?? "",
                        rect: CGRect(x: x, y: y, width: width, height: height), dpr: dpr, in: view) else { hide(); return }
                suggestion = Suggestion(entry: entry, context: context, field: field, domain: Self.domain(page),
                                        revision: entry.revision, mode: mode, kind: kind)
                dropdown.choose = { [weak self] choice in self?.choose(choice) }
                _ = try await evaluate("window.__mistPwSetDropdownOpen(true)", context: context, entry: entry)
                guard active(entry), entry.focusRevision == revision, MistPasswordPreferences.autofill else { return }
                return
            }
            codeWatch = nil
            try MistPasswordVault.shared.load()
            guard active(entry), entry.focusRevision == revision, MistPasswordPreferences.autofill else { return }
            var logins = MistPasswordMatching.matches(MistPasswordVault.shared.data.logins, page: page, domain: Self.domain)
            let emails = (mode == "email" || kind == "username") ? MistPasswordVault.shared.data.emails.sorted {
                if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
                return $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending
            } : []
            if mode == "email" {
                logins = []
                if emails.isEmpty { hide(); return }
            }
            if mode == "password" {
                let hint = message["hint"] as? String ?? ""
                let preferred = hint.isEmpty ? entry.identifier?.username(for: Self.domain(page)) ?? "" : hint
                if !preferred.isEmpty { logins = MistPasswordMatching.preferring(preferred, in: logins) }
            }
            guard let view = entry.tab?.webContentWrapper?.nativeView else { hide(); return }
            guard dropdown.show(logins: logins, emails: emails, pageHost: URL(string: page)?.host ?? "",
                                rect: CGRect(x: x, y: y, width: width, height: height), dpr: dpr, in: view) else { hide(); return }
            suggestion = Suggestion(entry: entry, context: context, field: field, domain: Self.domain(page),
                                    revision: entry.revision, mode: mode, kind: kind)
            dropdown.choose = { [weak self] login in self?.choose(login) }
            _ = try await evaluate("window.__mistPwSetDropdownOpen(\(logins.isEmpty && emails.isEmpty ? "'passive'" : "true"))",
                                   context: context, entry: entry)
        } catch { hide() }
    }

    private func hide(keepingCodeWatch: Bool = false) {
        if !keepingCodeWatch {
            codeWatch = nil
            for entry in entries.values { entry.focusRevision += 1 }
        }
        let old = suggestion
        suggestion = nil
        dropdown.hide()
        if let old {
            old.entry.enqueue { [weak self] in
                guard let self else { return }
                if self.suggestion?.entry === old.entry, self.suggestion?.context == old.context { return }
                _ = try? await self.evaluate("window.__mistPwSetDropdownOpen(false)", context: old.context, entry: old.entry)
            }
        }
    }

    private func choose(_ choice: MistPasswordDropdown.Choice) {
        guard let selected = suggestion else { return }
        hide()
        let focusRevision = selected.entry.focusRevision
        if case .manage = choice { AppController.shared.showSettings(pane: .mistPasswords); return }
        selected.entry.enqueue { [weak self] in
            guard let self, self.active(selected.entry), MistPasswordPreferences.autofill,
                  selected.entry.revision == selected.revision else { return }
            do {
                let page = try await self.pageOrigin(selected.entry)
                guard self.active(selected.entry), selected.entry.revision == selected.revision,
                      MistPasswordPreferences.autofill,
                      Self.domain(page) == selected.domain else { return }
                if case .code(let code) = choice {
                    guard selected.mode == "code", selected.entry.focusRevision == focusRevision else { return }
                    let result = try await self.evaluate("window.__mistPwFillCode(\(selected.field),\(MistPasswordPageScript.literal(code.code)))",
                        context: selected.context, entry: selected.entry)
                    guard let remote = result["result"] as? [String: Any],
                          let value = remote["value"] as? [String: Any], value["ok"] as? Bool == true else { return }
                    self.codeWatch = nil
                    await MistMailCodeSource.shared.consume(code)
                    return
                }
                let expression: String
                let username: String
                switch choice {
                case .login(let login):
                    guard !MistPasswordMatching.matches([login], page: page, domain: Self.domain).isEmpty else { return }
                    username = login.username
                    expression = "window.__mistPwFill(\(selected.field),\(MistPasswordPageScript.literal(login.username)),\(MistPasswordPageScript.literal(login.password)))"
                case .email(let email):
                    guard selected.kind != "password" else { return }
                    username = email.address
                    expression = "window.__mistPwFillField(\(selected.field),\(MistPasswordPageScript.literal(email.address)))"
                case .code, .manage: return
                }
                let result = try await self.evaluate(expression, context: selected.context, entry: selected.entry)
                guard let remote = result["result"] as? [String: Any],
                      let value = remote["value"] as? [String: Any], value["ok"] as? Bool == true else { return }
                if selected.mode == "username" {
                    selected.entry.identifier = Identifier(domain: selected.domain, username: username)
                }
                try MistPasswordVault.shared.change { value in
                    switch choice {
                    case .login(let login):
                        if let index = value.logins.firstIndex(where: { $0.id == login.id }) { value.logins[index].lastUsed = Date() }
                    case .email(let email):
                        if let index = value.emails.firstIndex(where: { $0.id == email.id }) { value.emails[index].lastUsed = Date() }
                    case .code, .manage: break
                    }
                }
            } catch { /* A failed fill never exposes transport errors or credentials. */ }
        }
    }

    private func success(_ entry: Entry) {
        guard let pending = entry.pending else { return }
        entry.pending = nil; entry.expiry?.cancel(); entry.expiry = nil; entry.identifier = nil
        guard pending.deadline > Date(), browser?.isIncognito == false,
              MistPasswordPreferences.offerToSave else { return }
        entry.enqueue { [weak self, weak entry] in
            guard let self, let entry, self.active(entry), let controller = self.browser?.windowController else { return }
            do {
                let vault = MistPasswordVault.shared
                try vault.load()
                guard !vault.data.neverSave.contains(pending.domain) else { return }
                let existing = MistPasswordMatching.matches(vault.data.logins, page: pending.login.site, domain: Self.domain)
                    .first { $0.username == pending.login.username }
                if existing?.password == pending.login.password { return }
                let header = controller.mainSplitViewController.webContentContainerViewController.addressBarAnchorView
                guard let anchor = (header?.window === controller.window && header?.isHiddenOrHasHiddenAncestor == false)
                    ? header : controller.window?.contentView else { return }
                let fallbackRect = anchor === header ? nil : NSRect(x: anchor.bounds.midX, y:
                    anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1, width: 1, height: 1)
                self.prompt.show(login: pending.login, updating: existing != nil, anchor: anchor, rect: fallbackRect) { [weak self] action in
                    guard let self, self.browser?.isIncognito == false, MistPasswordPreferences.offerToSave else { return }
                    do {
                        try vault.change { value in
                            switch action {
                            case .never: value.neverSave.insert(pending.domain)
                            case .save:
                                if let existing, let index = value.logins.firstIndex(where: { $0.id == existing.id }) {
                                    value.logins[index].password = pending.login.password
                                    value.logins[index].site = pending.login.site
                                } else { value.logins.append(pending.login) }
                            }
                        }
                    } catch { MistPasswordsSettingViewController.showError() }
                }
            } catch { MistPasswordsSettingViewController.showError() }
        }
    }
}
