// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage(PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue)
    private var alwaysShowURLPath: Bool = PhiPreferences.GeneralSettings.alwaysShowURLPath.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.showTabPreviews.rawValue)
    private var showTabPreviews: Bool = PhiPreferences.GeneralSettings.showTabPreviews.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.showOpenTabIndicators.rawValue)
    private var showOpenTabIndicators = PhiPreferences.GeneralSettings.showOpenTabIndicators.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.showUnloadedTabIndicators.rawValue)
    private var showUnloadedTabIndicators = PhiPreferences.GeneralSettings.showUnloadedTabIndicators.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
    private var autoPictureInPictureModeRawValue: String = PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode().rawValue

    @AppStorage(PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue)
    private var playerEnabled = PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.sidebarMediaPresentationModeKey)
    private var presentationModeRawValue = SidebarMediaPresentationMode.dynamic.rawValue

    @AppStorage(PhiPreferences.GeneralSettings.peekViewEnabled.rawValue)
    private var peekViewEnabled: Bool = PhiPreferences.GeneralSettings.peekViewEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue)
    private var autoPeekViewEnabled: Bool = PhiPreferences.GeneralSettings.autoPeekViewEnabled.defaultValue

    // Backed by Chromium local state through the bridge, not @AppStorage: the
    // cold-start path reads the same pref, so it is the single source of truth.
    @State private var restoreLastSessionEnabled = SessionRestorePreference.isEnabled

    private var restoreLastSessionHint: String {
        restoreLastSessionEnabled
            ? NSLocalizedString("settings.advanced.restoreLastSession.enabledHint", value: "Reopen your windows and tabs the next time you open Phi.", comment: "Advanced settings - Hint shown when restore-last-session is on")
            : NSLocalizedString("settings.advanced.restoreLastSession.disabledHint", value: "Phi starts with a new window. Closing a window may sign you out of some sites.", comment: "Advanced settings - Hint shown when restore-last-session is off, noting session cookies may be cleared when a window closes")
    }

    private var selectedAutoPipMode: Binding<AutoPictureInPictureMode> {
        Binding(
            get: {
                AutoPictureInPictureMode(rawValue: autoPictureInPictureModeRawValue)
                    ?? PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode()
            },
            set: { mode in
                autoPictureInPictureModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode)
            }
        )
    }

    private var selectedMiniPlayerMode: Binding<SidebarMediaPresentationMode?> {
        Binding(
            get: {
                playerEnabled ? (SidebarMediaPresentationMode(rawValue: presentationModeRawValue) ?? .dynamic) : nil
            },
            set: { mode in
                if let mode {
                    presentationModeRawValue = mode.rawValue
                    playerEnabled = true
                } else {
                    playerEnabled = false
                }
            }
        )
    }

    private var miniPlayerLabel: String {
        NSLocalizedString("settings.advanced.miniPlayer.title", value: "Mini Player",
                          comment: "Advanced settings - Menu for turning Mini Player off or choosing its display mode")
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                peekSection
                AdvancedSettingsSection(title: NSLocalizedString("settings.advanced.tabs.sectionTitle", value: "Tabs and address bar", comment: "Advanced settings - Section title for the tab and address bar options")) {
                    pageCard
                }
                AdvancedSettingsSection(title: NSLocalizedString("settings.advanced.startup.sectionTitle", value: "On startup", comment: "Advanced settings - Section title for the restore-last-session option")) {
                    browsingCard
                }
                AdvancedSettingsSection(title: NSLocalizedString("settings.advanced.media.sectionTitle", value: "Media", comment: "Advanced settings - Section title for the Mini Player and picture-in-picture options")) {
                    mediaCard
                }
                AgentControlSectionView()
                urlRulesSection
                AdvancedSettingsSection(title: NSLocalizedString("settings.advanced.other.sectionTitle", value: "Other", comment: "Advanced settings - Section title for the link to the additional browser settings")) {
                    additionalSettingsCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }

    private var peekSection: some View {
        AdvancedSettingsSection(
            title: NSLocalizedString("settings.navigations.peek.sectionTitle", value: "Peek", comment: "Navigations settings - Peek section title"),
            description: NSLocalizedString("settings.navigations.peek.sectionDescription", value: "Preview a link without opening it in a new tab.", comment: "Navigations settings - Description of the Peek feature")
        ) {
            SettingsDetailCard {
                AdvancedSettingsToggleRow(
                    title: NSLocalizedString("settings.navigations.peek.enableToggle.title", value: "Enable Peek View", comment: "Navigations settings - Toggle title for enabling Peek View"),
                    description: NSLocalizedString("settings.navigations.peek.enableToggle.description", value: "Shift-click a link, or choose “Open Link in Peek View”, to preview it in a floating panel over the page. Not available in the Comfortable layout.", comment: "Navigations settings - Explanation of the Peek View toggle"),
                    isOn: $peekViewEnabled,
                    onChange: { enabled in
                        // The automatic sub-toggle follows the master's
                        // transitions: enabling Peek View re-enables it,
                        // disabling Peek View switches it off.
                        autoPeekViewEnabled = enabled
                    }
                )

                SettingsRowDivider()

                AdvancedSettingsToggleRow(
                    title: NSLocalizedString("settings.navigations.peek.autoToggle.title", value: "Automatically peek from pinned tabs and bookmarks", comment: "Navigations settings - Toggle title for automatically opening cross-site links from pinned tabs and bookmarks in Peek View"),
                    description: NSLocalizedString("settings.navigations.peek.autoToggle.description", value: "Links that leave a pinned tab’s or bookmark’s site open in a Peek panel instead of a new tab.", comment: "Navigations settings - Explanation of the automatic Peek View toggle for pinned tabs and bookmarks"),
                    isOn: $autoPeekViewEnabled,
                    onChange: { _ in }
                )
                .disabled(!peekViewEnabled)
                .opacity(peekViewEnabled ? 1.0 : 0.4)
            }
        }
    }

    private var urlRulesSection: some View {
        AdvancedSettingsSection(
            title: NSLocalizedString("settings.navigations.urlRules.sectionTitle", value: "URL Rules", comment: "Navigations settings - URL Rules section title")
        ) {
            SettingsDetailCard {
                Button {
                    AppController.shared?.openURLRulesEditor(nil)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("settings.navigations.urlRules.openButton", value: "Manage URL Rules\u{2026}", comment: "Navigations settings - Title of the row that opens the URL Rules editor"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Text(NSLocalizedString("settings.navigations.urlRules.sectionDescription", value: "Route matching domains or URLs to a Space or Incognito.", comment: "Navigations settings - Description below the URL Rules editor row title"))
                                .font(.system(size: 11))
                                .themedForeground(.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .themedForeground(.textSecondary)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pageCard: some View {
        SettingsDetailCard {
            SettingsDetailRow(NSLocalizedString("settings.advanced.addressBar.showFullURLToggle", value: "Always show full URL", comment: "Advanced settings - Toggle title for always showing full URL in address bar")) {
                Toggle("", isOn: $alwaysShowURLPath)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }

            Divider()

            SettingsDetailRow(NSLocalizedString("settings.advanced.tabPreview.showToggle", value: "Show a preview card when hovering over a tab", comment: "Advanced settings - Toggle title for showing custom preview cards when hovering over open tabs")) {
                Toggle("", isOn: $showTabPreviews)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.openTabIndicators.showToggle", value: "Show open tab indicators", comment: "Advanced settings - Toggle title for showing dots on inactive open pinned tabs and bookmarks"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.openTabIndicators.description", value: "Show a dot on inactive pinned tabs and bookmarks that are currently open.", comment: "Advanced settings - Explains which tabs and bookmarks display the open-state dot"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $showOpenTabIndicators)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.unloadedTabIcons.showToggle", value: "Show unloaded tab indicators", comment: "Advanced settings - Toggle title for marking tabs whose pages are unloaded from memory"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.unloadedTabIcons.description", value: "Show a dashed outline around tab icons when their pages are unloaded from memory.", comment: "Advanced settings - Explains the dashed outline on icons of tabs whose pages are unloaded from memory"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $showUnloadedTabIndicators)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var browsingCard: some View {
        SettingsDetailCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.restoreLastSession.toggle", value: "Restore last session", comment: "Advanced settings - Row title for the app-level restore-previous-session toggle"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(restoreLastSessionHint)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $restoreLastSessionEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .themedTint(.themeColor)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: restoreLastSessionEnabled) { _, newValue in
                SessionRestorePreference.isEnabled = newValue
            }
        }
    }

    private var mediaCard: some View {
        SettingsDetailCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(miniPlayerLabel)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.advanced.sidebarMedia.hint", value: "Control media playing in background tabs from the sidebar.",
                                           comment: "Advanced settings - Description of Mini Player controls in the sidebar for media playing in background tabs"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: selectedMiniPlayerMode) {
                    Text(NSLocalizedString("settings.advanced.miniPlayer.offOption", value: "Off",
                                           comment: "Mini Player display option - Hide the player while media continues playing"))
                        .tag(Optional<SidebarMediaPresentationMode>.none)
                    ForEach([SidebarMediaPresentationMode.dynamic, .alwaysExpanded, .alwaysCompact]) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(miniPlayerLabel)
                .accessibilityIdentifier("settings.sidebarMedia.presentation")
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.advanced.pictureInPicture.title", value: "Auto picture-in-picture", comment: "Advanced settings - Row title for the three-state auto picture-in-picture mode"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(autoPipModeHint(for: selectedAutoPipMode.wrappedValue))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                }
                Spacer(minLength: 12)
                Picker("", selection: selectedAutoPipMode) {
                    ForEach(AutoPictureInPictureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var additionalSettingsCard: some View {
        SettingsDetailCard {
            Button(action: handleAdditionalBrowserSettingsTap) {
                SettingsDetailRow(NSLocalizedString("settings.advanced.additionalBrowserSettings.title", value: "Additional browser settings", comment: "Advanced settings - Title for always more settings")) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .themedForeground(.textSecondary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func autoPipModeHint(for mode: AutoPictureInPictureMode) -> String {
        switch mode {
        case .off:
            return NSLocalizedString("settings.advanced.pictureInPicture.offDescription", value: "Never pop out automatically; manual picture-in-picture still works", comment: "Advanced settings - Hint for the Off auto picture-in-picture mode")
        case .normal:
            return NSLocalizedString("settings.advanced.pictureInPicture.normalDescription", value: "Pop out playing video when you switch tabs or apps", comment: "Advanced settings - Hint for the Normal auto picture-in-picture mode")
        case .parked:
            return NSLocalizedString("settings.advanced.pictureInPicture.parkAtEdgeDescription", value: "Pop out playing video, parked at the screen edge until you click it", comment: "Advanced settings - Hint for the Park at edge auto picture-in-picture mode")
        }
    }

    private func handleAdditionalBrowserSettingsTap() {
        SpaceSessionControllersManager
            .shared
            .activeWindowController?
            .browserState
            .createTab("chrome://settings")
    }
}

private struct AdvancedSettingsSection<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AdvancedSettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void

    init(
        title: String,
        description: String? = nil,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.onChange = onChange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isOn) { _, newValue in
            onChange(newValue)
        }
    }
}

private struct AgentControlSectionView: View {
    @State private var enabled = PhiPreferences.AgentSpaces.cdpAgentAccessEnabled

    var body: some View {
        AdvancedSettingsSection(title: NSLocalizedString("settings.advanced.agentControl.sectionTitle", value: "Agent control", comment: "Advanced settings - Section title for the agent control switch")) {
            SettingsDetailCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("settings.developer.agentControl.enableToggle", value: "Allow agents to control Phi (CDP)", comment: "Advanced settings - Agent control toggle title"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("settings.advanced.agentControl.description", value: "Lets agent tools on this Mac (Claude Code, Codex) drive Phi over the DevTools Protocol through a private socket, without asking. Turning this off disconnects them right away. Drifter works either way.", comment: "Advanced settings - Explains local agent control and its switch"))
                            .font(.system(size: 11))
                            .themedForeground(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .themedTint(.themeColor)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: enabled) { _, newValue in
            AgentCDPListener.shared.setEnabled(newValue)
        }
    }
}
