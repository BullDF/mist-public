// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import Combine
import Settings

/// Tracks the context from which the Settings window was last presented so
/// individual panes can adapt their UI (e.g. hide app-wide preferences when
/// invoked from an incognito window).
@MainActor
final class SettingsPresentationState: ObservableObject {
    static let shared = SettingsPresentationState()

    @Published var openedFromIncognito: Bool = false

    private init() {}
}

/// The settings window's delegate: routes `windowShouldClose` to
/// `AppController.settingsWindowShouldClose(_:)`.
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AppController.shared.settingsWindowShouldClose(sender)
    }
}

extension AppController {

    private static let settingsWindowDelegate = SettingsWindowDelegate()
    
    private func panes() -> [SettingsPane] {
        let panes: [SettingsPane] =
        [GeneralSettingViewController(),
         ProfilesSettingViewController(),
         SpacesSettingViewController(),
         MistPasswordsSettingViewController(),
         MistMailSettingViewController(),
         MistDrifterSettingViewController(),
         MistSlackSettingViewController(),
         MistSyncSettingViewController(),
         ShortcutsSettingViewController(),
         AdvancedSettingViewController(),
        ]
        return panes
    }

    /// Returns the shared settings window controller, creating it on first access.
    /// Refreshes the presentation context (e.g. incognito source) on every call so
    /// individual panes see the right state regardless of which entry point was used.
    @discardableResult
    func ensureSettingsWindowController() -> SettingsWindowController {
        refreshSettingsPresentationState()

        if let existingController = settingsWindowController {
            return existingController
        }
        
        let controller = SettingsWindowController(panes: panes(),
                                                  style: .toolbarItems,
                                                  animated: false,
                                                  hidesToolbarForSingleItem: false)
        settingsWindowController = controller
        
        if let window = controller.window {
            window.delegate = AppController.settingsWindowDelegate
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKeyWhileSettingsOpen(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        
        return controller
    }

    private func refreshSettingsPresentationState() {
        Task { @MainActor in
            let isIncognito = SpaceSessionControllersManager.shared.activeWindowController?.browserState.isIncognito ?? false
            SettingsPresentationState.shared.openedFromIncognito = isIncognito
        }
    }
    
    /// Shows the settings window, optionally jumping to a specific pane.
    ///
    /// `SettingsWindowController.show(pane:)` re-centers the window and then
    /// restores the autosaved frame on every call. When the window is already
    /// on screen that discards any position the user dragged it to (the frame
    /// autosave can lag behind the move), so the popup visibly jumps. Capture
    /// the current top-left before showing and put it back afterwards; the
    /// top-left anchor keeps pane-switch height changes looking native.
    @discardableResult
    func showSettings(pane paneIdentifier: Settings.PaneIdentifier? = nil) -> SettingsWindowController {
        let controller = ensureSettingsWindowController()

        let visibleTopLeft: NSPoint? = {
            guard let window = controller.window, window.isVisible else { return nil }
            return NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }()

        // `SettingsWindowController.show(pane:)` only asks for cooperative
        // activation (`NSApp.activate()`), which macOS drops while another
        // application owns the foreground. That is the case for the Phi Chat
        // app shim: its settings entry travels through a phi://native deeplink
        // back into this process, so the window would open behind the shim.
        // Note who is losing the foreground before anything tries to take it.
        // Redisplays while Phi is active (a pane linking to another pane)
        // keep whatever source is on record.
        if !NSApp.isActive {
            settingsActivationSource = NSWorkspace.shared.frontmostApplication
        }

        controller.show(pane: paneIdentifier)

        if let visibleTopLeft {
            controller.window?.setFrameTopLeftPoint(visibleTopLeft)
        }

        // Only the legacy `activate(ignoringOtherApps:)` gets through: the
        // cooperative `NSRunningApplication.current.activate(options:)` was
        // declined here on macOS 26. It raises every Phi window, browser
        // windows included.
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)

        return controller
    }

    @MainActor
    @objc func showPreferences(_ sender: Any?) {
        let controller = showSettings()
        controller.window?.orderFront(self)
    }
    
    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindowController?.window else {
            return
        }
        
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: closingWindow
        )
        
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        
        settingsWindowController = nil
        settingsActivationSource = nil
    }

    /// `windowShouldClose` for the settings window. macOS leaves the
    /// foreground with whoever took it, so an app the window was opened over
    /// -- the Phi Chat shim, say -- would stay buried once it goes away; and
    /// closing the key window makes AppKit promote another Phi window to key
    /// and order it front, above that app, until the app is activated: that
    /// was the flash. So hand the foreground back first and close only once
    /// Phi has resigned active, when nothing gets promoted. One `activate()`,
    /// since `yieldActivation(to:)` only drops the foreground for an app that
    /// then activates itself, and the shim never asks. The source is already
    /// gone if the user moved on to a browser window meanwhile
    /// (`windowDidBecomeKeyWhileSettingsOpen`).
    func settingsWindowShouldClose(_ window: NSWindow) -> Bool {
        guard window === settingsWindowController?.window,
              let activationSource = settingsActivationSource,
              NSApp.isActive, !activationSource.isTerminated else {
            return true
        }
        settingsActivationSource = nil
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeSettingsWindowAfterHandoff),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        guard activationSource.activate() else {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
            return true
        }
        return false
    }

    @objc private func closeSettingsWindowAfterHandoff() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        settingsWindowController?.window?.close()
    }

    /// While the settings window is up, a browser window becoming key means
    /// the user has moved on to Phi: closing the settings window then leaves
    /// the foreground where it is instead of handing it back. Browser windows
    /// only: the panes run modal alerts and open panels, which become key too
    /// without the user going anywhere.
    @objc private func windowDidBecomeKeyWhileSettingsOpen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.windowController is SpaceSessionController else {
            return
        }
        settingsActivationSource = nil
    }
    
}
