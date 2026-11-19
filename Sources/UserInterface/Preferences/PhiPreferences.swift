// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

extension UserDefaults {
    /// Returns the Bool for `key`, falling back to `default` when the key has never been set.
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard object(forKey: key) != nil else { return defaultValue }
        return bool(forKey: key)
    }
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case balanced     // vertical tabs + address bar at the top of webcontent
    case performance  // vertical tabs
    case comfortable  // horizontal tabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .performance:
            return NSLocalizedString("settings.general.layoutMode.performanceOption", value: "Performance", comment: "Layout option - Vertical tabs with address bar at side bar")
        case .balanced:
            return NSLocalizedString("settings.general.layoutMode.balancedOption", value: "Balanced", comment: "Layout option - Vertical tabs with address bar at the top of webcontent")
        case .comfortable:
            return NSLocalizedString("settings.general.layoutMode.comfortableOption", value: "Comfortable", comment: "Layout option - Horizontal tabs")
        }
    }

    var isTraditional: Bool { self == .comfortable }
    var showsNavigationAtTop: Bool { self != .performance }
}

/// Three-state auto picture-in-picture behavior. Stored as a single enum so
/// the illegal "off but parked" combination cannot be represented; Chromium
/// reads it through two bridge getters derived from the mode. Manual
/// picture-in-picture is unaffected in every mode.
enum AutoPictureInPictureMode: String, CaseIterable, Identifiable {
    case off     // never pop out automatically
    case normal  // pop out and stay where it appears (default)
    case parked  // pop out, then park at the screen edge until clicked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return NSLocalizedString("settings.advanced.pictureInPicture.offOption", value: "Off", comment: "Auto picture-in-picture option - never pop out automatically; manual picture-in-picture is unaffected")
        case .normal:
            return NSLocalizedString("settings.advanced.pictureInPicture.normalOption", value: "Normal", comment: "Auto picture-in-picture option - pop out and stay in place")
        case .parked:
            return NSLocalizedString("settings.advanced.pictureInPicture.parkAtEdgeOption", value: "Park at edge", comment: "Auto picture-in-picture option - pop out, then park at the screen edge until clicked")
        }
    }
}

/// The stored presentation preference is retained while the player is disabled.
enum SidebarMediaPresentationMode: String, CaseIterable, Identifiable {
    case alwaysExpanded
    case alwaysCompact
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysExpanded:
            return NSLocalizedString("settings.general.sidebarMedia.alwaysExpandedOption", value: "Always expanded", comment: "Sidebar media presentation option - Show the full player whenever background media is available")
        case .alwaysCompact:
            return NSLocalizedString("settings.general.sidebarMedia.alwaysCompactOption", value: "Always compact", comment: "Sidebar media presentation option - Keep transport controls compact without pointer or keyboard expansion")
        case .dynamic:
            return NSLocalizedString("settings.general.sidebarMedia.dynamicOption", value: "Auto", comment: "Mini Player display option - Expand after a brief pointer hover, or immediately using keyboard focus or VoiceOver")
        }
    }
}

enum PhiPreferences: String {
    case phiMainDebugMenuEnabled
    case phiLoginPhase
    case preferedUserName
    case accentColor
    case needImportDataFromOtherBrowsers

    static let fixedWindowBackground = ThemedColor { _, appearance in
        DefaultColors.windowBackground.color(for: appearance)
    }
}

extension PhiPreferences {
    enum GeneralSettings: String, CaseIterable {
        case openNewTabPageOnCmdT
        case navigationAtTop  // Whether to show navigation and address bar in content header (Layout 2)
        case traditionalLayout  // Traditional layout, show tabs and (maybe) bookmark bar at  top (Layout 3)
        case alwaysShowBookmarkBar // In traditional layout, always show bookmark bar below address bar
        case showBookmarkBarOnNewTabPage // In traditional layout, show bookmark bar on new tab page
        case alwaysShowURLPath // In address bar menu, always show full URL path
        case showTabPreviews // Whether open tabs use custom hover preview cards
        case sidebarMediaPlayerEnabled // Show controls for background page media
        case showOpenTabIndicators // Show dots on inactive open pinned tabs and bookmarks
        case showUnloadedTabIndicators // Show dashed outlines and smaller icons for unloaded or discarded tabs
        case spacesFeatureEnabled // Master gate for Spaces + profile management UI; defaults on, no user-facing toggle
        case suppressCloseIncognitoSpaceWarning // "Do not ask again" on the close-Incognito-Space confirmation
        case peekViewEnabled // Master gate for Peek View: the context-menu item and the automatic cross-site diversion
        case autoPeekViewEnabled // Sub-gate under peekViewEnabled: the automatic cross-site diversion from pinned/bookmark-bound tabs; explicit peeks are unaffected

        var defaultValue: Bool {
            switch self {
            case .openNewTabPageOnCmdT:
                return true
            case .navigationAtTop:
                return true
            case .traditionalLayout:
                return false
            case .alwaysShowBookmarkBar:
                return false
            case .showBookmarkBarOnNewTabPage:
                return true
            case .alwaysShowURLPath:
                return false
            case .showTabPreviews:
                return true
            case .sidebarMediaPlayerEnabled:
                return true
            case .showOpenTabIndicators:
                return false
            case .showUnloadedTabIndicators:
                return true
            case .spacesFeatureEnabled:
                return true
            case .suppressCloseIncognitoSpaceWarning:
                return false
            case .peekViewEnabled:
                return true
            case .autoPeekViewEnabled:
                return true
            }
        }

        func loadValue(from defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(forKey: rawValue, default: defaultValue)
        }

        static let sidebarMediaPresentationModeKey = "sidebarMediaPresentationMode"

        static func loadSidebarMediaPresentationMode(
            from defaults: UserDefaults = .standard
        ) -> SidebarMediaPresentationMode {
            defaults.string(forKey: sidebarMediaPresentationModeKey)
                .flatMap(SidebarMediaPresentationMode.init(rawValue:)) ?? .dynamic
        }

        static func saveSidebarMediaPresentationMode(
            _ mode: SidebarMediaPresentationMode,
            to defaults: UserDefaults = .standard
        ) {
            defaults.set(mode.rawValue, forKey: sidebarMediaPresentationModeKey)
        }

        static let autoPictureInPictureModeKey = "autoPictureInPictureMode"

        static func loadAutoPictureInPictureMode(
            from defaults: UserDefaults = .standard
        ) -> AutoPictureInPictureMode {
            if let rawValue = defaults.string(forKey: Self.autoPictureInPictureModeKey),
               let mode = AutoPictureInPictureMode(rawValue: rawValue) {
                return mode
            }
            return .normal
        }

        static func saveAutoPictureInPictureMode(
            _ mode: AutoPictureInPictureMode,
            to defaults: UserDefaults = .standard
        ) {
            defaults.set(mode.rawValue, forKey: Self.autoPictureInPictureModeKey)
        }

        static let layoutModeKey = "layoutMode"

        static func loadLayoutMode() -> LayoutMode {
            let defaults = UserDefaults.standard

            if let rawValue = defaults.string(forKey: Self.layoutModeKey),
               let mode = LayoutMode(rawValue: rawValue) {
                return mode
            }

            // Backward compatibility for old dual-bool encoding.
            let traditionalLayout = UserDefaults.standard.value(forKey: Self.traditionalLayout.rawValue) as? Bool
            let navigationAtTop = UserDefaults.standard.value(forKey: Self.navigationAtTop.rawValue) as? Bool
            if traditionalLayout == true {
                return .comfortable
            } else if navigationAtTop == true {
                return .balanced
            } else {
                // default value
                return .performance
            }
        }

        static func saveLayoutMode(_ mode: LayoutMode) {
            let defaults = UserDefaults.standard
            defaults.set(mode.rawValue, forKey: Self.layoutModeKey)
        }

        /// Duration of the cross-Space swap animation, in seconds. Drives the
        /// horizontal-layout slide and the vertical-layout sidebar tint
        /// cross-fade. The horizontal slide is the longer, more prominent
        /// motion; vertical's tint cross-fade is shorter.
        static func loadSwitchSpaceAnimationDuration() -> TimeInterval {
            // Debug override for inspecting the switch animation, in seconds:
            // `defaults write <bundle id> PhiSwitchSpaceAnimationDurationOverride -float 2`.
            let override = UserDefaults.standard.double(forKey: Self.switchSpaceAnimationDurationOverrideKey)
            if override > 0 {
                return override
            }
            return loadLayoutMode().isTraditional
                ? Self.horizontalSwitchSpaceAnimationDuration
                : Self.verticalSwitchSpaceAnimationDuration
        }

        static let switchSpaceAnimationDurationOverrideKey = "PhiSwitchSpaceAnimationDurationOverride"

        /// Cross-Space animation duration in the horizontal (Comfortable) layout.
        static let horizontalSwitchSpaceAnimationDuration: TimeInterval = 0.2
        /// Cross-Space animation duration in the vertical (Performance /
        /// Balanced) layouts.
        static let verticalSwitchSpaceAnimationDuration: TimeInterval = 0.1

    }
    
    
    // MARK: - Agent Spaces

    enum AgentSpaces {
        private static let cdpAgentAccessKey = "PhiCDPAgentAccessEnabled"
        private static let autoViewKey = "PhiAgentSpaceAutoView"

        /// View ▸ Agent Autoview: when `true`, the focused window follows the
        /// operating agent — a running agent Space is surfaced (watch mode)
        /// unless the user is already watching a running one, which is never
        /// preempted (see `AgentSpaceManager.autoViewReevaluate`). Default
        /// `false`.
        static var autoViewEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: autoViewKey) }
            set { UserDefaults.standard.set(newValue, forKey: autoViewKey) }
        }

        /// External agent access over the private socket; disabling disconnects live agents.
        static var cdpAgentAccessEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: cdpAgentAccessKey) }
            set { UserDefaults.standard.set(newValue, forKey: cdpAgentAccessKey) }
        }

    }

    // MARK: - Reader View

    enum Reader {
        private static let fontSizeKey = "PhiReaderFontSize"

        /// Body text size for the reader surface, in points. Set from the
        /// controls inside Reader View rather than from Settings, so it stays
        /// next to the text it changes. Clamped to the range the reader's
        /// fixed content column stays readable at.
        static var fontSize: Int {
            get {
                let stored = UserDefaults.standard.integer(forKey: Self.fontSizeKey)
                guard stored != 0 else {
                    return ReaderDocumentBuilder.defaultFontSize
                }
                return min(max(stored, ReaderDocumentBuilder.minFontSize),
                           ReaderDocumentBuilder.maxFontSize)
            }
            set {
                UserDefaults.standard.set(newValue, forKey: Self.fontSizeKey)
            }
        }

        private static let widthKey = "PhiReaderWidth"
        private static let themeKey = "PhiReaderTheme"
        private static let typefaceKey = "PhiReaderTypeface"
        private static let lineHeightKey = "PhiReaderLineHeight"
        private static let letterSpacingKey = "PhiReaderLetterSpacing"
        private static let showsImagesKey = "PhiReaderShowsImages"
        private static let highlightsLinksKey = "PhiReaderHighlightsLinks"

        /// Content column width. Set from inside Reader View, like the size.
        static var width: ReaderStyle.Width {
            get { read(Self.widthKey) ?? ReaderStyle.standard.width }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.widthKey) }
        }

        /// Reading background. Defaults to following the browser's appearance,
        /// which is what the reader did before there was a choice.
        static var theme: ReaderStyle.Theme {
            get { read(Self.themeKey) ?? ReaderStyle.standard.theme }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.themeKey) }
        }

        static var typeface: ReaderStyle.Typeface {
            get { read(Self.typefaceKey) ?? ReaderStyle.standard.typeface }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.typefaceKey) }
        }

        static var lineHeight: ReaderStyle.LineHeight {
            get { read(Self.lineHeightKey) ?? ReaderStyle.standard.lineHeight }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.lineHeightKey) }
        }

        static var letterSpacing: ReaderStyle.LetterSpacing {
            get { read(Self.letterSpacingKey) ?? ReaderStyle.standard.letterSpacing }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.letterSpacingKey) }
        }

        /// Read through `object(forKey:)` rather than `bool(forKey:)`: both
        /// default to false when nothing is stored, and these two default to
        /// on, so an untouched install must be told apart from a deliberate
        /// off rather than silently read as one.
        static var showsImages: Bool {
            get { readFlag(Self.showsImagesKey) ?? ReaderStyle.standard.showsImages }
            set { UserDefaults.standard.set(newValue, forKey: Self.showsImagesKey) }
        }

        static var highlightsLinks: Bool {
            get { readFlag(Self.highlightsLinksKey) ?? ReaderStyle.standard.highlightsLinks }
            set { UserDefaults.standard.set(newValue, forKey: Self.highlightsLinksKey) }
        }

        /// A stored value that no longer names a case — an older or newer
        /// build wrote it — falls back to the default rather than failing.
        private static func read<T: RawRepresentable>(_ key: String) -> T?
        where T.RawValue == String {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
            return T(rawValue: raw)
        }

        private static func readFlag(_ key: String) -> Bool? {
            UserDefaults.standard.object(forKey: key) as? Bool
        }
    }

    // MARK: - Theme Settings

    enum ThemeSettings: String, CaseIterable {
        /// User-selected appearance mode. `0 = system`, `1 = light`, `2 = dark`.
        case userAppearanceChoice = "PhiUserAppearanceChoice"
        /// Current theme identifier.
        case currentThemeId = "PhiCurrentThemeId"
        /// Archived snapshots for themes customized by the user.
        case themeSnapshots = "PhiThemeSnapshots"
        /// When `true`, the Mirage extension applies the window theme's accent
        /// to `::selection` on every web page; when `false`, it leaves the
        /// page's native selection color alone. Default `true`.
        case selectionTintEnabled = "PhiSelectionTintEnabled"

        var defaultValue: Any {
            switch self {
            case .userAppearanceChoice:
                return 0  // .system
            case .currentThemeId:
                return "default"
            case .themeSnapshots:
                return Data()
            case .selectionTintEnabled:
                return true
            }
        }
        
    }

    // MARK: - Password Manager Settings

    enum PasswordManagerSettings: String, CaseIterable {
        case autoInstallICloudPasswords

        var defaultValue: Bool {
            switch self {
            case .autoInstallICloudPasswords:
                return false
            }
        }

        func loadValue() -> Bool {
            UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        /// Whether the user's choice has ever been recorded — distinguishes a
        /// real `false` from "never set", which gates the existing-user backfill.
        var isSet: Bool {
            UserDefaults.standard.object(forKey: rawValue) != nil
        }

        func save(_ value: Bool) {
            UserDefaults.standard.set(value, forKey: rawValue)
        }
    }
}
