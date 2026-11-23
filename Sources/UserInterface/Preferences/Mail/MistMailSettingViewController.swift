import AppKit
import MistMailCore
import Settings
import enum Settings.Settings
import SwiftUI

extension Settings.PaneIdentifier { static let mistMail = Self("mistMail") }

final class MistMailSettingViewController: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier = .mistMail
    let paneTitle = MistAppID.mail.name
    let toolbarItemIcon = NSImage.settingsPaneIcon(systemSymbolName: "envelope", pointSize: 15)
    override func loadView() {
        let host = ThemedHostingController(rootView: MistMailSettingsView()); addChild(host); view = host.view
        view.setFrameSize(NSSize(width: 680, height: 561))
    }
}

/// Value-only defaults and validation, usable without constructing Settings or touching credentials.
struct MailAccountForm {
    var presetIndex = 0
    var accountName = "", senderName: String, email = "", username = "", password = ""
    var imapHost = "", imapPort = "993", imapSecurity: MailSecurity = .tls
    var smtpHost = "", smtpPort = "465", smtpSecurity: MailSecurity = .tls
    var serverExpanded = false
    var sortOrder = 0
    var signatureHTML: String?

    init(account: MailAccount? = nil, senderName: String = NSFullUserName()) {
        self.senderName = senderName
        if let account {
            let config = account.config
            presetIndex = MailAccountPreset.all.firstIndex { $0.imap?.host == config.imap.host && $0.smtp?.host == config.smtp.host } ?? 2
            accountName = config.displayName; self.senderName = config.senderName; email = config.email; username = config.username; sortOrder = config.sortOrder
            signatureHTML = config.signatureHTML
            imapHost = config.imap.host; imapPort = String(config.imap.port); imapSecurity = config.imap.security
            smtpHost = config.smtp.host; smtpPort = String(config.smtp.port); smtpSecurity = config.smtp.security; serverExpanded = presetIndex == 2
        } else { selectPreset(0) }
    }
    mutating func selectPreset(_ index: Int) {
        guard MailAccountPreset.all.indices.contains(index) else { return }
        presetIndex = index; let preset = MailAccountPreset.all[index]
        imapHost = preset.imap?.host ?? ""; imapPort = String(preset.imap?.port ?? 993); imapSecurity = preset.imap?.security ?? .tls
        smtpHost = preset.smtp?.host ?? ""; smtpPort = String(preset.smtp?.port ?? 587); smtpSecurity = preset.smtp?.security ?? .startTLS
        username = defaultUsername(email); serverExpanded = index == 2
    }
    func defaultUsername(_ email: String) -> String { presetIndex == 1 ? String(email.split(separator: "@", omittingEmptySubsequences: false).first ?? "") : email }
    mutating func setEmail(_ value: String) {
        let shouldFill = username.isEmpty || username == defaultUsername(email)
        email = value; if shouldFill { username = defaultUsername(value) }
    }
    func configuration() throws -> MailAccountConfig {
        guard let incoming = Int(imapPort), let outgoing = Int(smtpPort) else { throw MailError.invalidConfiguration }
        let config = MailAccountConfig(displayName: accountName.isEmpty ? email : accountName, senderName: senderName, email: email, username: username,
                                       imap: .init(host: imapHost, port: incoming, security: imapSecurity), smtp: .init(host: smtpHost, port: outgoing, security: smtpSecurity), sortOrder: sortOrder,
                                       signatureHTML: signatureHTML)
        try config.validate(); return config
    }
}

private struct MailAccountSheetSelection: Identifiable { let id = UUID(); let account: MailAccount? }

private struct MistMailSettingsView: View {
    @ObservedObject private var service = MistMailService.shared
    @AppStorage(MailNotificationPolicy.settingKey) private var notificationsEnabled = true
    @State private var editing: MailAccountSheetSelection?
    @State private var removing: MailAccount?
    @State private var error: String?
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    /// Drag-reorder state, as in the Spaces pane: `orderedIDs` is rearranged live while a drag hovers
    /// across rows, and the engine is written once, on drop.
    @State private var draggingID: String?
    @State private var orderedIDs: [String] = []

    private var orderedAccounts: [MailAccount] {
        guard !orderedIDs.isEmpty else { return service.accounts }
        let byID = Dictionary(uniqueKeysWithValues: service.accounts.map { ($0.id.uuidString, $0) })
        let known = Set(orderedIDs)
        return orderedIDs.compactMap { byID[$0] } + service.accounts.filter { !known.contains($0.id.uuidString) }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(MailStrings.accounts).font(.system(size: 12)).themedForeground(.textSecondary)
                SettingsDetailCard {
                    if service.accounts.isEmpty {
                        SettingsDetailRow(MailStrings.addAccount) { EmptyView() }
                    }
                    ForEach(Array(orderedAccounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsRowDivider() }
                        if service.accounts.count > 1 { reorderableRow(account) } else { accountRow(account, reorderable: false) }
                    }
                }
                // Catches a drop that lands off every row (the dragged row's own slot, a divider, the card's padding).
                .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(draggingSpaceId: $draggingID, orderedIds: $orderedIDs, commit: reorder))
                Button(MailStrings.add) { editing = .init(account: nil) }
                SettingsDetailCard {
                    SettingsDetailRow(MailStrings.showNotifications) {
                        Toggle("", isOn: $notificationsEnabled).labelsHidden()
                    }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }.padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground).frame(width: 680, height: 561)
        // A drag cancelled with Esc or dropped outside the card never reports back; reopening the pane heals it.
        .onAppear { draggingID = nil; orderedIDs = service.accounts.map(\.id.uuidString) }
        // Follow changes made elsewhere (a synced reorder, an added or removed account), never mid-drag.
        .onChange(of: service.accounts.map(\.id)) { _, ids in if draggingID == nil { orderedIDs = ids.map(\.uuidString) } }
        .onChange(of: notificationsEnabled) { _, enabled in service.notificationsEnabledDidChange(enabled) }
        .sheet(item: $editing) { selection in MailAccountSheet(account: selection.account, engine: service.engine) }
        .alert(removing.map { String(format: MailStrings.removeTitle, $0.config.displayName) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button(MailStrings.remove, role: .destructive) {
                removing = nil
                Task {
                    do { guard let engine = service.engine else { throw MailError.storage("") }; try await engine.removeAccount(account.id); error = nil }
                    catch { self.error = MailPresentation.errorMessage(error) }
                }
            }
            Button(MailStrings.cancel, role: .cancel) { removing = nil }
        } message: { _ in Text(MistSyncEngine.shared.credentials != nil ? MailStrings.removeMessageSynced : MailStrings.removeMessage) }
    }

    private func accountRow(_ account: MailAccount, reorderable: Bool) -> some View {
        HStack(spacing: 8) {
            if reorderable { Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).themedForeground(.textSecondary) }
            SettingsDetailRow(account.config.displayName) {
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(verbatim: account.config.email).font(.system(size: 12)).themedForeground(.textSecondary)
                        HStack(spacing: 4) {
                            Circle().fill(Color(nsColor: MailPresentation.statusColor(service.statuses[account.id]))).frame(width: 6, height: 6)
                            Text(MailPresentation.status(service.statuses[account.id])).font(.system(size: 11)).themedForeground(.textSecondary)
                        }
                    }
                    if Self.offersReconnect(service.statuses[account.id]) {
                        Button(MailStrings.reconnect) { service.reconnect(account.id) }
                    }
                    Button(MailStrings.edit) { editing = .init(account: account) }
                    Button(MailStrings.remove) { removing = account }
                }
            }
        }
    }

    /// Every status but a working connection, or one being made.
    static func offersReconnect(_ status: MailAccountStatus?) -> Bool {
        switch status { case .connected, .connecting, .syncing: false; default: true }
    }

    /// The Spaces pane's drag: an explicit full-opacity preview, the lifted row hidden as the drop gap,
    /// rows moving aside live, and one engine write on drop.
    private func reorderableRow(_ account: MailAccount) -> some View {
        let id = account.id.uuidString
        return accountRow(account, reorderable: true)
            .contentShape(Rectangle())
            .onDrag {
                draggingID = id
                return NSItemProvider(object: id as NSString)
            } preview: {
                // The card's width, so the lifted account looks like the row it came from.
                accountRow(account, reorderable: true).padding(.horizontal, 12).frame(width: 608).settingsCardChrome()
                    .environment(\.phiTheme, theme).environment(\.phiAppearance, appearance)
            }
            .opacity(draggingID == id ? 0 : 1)
            .onDrop(of: [.text], delegate: SpaceRowDropDelegate(targetSpaceId: id, draggingSpaceId: $draggingID, orderedIds: $orderedIDs, commit: reorder))
    }

    private func reorder(_ ids: [String]) {
        Task {
            do {
                guard let engine = service.engine else { throw MailError.storage("") }
                try await engine.reorderAccounts(ids.compactMap(UUID.init(uuidString:))); error = nil
            } catch {
                self.error = MailPresentation.errorMessage(error); orderedIDs = service.accounts.map(\.id.uuidString)
            }
        }
    }
}

private struct MailAccountSheet: View {
    let account: MailAccount?
    let engine: MailEngine?
    @State private var form: MailAccountForm
    @State private var signature: MailSignatureEditorSession
    @State private var signatureHasFocus = false
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(account: MailAccount?, engine: MailEngine?) {
        self.account = account; self.engine = engine; _form = State(initialValue: MailAccountForm(account: account))
        _signature = State(initialValue: MailSignatureEditorSession(html: account?.config.signatureHTML))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(account == nil ? MailStrings.addAccountTitle : MailStrings.editAccount).font(.system(size: 18, weight: .semibold)).themedForeground(.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsDetailCard {
                        SettingsDetailRow(MailStrings.preset) {
                            Picker("", selection: Binding(get: { form.presetIndex }, set: { form.selectPreset($0) })) {
                                ForEach(MailAccountPreset.all.indices, id: \.self) { index in Text(verbatim: index == 2 ? MailStrings.other : MailAccountPreset.all[index].name).tag(index) }
                            }.labelsHidden().frame(width: 300)
                        }
                        SettingsRowDivider(); field(MailStrings.accountName, text: $form.accountName)
                        SettingsRowDivider(); field(MailStrings.yourName, text: $form.senderName)
                        SettingsRowDivider(); field(MailStrings.email, text: Binding(get: { form.email }, set: { form.setEmail($0) }))
                        SettingsRowDivider(); field(MailStrings.username, text: $form.username)
                        SettingsRowDivider()
                        SettingsDetailRow(MailStrings.password) {
                            SecureField(account == nil ? "" : MailStrings.unchangedPassword, text: $form.password).textFieldStyle(.roundedBorder).frame(width: 300)
                        }
                    }
                    if form.presetIndex == 0 {
                        Button(MailStrings.gmailHint) {
                            let url = URL(string: "https://myaccount.google.com/apppasswords")!
                            if let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState { state.createTab(url.absoluteString) }
                            else { AppController.shared?.application(NSApp, open: [url]) }
                        }.buttonStyle(.link).font(.system(size: 12))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MailStrings.signature).font(.system(size: 12)).themedForeground(.textSecondary)
                        SettingsDetailCard {
                            MailSignatureEditorView(editor: signature.editor, isEnabled: !working, hasFocus: $signatureHasFocus)
                                .frame(height: 180)
                                .padding(.vertical, 4)
                        }
                    }
                    DisclosureGroup(MailStrings.servers, isExpanded: $form.serverExpanded) {
                        SettingsDetailCard {
                            field(MailStrings.imapHost, text: $form.imapHost)
                            SettingsRowDivider(); field(MailStrings.port, text: $form.imapPort)
                            SettingsRowDivider(); security($form.imapSecurity)
                            SettingsRowDivider(); field(MailStrings.smtpHost, text: $form.smtpHost)
                            SettingsRowDivider(); field(MailStrings.port, text: $form.smtpPort)
                            SettingsRowDivider(); security($form.smtpSecurity)
                        }.padding(.top, 8)
                    }.font(.system(size: 12)).themedForeground(.textSecondary)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
            }.disabled(working)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(MailStrings.cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(MailStrings.signIn, action: signIn)
                    .keyboardShortcut(signatureHasFocus ? nil : .defaultAction)
                    .disabled(working || (account == nil && form.password.isEmpty))
            }
        }.padding(24).frame(width: 600, height: 740).themedBackground(PhiPreferences.fixedWindowBackground)
        .interactiveDismissDisabled(working)
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        SettingsDetailRow(title) { TextField("", text: text).textFieldStyle(.roundedBorder).autocorrectionDisabled().frame(width: 300) }
    }
    private func security(_ value: Binding<MailSecurity>) -> some View {
        SettingsDetailRow(MailStrings.security) {
            Picker("", selection: value) {
                Text(verbatim: "TLS").tag(MailSecurity.tls); Text(verbatim: "STARTTLS").tag(MailSecurity.startTLS); Text(MailStrings.noSecurity).tag(MailSecurity.plaintext)
            }.labelsHidden().frame(width: 300)
        }
    }
    private func signIn() {
        working = true; error = nil
        Task {
            do {
                guard let engine else { throw MailError.storage("") }
                form.signatureHTML = try await signature.editor.exportBody()
                var config = try form.configuration()
                if config.signatureHTML != nil {
                    let password = if let account, form.password.isEmpty { try await engine.storedPassword(accountID: account.id) }
                        else { form.password }
                    try MistEngineMailAccountSyncStorage.validateSignatureSize(config, password: password)
                }
                if let account { try await engine.updateAccount(account.id, config: config, password: form.password.isEmpty ? nil : form.password) }
                else {
                    // Last, read now: a reorder while the sheet was open moves the positions up.
                    config.sortOrder = (try await engine.accounts().map(\.config.sortOrder).max() ?? -1) + 1
                    try await engine.addAccount(config, password: form.password)
                }
                form.password = ""; dismiss()
            } catch { self.error = MailPresentation.errorMessage(error) }
            working = false
        }
    }
}

@MainActor
private final class MailSignatureEditorSession {
    private let html: String?
    init(html: String?) { self.html = html }

    lazy var editor: MailRichTextEditor = {
        let editor = MailRichTextEditor()
        editor.setAccessibilityLabel(MailStrings.signature)
        editor.loadDocument(MailComposeFormatting.document(html: MailAccountConfig.normalizedSignature(html)))
        return editor
    }()
}

private struct MailSignatureEditorView: NSViewRepresentable {
    let editor: MailRichTextEditor
    let isEnabled: Bool
    @Binding var hasFocus: Bool

    func makeCoordinator() -> MailFormattingToolbar {
        let toolbar = MailFormattingToolbar(editor: editor)
        let focus = $hasFocus
        editor.onFocusChange = { focus.wrappedValue = $0 }
        editor.onShortcut = { [weak toolbar] command in
            if command == "link" { toolbar?.showLinkSheet() }
        }
        return toolbar
    }

    func makeNSView(context: Context) -> NSStackView {
        let toolbar = context.coordinator
        let stack = NSStackView(views: [toolbar, editor])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        NSLayoutConstraint.activate([
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return stack
    }

    func updateNSView(_ view: NSStackView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        editor.allowsBodyEditing = isEnabled
    }
}
