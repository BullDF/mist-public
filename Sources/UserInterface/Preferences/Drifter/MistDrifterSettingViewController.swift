import AppKit
import Settings
import enum Settings.Settings
import SwiftUI

extension Settings.PaneIdentifier {
    static let mistDrifter = Self("mistDrifter")
}

/// Drifter's new-chat defaults: the model, effort and confirmation every new chat starts on.
final class MistDrifterSettingViewController: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier = .mistDrifter
    let paneTitle = MistAppID.drifter.name
    let toolbarItemIcon: NSImage = {
        // The logo is a white cutout, so as a template it takes the toolbar's tint like the symbols.
        let logo = NSImage(named: DrifterApp.logo) ?? NSImage()
        let width: CGFloat = 20, height = width * logo.size.height / max(1, logo.size.width)
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
            logo.draw(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height))
            return true
        }
        image.isTemplate = true
        return image
    }()

    override func loadView() {
        let host = ThemedHostingController(rootView: MistDrifterSettingsView())
        addChild(host)
        view = host.view
        view.setFrameSize(NSSize(width: 680, height: 561))
    }
}

private struct MistDrifterSettingsView: View {
    @StateObject private var settings = Self.makeSettings()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(Strings.newChats).font(.system(size: 12)).themedForeground(.textSecondary)
                VStack(alignment: .leading, spacing: 12) {
                    SettingsDetailCard {
                        SettingsDetailRow(Strings.model) {
                            menu(Binding(get: { settings.config.engine.rawValue + ":" + settings.config.model },
                                         set: { id in settings.models.first { $0.id == id }.map(settings.selectModel) })) {
                                ForEach(modelOptions) { Text(verbatim: $0.title).tag($0.id) }
                            }
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(Strings.effort) {
                            menu(Binding(get: { settings.config.effort }, set: settings.selectEffort)) {
                                ForEach(settings.efforts, id: \.self) { Text(ClaudeCodeEffort(rawValue: $0)?.title ?? $0.capitalized).tag($0) }
                            }
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(Strings.confirmation) {
                            menu(Binding(get: { settings.config.confirmation }, set: settings.selectConfirmation)) {
                                ForEach(DrifterConfirmation.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                    }
                    if let message = settings.codexMessage { note(message) }
                    note(Strings.hint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(36)
        }
        .controlSize(.regular)
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .task { await settings.refreshModels() }
    }

    private static func makeSettings() -> DrifterSettings {
        let saved = DrifterLaunchSettings()
        let settings = DrifterSettings(config: saved.config)
        settings.onChange = { saved.save($0) }
        return settings
    }

    /// The offered models, plus a saved one the catalogs don't list (yet, or any more).
    private var modelOptions: [DrifterModel] {
        guard settings.selectedModel == nil else { return settings.models }
        let config = settings.config
        return settings.models + [DrifterModel(engine: config.engine, model: config.model, title: settings.modelTitle,
                                               efforts: [config.effort], defaultEffort: config.effort)]
    }

    private func menu<Value: Hashable, Content: View>(_ selection: Binding<Value>, @ViewBuilder content: () -> Content) -> some View {
        Picker("", selection: selection, content: content)
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .themedForeground(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum Strings {
        static let newChats = NSLocalizedString("drifterSettings.newChats", value: "New Chats", comment: "Drifter settings - Section with the settings every new Drifter chat starts on")
        static let model = NSLocalizedString("browser.newTabPage.claudeCode.model", value: "Model", comment: "Claude Code - Accessibility label for the model selector")
        static let effort = NSLocalizedString("browser.newTabPage.claudeCode.effort", value: "Effort", comment: "Claude Code - Accessibility label for the reasoning effort selector")
        static let confirmation = NSLocalizedString("drifterSettings.confirmation", value: "Confirmation", comment: "Drifter settings - Row choosing whether agents ask before acting")
        static let hint = NSLocalizedString("drifterSettings.hint", value: "Every new chat starts with these settings. A change in a chat's composer applies to that chat only.", comment: "Drifter settings - Explains that the settings are new chats' defaults")
    }
}
