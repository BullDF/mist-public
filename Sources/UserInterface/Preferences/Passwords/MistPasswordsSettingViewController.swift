import AppKit
import LocalAuthentication
import Settings
import enum Settings.Settings
import SwiftUI
import UniformTypeIdentifiers

extension Settings.PaneIdentifier {
    static let mistPasswords = Self("mistPasswords")
}

final class MistPasswordsSettingViewController: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier = .mistPasswords
    let paneTitle = MistPasswordStrings.title
    let toolbarItemIcon = NSImage.settingsPaneIcon(systemSymbolName: "key", pointSize: 15)

    override func loadView() {
        let host = ThemedHostingController(rootView: MistPasswordsSettingsView())
        addChild(host)
        view = host.view
        view.setFrameSize(NSSize(width: 680, height: 561))
    }

    @MainActor static func showError() {
        let alert = NSAlert()
        alert.messageText = MistPasswordStrings.error
        alert.informativeText = MistPasswordStrings.errorMessage
        alert.addButton(withTitle: MistPasswordStrings.done)
        if let window = AppController.shared.settingsWindowController?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else { alert.runModal() }
    }
}

private struct MistPasswordsSettingsView: View {
    @ObservedObject private var vault = MistPasswordVault.shared
    @AppStorage(MistPasswordPreferences.offerToSaveKey) private var offer = true
    @AppStorage(MistPasswordPreferences.autofillKey) private var autofill = true
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var pendingDeletion: Set<UUID> = []
    @State private var emailAddress = ""

    private var newEmail: String? {
        guard let address = MistEmailAddress.normalized(emailAddress),
              !vault.data.emails.contains(where: { $0.id == address.lowercased() }) else { return nil }
        return address
    }

    private var filtered: [MistLogin] {
        vault.data.logins.filter { search.isEmpty || $0.host.localizedCaseInsensitiveContains(search) ||
            $0.username.localizedCaseInsensitiveContains(search) }.sorted {
                ($0.host, $0.username) < ($1.host, $1.username)
            }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                SettingsDetailCard {
                    SettingsDetailRow(MistPasswordStrings.offer, systemImage: "key") {
                        Toggle("", isOn: $offer)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                            .accessibilityLabel(MistPasswordStrings.offer)
                    }
                    SettingsRowDivider()
                    SettingsDetailRow(MistPasswordStrings.autofill, systemImage: "text.cursor") {
                        Toggle("", isOn: $autofill)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                            .accessibilityLabel(MistPasswordStrings.autofill)
                    }
                }

                section(title: MistPasswordStrings.saved) {
                    HStack(alignment: .top, spacing: 16) {
                        loginListPanel
                            .frame(width: 240, height: 300)
                        detailPanel
                            .frame(maxWidth: .infinity)
                            .frame(height: 300, alignment: .top)
                    }
                }

                section(title: MistPasswordStrings.emails) {
                    SettingsDetailCard {
                        ForEach(vault.data.emails.sorted {
                            $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending
                        }) { email in
                            emailRow(email)
                            SettingsRowDivider()
                        }
                        HStack(spacing: 12) {
                            TextField(MistPasswordStrings.emailPlaceholder, text: $emailAddress)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit(addEmail)
                            Button(MistPasswordStrings.addEmail, action: addEmail)
                                .controlSize(.small)
                                .disabled(newEmail == nil)
                        }
                        .padding(.vertical, 12)
                    }
                }

                section(title: MistPasswordStrings.never) {
                    SettingsDetailCard {
                        if vault.data.neverSave.isEmpty {
                            Text(MistPasswordStrings.neverEmpty)
                                .font(.system(size: 13))
                                .themedForeground(.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(Array(vault.data.neverSave.sorted().enumerated()), id: \.element) { index, site in
                                if index > 0 { SettingsRowDivider() }
                                neverSaveRow(site)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .onAppear {
            do { try vault.load() } catch { MistPasswordsSettingViewController.showError() }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .alert(pendingDeletion.count > 1
               ? String(format: MistPasswordStrings.deleteMultipleTitle, pendingDeletion.count)
               : MistPasswordStrings.deleteTitle, isPresented: $confirmingDelete) {
            Button(MistPasswordStrings.deleteConfirm, role: .destructive) {
                do {
                    try vault.change { data in
                        data.logins.removeAll { pendingDeletion.contains($0.id) }
                    }
                    selection.removeAll()
                } catch { MistPasswordsSettingViewController.showError() }
            }
            Button(MistPasswordStrings.cancel, role: .cancel) {}
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loginListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                TextField(MistPasswordStrings.search, text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SettingsRowDivider()

            List(selection: $selection) {
                ForEach(filtered) { login in
                    loginListRow(login)
                        .tag(login.id)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onDeleteCommand(perform: confirmDeletion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if filtered.isEmpty {
                    Text(MistPasswordStrings.empty)
                        .font(.system(size: 12))
                        .themedForeground(.textSecondary)
                }
            }

            SettingsRowDivider()

            HStack(spacing: 0) {
                Button(action: importCSV) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(MistPasswordStrings.importCSV)
                .accessibilityLabel(MistPasswordStrings.importCSV)
                Button(action: exportCSV) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(MistPasswordStrings.exportCSV)
                .accessibilityLabel(MistPasswordStrings.exportCSV)
                .disabled(vault.data.logins.isEmpty)
                Spacer()
            }
            .frame(height: 34)
        }
        .settingsCardChrome()
    }

    private func loginListRow(_ login: MistLogin) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: login.host)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .lineLimit(1)
            Text(verbatim: login.username)
                .font(.system(size: 11))
                .themedForeground(.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailPanel: some View {
        if selection.count > 1 {
            VStack(spacing: 12) {
                Text(String(format: MistPasswordStrings.selectedCount, selection.count))
                    .font(.system(size: 13))
                    .themedForeground(.textSecondary)
                Button(String(format: MistPasswordStrings.deleteMultiple, selection.count), role: .destructive,
                       action: confirmDeletion)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let login = filtered.first(where: { selection.contains($0.id) }) {
            ScrollView {
                MistPasswordDetails(login: login, onDelete: confirmDeletion).id(login.id)
            }
        } else {
            Text(MistPasswordStrings.selectPrompt)
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func confirmDeletion() {
        guard !selection.isEmpty else { return }
        pendingDeletion = selection
        confirmingDelete = true
    }

    private func addEmail() {
        guard let address = newEmail else { return }
        do {
            try vault.change { $0.insertEmail(address) }
            emailAddress = ""
        } catch { MistPasswordsSettingViewController.showError() }
    }

    private func emailRow(_ email: MistEmail) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 16, weight: .regular))
                .themedForeground(.textSecondary)
                .frame(width: 24, alignment: .center)
            Text(verbatim: email.address)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(MistPasswordStrings.remove) {
                do { try vault.change { $0.removeEmail(id: email.id) } }
                catch { MistPasswordsSettingViewController.showError() }
            }
            .controlSize(.small)
            .layoutPriority(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func neverSaveRow(_ site: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .regular))
                .themedForeground(.textSecondary)
                .frame(width: 24, alignment: .center)
            Text(verbatim: site)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(MistPasswordStrings.remove) {
                do { try vault.change { $0.neverSave.remove(site) } }
                catch { MistPasswordsSettingViewController.showError() }
            }
            .controlSize(.small)
            .layoutPriority(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportCSV() {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        Task { @MainActor in
            let allowed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                             localizedReason: MistPasswordStrings.exportAuthenticate)) == true
            context.invalidate()
            guard allowed else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Passwords.csv"
            panel.message = MistPasswordStrings.exportPlaintext
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let logins = vault.data.logins
                    try Data(MistPasswordCSV.export(logins).utf8).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { MistPasswordsSettingViewController.showError() }
            }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let counts = try vault.importCSV(String(contentsOf: url, encoding: .utf8), domain: MistPasswordTabManager.domain)
                let alert = NSAlert()
                alert.messageText = MistPasswordStrings.importTitle
                alert.informativeText = String(format: MistPasswordStrings.importCounts, counts.imported, counts.updated, counts.skipped)
                    + "\n\n" + MistPasswordStrings.plaintext
                alert.addButton(withTitle: MistPasswordStrings.done)
                alert.addButton(withTitle: MistPasswordStrings.trash)
                let completion: (NSApplication.ModalResponse) -> Void = { result in
                    if result == .alertSecondButtonReturn {
                        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                        catch { MistPasswordsSettingViewController.showError() }
                    }
                }
                if let window = AppController.shared.settingsWindowController?.window {
                    alert.beginSheetModal(for: window, completionHandler: completion)
                } else { completion(alert.runModal()) }
            } catch { MistPasswordsSettingViewController.showError() }
        }
    }
}

private struct MistPasswordDetails: View {
    let login: MistLogin
    let onDelete: () -> Void
    @State private var username: String
    @State private var password: String
    @State private var revealed = false
    @State private var authentication: LAContext?
    @State private var active = true

    init(login: MistLogin, onDelete: @escaping () -> Void) {
        self.login = login
        self.onDelete = onDelete
        _username = State(initialValue: login.username)
        _password = State(initialValue: login.password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsDetailCard {
                SettingsDetailRow(MistPasswordStrings.website, systemImage: "globe") {
                    Text(verbatim: login.host)
                        .font(.system(size: 13))
                        .themedForeground(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 150, alignment: .trailing)
                }
                SettingsRowDivider()
                SettingsDetailRow(MistPasswordStrings.username, systemImage: "person") {
                    HStack(spacing: 4) {
                        TextField(MistPasswordStrings.username, text: $username)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                        iconButton(systemName: "doc.on.doc", help: MistPasswordStrings.copyUsername) {
                            copy(username)
                        }
                    }
                }
                SettingsRowDivider()
                SettingsDetailRow(MistPasswordStrings.password, systemImage: "lock") {
                    HStack(spacing: 4) {
                        Group {
                            if revealed {
                                TextField(MistPasswordStrings.password, text: $password)
                            } else {
                                SecureField(MistPasswordStrings.password, text: $password)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.trailing)
                        // Narrower than the username field so a localized label fits beside two buttons.
                        .frame(width: 128)
                        iconButton(systemName: revealed ? "eye.slash" : "eye",
                                   help: revealed ? MistPasswordStrings.hide : MistPasswordStrings.reveal) {
                            if revealed { revealed = false } else { authenticate { revealed = true } }
                        }
                        iconButton(systemName: "doc.on.doc", help: MistPasswordStrings.copyPassword) {
                            authenticate { copy(password) }
                        }
                    }
                }
            }

            HStack {
                Button(MistPasswordStrings.delete, role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Spacer()
                Button(MistPasswordStrings.saveChanges) {
                    do {
                        try MistPasswordVault.shared.change { data in
                            if let index = data.logins.firstIndex(where: { $0.id == login.id }) {
                                data.logins[index].username = username
                                data.logins[index].password = password
                            }
                        }
                        revealed = false
                    } catch { MistPasswordsSettingViewController.showError() }
                }
                .controlSize(.small)
                .disabled(password.isEmpty || (username == login.username && password == login.password))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(authentication != nil)
        .onAppear { active = true; username = login.username; password = login.password; revealed = false }
        .onChange(of: login) { _, updated in
            authentication?.invalidate(); authentication = nil
            username = updated.username; password = updated.password; revealed = false
        }
        .onDisappear { active = false; revealed = false; password = ""; authentication?.invalidate(); authentication = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealed = false
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func authenticate(_ action: @escaping () -> Void) {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authentication = context
        Task { @MainActor in
            let allowed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                             localizedReason: MistPasswordStrings.authenticate)) == true
            guard active, authentication === context else { return }
            authentication = nil
            context.invalidate()
            if allowed { action() }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
