import AppKit
import SwiftUI

/// The Mist apps' design kit: one quiet, Apple-like language that every app page draws from (#73).
///
/// This file holds the tokens: colors, metrics, type and elevation. The components in this folder draw only from
/// them, in SwiftUI and, where AppKit pages need them, as AppKit views. Colors are themed grayscale except the theme
/// color, the only accent: primary buttons, unread dots, focus and drop highlights, progress.
enum MistKit {
    enum Radius {
        /// A page's one hero card (the Clipboard box).
        static let heroCard: CGFloat = 24
        /// A content card (a shared item, a message).
        static let card: CGFloat = 16
        /// The card a page's text input sits in (a composer).
        static let input: CGFloat = 20
        /// A card inside a card, or a file row.
        static let innerCard: CGFloat = 12
        static let dropZone: CGFloat = 16
        static let sidebarRow: CGFloat = 10
        static let listRow: CGFloat = 14
        /// A form field's well; search fields are capsules.
        static let field: CGFloat = 8
        /// An icon tile's corners: 11 at 38 pt, 8 at 28.
        static func tile(_ side: CGFloat) -> CGFloat { (side * 0.29).rounded() }
    }

    /// The unread dot's diameter.
    static let dotSide: CGFloat = 7
    /// A hollow dot's ring.
    static let dotRingWidth: CGFloat = 1.5
    /// The outline of every outlined surface (cards, the composer, field wells, file cards, transcript cards), in
    /// `mistHairline`: a full point reads in both appearances, and the soft color keeps it from looking heavy.
    static let borderWidth: CGFloat = 1
    static let disabledOpacity: CGFloat = 0.35
    /// An icon button's opacity while pressed.
    static let pressedOpacity: CGFloat = 0.75
    /// A page's content column never grows past this.
    static let readableWidth: CGFloat = 640
}

// MARK: - Colors

/// Kit colors that no existing token covers, named for what they paint. Text uses `.textPrimary`, `.textSecondary`
/// and `.textTertiary`; the accent is `.themeColor`, and filled buttons use `.themeButtonBackground`, which is the theme
/// color in every theme but Pure, where it's Pure's monochrome swatch.
extension ThemedColor {
    /// Secondary pills, search fields, chips and icon tiles.
    static let mistChipFill = ThemedColor.separator
    /// A selected sidebar or list row, and a pressed secondary pill: gray, never the accent.
    static let mistSelectedFill = ThemedColor(light: NSColor.black.withAlphaComponent(0.075),
                                              dark: NSColor.white.withAlphaComponent(0.1))
    /// A row or icon button under the pointer.
    static let mistHoverFill = ThemedColor.hover
    /// Outlines, drawn `MistKit.borderWidth` wide, and pane dividers.
    static let mistHairline = ThemedColor.border
    /// A page's sidebar, a shade off the page.
    static let mistSidebarFill = ThemedColor(light: NSColor.black.withAlphaComponent(0.02),
                                             dark: NSColor.white.withAlphaComponent(0.025))
    /// Cards: white on a light page, a step lighter than a dark page so they lift off it.
    static let mistCardFill = ThemedColor { theme, appearance in
        guard appearance.isDark else { return .white }
        let page = theme.color(for: .windowBackground, appearance: appearance).withAlphaComponent(1)
        return page.blended(withFraction: 0.05, of: .white) ?? page
    }
    /// A drop zone's faint tint; `mistDropFillActive` while it has focus or a drag is over it.
    static let mistDropFill = ThemedColor { theme, appearance in
        theme.color(for: .themeColor, appearance: appearance).withAlphaComponent(appearance.isDark ? 0.07 : 0.04)
    }
    static let mistDropFillActive = ThemedColor { theme, appearance in
        theme.color(for: .themeColor, appearance: appearance).withAlphaComponent(appearance.isDark ? 0.12 : 0.08)
    }
    /// A drop zone's dashed border at rest; it turns `.themeColor` with focus or a drag.
    static let mistDropBorder = ThemedColor { theme, appearance in
        theme.color(for: .themeColor, appearance: appearance).withAlphaComponent(appearance.isDark ? 0.6 : 0.55)
    }
    /// A focused field's ring.
    static let mistFocusRing = ThemedColor { theme, appearance in
        theme.color(for: .themeColor, appearance: appearance).withAlphaComponent(0.55)
    }
    /// Selected text in the apps' text views and fields, where macOS would use its highlight color (the accent's).
    static let mistTextSelection = ThemedColor { theme, appearance in
        theme.color(for: .themeColor, appearance: appearance).withAlphaComponent(appearance.isDark ? 0.45 : 0.28)
    }
    /// Error lines.
    static let mistError = ThemedColor(.systemRed)
    /// A status waiting for the user's input, matching the sidebar.
    static let mistAttention = ThemedColor(.systemOrange)
    /// A count badge on an icon (`MistBadge`), red like the Dock's and the sidebar's.
    static let mistBadgeFill = ThemedColor(.systemRed)
    /// A completed status dot.
    static let mistSuccess = ThemedColor(.systemGreen)
}

// MARK: - Type

/// A kit text style: size, weight and color, with tracking only on the page title.
struct MistTextStyle {
    let size: CGFloat
    let weight: NSFont.Weight
    let color: ThemedColor
    var tracking: CGFloat = 0
    var monospacedDigits = false

    /// A single-column page's title, under its glyph.
    static let pageTitle = MistTextStyle(size: 27, weight: .bold, color: .textPrimary, tracking: -0.4)
    /// A page's subtitle and a drop zone's prompt.
    static let lead = MistTextStyle(size: 14.5, weight: .regular, color: .textSecondary)
    /// A column or list title.
    static let title = MistTextStyle(size: 20, weight: .bold, color: .textPrimary)
    /// A card's title (a message's subject).
    static let cardTitle = MistTextStyle(size: 18, weight: .bold, color: .textPrimary)
    /// A header bar's title, such as a chat's name.
    static let headerTitle = MistTextStyle(size: 15, weight: .bold, color: .textPrimary)
    /// An item's name in a card or row.
    static let headline = MistTextStyle(size: 14, weight: .semibold, color: .textPrimary)
    static let body = MistTextStyle(size: 13.5, weight: .regular, color: .textPrimary)
    /// A sidebar row's title.
    static let rowTitle = MistTextStyle(size: 13.5, weight: .medium, color: .textPrimary)
    /// A list row's first line.
    static let rowHeadline = MistTextStyle(size: 13, weight: .semibold, color: .textPrimary)
    /// A list row's second line (a message's subject).
    static let rowSubheadline = MistTextStyle(size: 12.5, weight: .medium, color: .textPrimary)
    /// Subtitles, metadata and a list row's preview.
    static let secondary = MistTextStyle(size: 12, weight: .regular, color: .textSecondary)
    /// Times and small trailing details.
    static let detail = MistTextStyle(size: 11, weight: .regular, color: .textTertiary)
    /// A sidebar row's count.
    static let count = MistTextStyle(size: 11.5, weight: .regular, color: .textSecondary, monospacedDigits: true)
    static let sectionHeader = MistTextStyle(size: 12, weight: .semibold, color: .textTertiary)
    /// A line saying there's nothing here, or what's loading.
    static let placeholder = MistTextStyle(size: 13.5, weight: .regular, color: .textTertiary)
    static let error = MistTextStyle(size: 12, weight: .regular, color: .mistError)
    /// Pill buttons; the button picks the color.
    static let button = MistTextStyle(size: 13, weight: .semibold, color: .textPrimary)

    var nsFont: NSFont {
        monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
    var font: Font {
        let font = Font.system(size: size, weight: Font.Weight(weight))
        return monospacedDigits ? font.monospacedDigit() : font
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}

extension View {
    /// Sets a kit text style's font, color and tracking.
    func mistText(_ style: MistTextStyle) -> some View {
        font(style.font).tracking(style.tracking).themedForeground(style.color)
    }
}

extension NSTextField {
    /// A one-line label in a kit text style.
    static func mistLabel(_ text: String = "", style: MistTextStyle) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.applyMistStyle(style)
        return label
    }
    /// A wrapping label in a kit text style; never selectable unless asked, so a click goes to its row. A selectable
    /// one shows its selection in the kit's color (`MistSelectableLabel`).
    static func mistWrappingLabel(_ text: String = "", style: MistTextStyle, selectable: Bool = false) -> NSTextField {
        let label = selectable ? MistSelectableLabel(wrappingLabelWithString: text) : NSTextField(wrappingLabelWithString: text)
        label.isSelectable = selectable
        label.applyMistStyle(style)
        return label
    }
    /// Gives a field a kit text style. The color binds through `NSTextField`, so a later `phi.setTextColor` on the
    /// field replaces it rather than fighting it. AppKit labels carry no tracking; only the page title has any, and
    /// `MistPageHeaderView` sets it.
    func applyMistStyle(_ style: MistTextStyle) {
        font = style.nsFont
        let field: NSTextField = self
        field.phi.setTextColor(style.color)
    }
}

// MARK: - Elevation

/// How far a surface floats off the page: two soft shadows, tighter in dark mode's deeper black.
enum MistElevation {
    case flat, card, hero

    struct Shadow {
        let y: CGFloat
        /// The CSS blur, twice the shadow radius that SwiftUI and Core Animation take.
        let blur: CGFloat
        let lightOpacity: CGFloat
        let darkOpacity: CGFloat
        func opacity(_ appearance: Appearance) -> CGFloat { appearance.isDark ? darkOpacity : lightOpacity }
    }

    /// Tight first, wide second.
    var shadows: [Shadow] {
        switch self {
        case .flat: []
        case .card: [Shadow(y: 1, blur: 3, lightOpacity: 0.05, darkOpacity: 0.4),
                     Shadow(y: 8, blur: 24, lightOpacity: 0.05, darkOpacity: 0.35)]
        case .hero: [Shadow(y: 2, blur: 10, lightOpacity: 0.05, darkOpacity: 0.4),
                     Shadow(y: 18, blur: 50, lightOpacity: 0.13, darkOpacity: 0.5)]
        }
    }
}

// MARK: - Motion

/// How a list moves when its rows come, go or change places: a row that leaves or joins fades (`mistListRow`) while
/// the rows around it settle into place, and a row that moves slides to its new place, over the rows it passes when it
/// moves up (`mistListPosition`). Only those changes animate; a row updating in place never does, so a list fed by a
/// streaming source animates no more often than its rows come, go or move.
enum MistMotion {
    static let listChange: Animation = .easeInOut(duration: 0.3)

    /// Applies a change to a list's rows, animated unless `animated` is false or Reduce Motion is on.
    @MainActor static func changeList(animated: Bool = true, _ change: () -> Void) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return change() }
        withAnimation(listChange, change)
    }
}

extension AnyTransition {
    /// A list row (or card) joining or leaving a list changed through `MistMotion.changeList`. It fades only while its
    /// gap is open: a leaving row is gone halfway through, before its neighbors close over it, and a joining row shows
    /// from halfway, once they've made room. Rows without their own fill would otherwise show through each other. An
    /// unanimated change shows or hides the row at once.
    static let mistListRow: AnyTransition = .modifier(active: MistListRowFade(progress: 0),
                                                      identity: MistListRowFade(progress: 1))
}

private struct MistListRowFade: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { content.opacity(max(0, progress * 2 - 1)) }
}

extension View {
    /// A list row's index in a list changed through `MistMotion.changeList`. While a change slides the row up, it
    /// rides above the rows it passes, which slide down under it; at rest it layers like any other row, so its shadow
    /// never falls on the row below. Its text updates in place rather than crossfading: a crossfade draws the new text
    /// at the row's destination while the row is still sliding there.
    func mistListPosition(_ index: Int) -> some View {
        modifier(MistListPosition(position: Double(index), index: Double(index)))
    }
}

private struct MistListPosition: ViewModifier, Animatable {
    /// Where the row is drawn: animated from its old index to `index` while the list's change runs.
    var position: Double
    let index: Double
    var animatableData: Double {
        get { position }
        set { position = newValue }
    }
    func body(content: Content) -> some View { content.contentTransition(.identity).zIndex(position > index ? 1 : 0) }
}
