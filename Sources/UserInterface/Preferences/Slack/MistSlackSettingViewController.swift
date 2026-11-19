import AppKit
import Settings
import enum Settings.Settings
import SwiftUI

extension Settings.PaneIdentifier {
    static let mistSlack = Self("mistSlack")
}

final class MistSlackSettingViewController: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier = .mistSlack
    let paneTitle = MistSlackStrings.title
    let toolbarItemIcon = NSImage.settingsPaneIcon(systemSymbolName: "number", pointSize: 15)

    override func loadView() {
        let host = ThemedHostingController(rootView: MistSlackSettingsView())
        addChild(host)
        view = host.view
        view.setFrameSize(NSSize(width: 680, height: 561))
    }
}

private struct MistSlackSettingsView: View {
    @ObservedObject private var service = MistSlackService.shared
    @ObservedObject private var connection = SlackAgentConnection.shared
    @State private var user = ""
    @State private var bot = ""
    @State private var app = ""
    @State private var saving = false
    @State private var confirmingRemoval = false
    @State private var error: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                if let identity = service.identity {
                    section(MistSlackStrings.workspace) {
                        SettingsDetailCard {
                            SettingsDetailRow(MistSlackStrings.workspace) {
                                VStack(alignment: .trailing, spacing: 4) {
                                    value(identity.team)
                                    Text(verbatim: identity.url)
                                        .font(.system(size: 12))
                                        .themedForeground(.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                            SettingsRowDivider()
                            SettingsDetailRow(MistSlackStrings.signedInAs) { value(identity.displayName) }
                            if let bot = identity.bot {
                                SettingsRowDivider()
                                SettingsDetailRow(MistSlackStrings.bot) { value(bot) }
                            }
                        }
                    }
                }
                section(MistSlackStrings.drifterInSlack) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsDetailCard {
                            SettingsDetailRow(MistSlackStrings.answerInSlack) {
                                Toggle("", isOn: $connection.answerInSlack).toggleStyle(.switch)
                                    .labelsHidden()
                                    .controlSize(.mini)
                                    .themedTint(.themeColor)
                            }
                        }
                        Text(connectionStatus)
                            .font(.system(size: 12))
                            .themedForeground(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section(MistSlackStrings.tokens) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsDetailCard {
                            tokenRow(MistSlackStrings.userToken, text: $user, saved: service.tokens.user != nil, kind: .user)
                            SettingsRowDivider()
                            tokenRow(MistSlackStrings.botToken, text: $bot, saved: service.tokens.bot != nil, kind: .bot)
                            SettingsRowDivider()
                            tokenRow(MistSlackStrings.appToken, text: $app, saved: service.tokens.app != nil, kind: .app)
                        }
                        HStack(spacing: 8) {
                            Button(MistSlackStrings.save, action: save)
                                .disabled(saving || [user, bot, app].allSatisfy { $0.isEmpty })
                            if saving { ProgressView().controlSize(.small) }
                        }
                        Text(MistSlackStrings.hint)
                            .font(.system(size: 12))
                            .themedForeground(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if service.isConfigured {
                    Button(MistSlackStrings.removeTokens, role: .destructive) { confirmingRemoval = true }
                        .disabled(saving)
                }
                if let message = error ?? identityError {
                    Text(message).font(.system(size: 12)).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(36)
        }
        .controlSize(.regular)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .task { await service.refreshIdentity() }
        .alert(MistSlackStrings.removeTitle, isPresented: $confirmingRemoval) {
            Button(MistSlackStrings.remove, role: .destructive) {
                do {
                    try service.remove()
                    user = ""
                    bot = ""
                    app = ""
                    error = nil
                } catch { self.error = MistSlackStrings.message(error) }
            }
            Button(MistSlackStrings.cancel, role: .cancel) {}
        } message: { Text(MistSlackStrings.removeMessage) }
    }

    private var identityError: String? {
        guard service.isConfigured, service.identity == nil, let error = service.lastError else { return nil }
        return MistSlackStrings.message(error)
    }

    private var connectionStatus: String {
        switch connection.status {
        case .off: return MistSlackStrings.answerOff
        case .missingTokens: return MistSlackStrings.answerMissingTokens
        case .connecting: return MistSlackStrings.answerConnecting
        case .connected(let count): return count > 1 ? MistSlackStrings.answerShared : MistSlackStrings.answerConnected
        case .failed(let code): return code == "network" ? MistSlackStrings.errorNetwork : String(format: MistSlackStrings.answerFailed, code)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 12)).themedForeground(.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 13)).themedForeground(.textSecondary).textSelection(.enabled)
    }

    private func tokenRow(_ label: String, text: Binding<String>, saved: Bool, kind: SlackTokenKind) -> some View {
        SettingsDetailRow(label) {
            SecureField(text: text, prompt: Text(verbatim: saved ? MistSlackStrings.saved : kind.prefix + "…")) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(width: 300)
                .disabled(saving)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await service.save(user: user, bot: bot, app: app)
                user = ""
                bot = ""
                app = ""
            } catch { self.error = MistSlackStrings.message(error) }
        }
    }
}
