import AppKit
import Settings
import enum Settings.Settings
import SwiftUI

extension Settings.PaneIdentifier {
    static let mistSync = Self("mistSync")
}

final class MistSyncSettingViewController: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier = .mistSync
    let paneTitle = MistSyncStrings.title
    let toolbarItemIcon = NSImage.settingsPaneIcon(systemSymbolName: "arrow.triangle.2.circlepath", pointSize: 15)

    override func loadView() {
        let host = ThemedHostingController(rootView: MistSyncSettingsView())
        addChild(host)
        view = host.view
        view.setFrameSize(NSSize(width: 680, height: 561))
    }
}

private struct MistSyncSettingsView: View {
    @ObservedObject private var engine = MistSyncEngine.shared
    @ObservedObject private var clipboard = MistClipboardSyncSource.shared
    @State private var serverURL = ""
    @State private var pairingCode = ""
    @State private var showPairing = false
    @State private var confirmingTurnOff = false
    @State private var error: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                if let credentials = engine.credentials {
                    SettingsDetailCard {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(status(at: context.date))
                                    .font(.system(size: 13))
                                    .themedForeground(.textPrimary)
                                if let lastError = engine.lastError {
                                    Text(lastError.localizedDescription)
                                        .font(.system(size: 12))
                                        .themedForeground(.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(MistSyncStrings.serverURL) {
                            Text(verbatim: credentials.serverURL)
                                .font(.system(size: 13))
                                .themedForeground(.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    section(MistAppID.clipboard.name) {
                        SettingsDetailCard {
                            SettingsDetailRow(MistSyncStrings.clipboardShare) {
                                Toggle("", isOn: Binding(get: { clipboard.sharing }, set: { clipboard.setSharing($0) }))
                                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).themedTint(.themeColor)
                            }
                        }
                    }
                    section(MistSyncStrings.pairingCode) {
                        SettingsDetailCard {
                            SettingsDetailRow(MistSyncStrings.pairingHint) {
                                if showPairing {
                                    Button(MistSyncStrings.copy) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(credentials.pairingCode, forType: .string)
                                    }
                                } else {
                                    Button(MistSyncStrings.showPairing) { showPairing = true }
                                }
                            }
                            if showPairing {
                                SettingsRowDivider()
                                Text(verbatim: credentials.pairingCode)
                                    .font(.system(size: 12, design: .monospaced))
                                    .themedForeground(.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                    Button(MistSyncStrings.turnOff, role: .destructive) { confirmingTurnOff = true }
                } else {
                    section(MistSyncStrings.serverURL) {
                        SettingsDetailCard {
                            fieldRow(placeholder: "https://", text: $serverURL,
                                     button: MistSyncStrings.setup, action: setup)
                        }
                    }
                    section(MistSyncStrings.pairingCode) {
                        SettingsDetailCard {
                            fieldRow(placeholder: "mist-sync:", text: $pairingCode,
                                     button: MistSyncStrings.join, action: join)
                        }
                    }
                }
                if let message = error ?? (engine.credentials == nil ? engine.lastError?.localizedDescription : nil) {
                    Text(message).font(.system(size: 12)).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .alert(MistSyncStrings.turnOffTitle, isPresented: $confirmingTurnOff) {
            Button(MistSyncStrings.turnOffConfirm, role: .destructive) {
                perform { try engine.turnOff(); showPairing = false; pairingCode = "" }
            }
            Button(MistSyncStrings.cancel, role: .cancel) {}
        } message: { Text(MistSyncStrings.turnOffMessage) }
    }

    /// Section title above its card, as in the General pane.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldRow(placeholder: String, text: Binding<String>, button: String,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            TextField(text: text, prompt: Text(verbatim: placeholder)) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(action)
            Button(button, action: action)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 12)
    }

    private func status(at date: Date) -> String {
        switch engine.status {
        case .connected:
            // The timeline's date can be up to 30 seconds old; a later sync must never read as a future time.
            let now = max(date, Date())
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            let relative = formatter.localizedString(for: min(engine.lastSynced ?? now, now), relativeTo: now)
            return String(format: MistSyncStrings.connected, relative)
        case .connecting: return MistSyncStrings.connecting
        case .off, .offline: return MistSyncStrings.offline
        }
    }

    private func setup() {
        perform {
            try engine.enable(MistSyncCredentials.create(serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)))
            showPairing = true
        }
    }

    private func join() {
        perform {
            try engine.enable(MistSyncCredentials.parse(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)))
            pairingCode = ""
        }
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
