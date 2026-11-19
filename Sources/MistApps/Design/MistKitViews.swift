import AppKit
import SwiftUI

// MARK: - Glyphs

/// An app or state glyph: a template asset, a thin SF Symbol, or an original-color app logo.
enum MistGlyph {
    case asset(String)
    case symbol(String)
    /// An app logo asset, drawn in its original colors.
    case image(String)

    var nsImage: NSImage? {
        switch self {
        case let .asset(name), let .image(name): NSImage(named: name)
        case let .symbol(name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }
}

private struct MistGlyphImage: View {
    let glyph: MistGlyph
    let side: CGFloat

    var body: some View {
        switch glyph {
        case let .asset(name):
            Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: side, height: side)
        case let .image(name):
            Image(name).renderingMode(.original).resizable().scaledToFit().frame(width: side, height: side)
        case let .symbol(name):
            Image(systemName: name).font(.system(size: side * 0.85, weight: .thin)).frame(width: side, height: side)
        }
    }
}

// MARK: - Page header and states

/// A single-column page's header: a thin glyph, a large bold title and one centered subtitle line.
struct MistPageHeader: View {
    static let glyphSide: CGFloat = 40
    let glyph: MistGlyph
    let title: String
    var subtitle: String?
    /// The glyph's square; larger app logos can share the page header's typography.
    var glyphSide: CGFloat = MistPageHeader.glyphSide
    struct Action {
        let title: String
        let symbol: String
        let handler: () -> Void
    }
    var action: Action?

    var body: some View {
        VStack(spacing: 0) {
            MistGlyphImage(glyph: glyph, side: glyphSide).themedForeground(.textPrimary)
            Text(title).mistText(.pageTitle).multilineTextAlignment(.center).padding(.top, 14)
            if let action {
                Button(action: action.handler) { Label(action.title, systemImage: action.symbol) }
                    .buttonStyle(.mist(.secondary, size: .regular)).padding(.top, 16)
            }
            if let subtitle {
                Text(subtitle).mistText(.lead).lineSpacing(4).multilineTextAlignment(.center)
                    .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        }
    }
}

/// A page that can't show its content yet (not set up, turned off): the page header with one primary action.
struct MistUnavailableState: View {
    let glyph: MistGlyph
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            MistPageHeader(glyph: glyph, title: title, subtitle: message)
            Button(actionTitle, action: action).buttonStyle(.mistPrimary)
        }
    }
}

/// A quiet centered line for an empty or loading area, with an optional spinner and secondary action.
struct MistPlaceholder: View {
    let message: String
    var loading = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if loading { ProgressView().controlSize(.small) }
            Text(message).mistText(.placeholder).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.mist(.secondary, size: .regular))
            }
        }
    }
}

/// A notice across the top of a pane: a message and an optional action, on a chip-fill strip.
struct MistNotice: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(message).mistText(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.mist(.secondary, size: .regular))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background { RoundedRectangle(cornerRadius: MistKit.Radius.innerCard, style: .continuous).themedFill(.mistChipFill) }
    }
}

/// A sidebar or list section's header.
struct MistSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).mistText(.sectionHeader).lineLimit(1)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Surfaces

/// The kit's cards. The page's hero card floats highest; a content card holds one item; an inner card is a file row
/// or a card inside a card, outlined but flat.
enum MistCardStyle {
    case hero, content, inner
    /// The card a page's text input sits in (a composer).
    case input
    /// An input or list card floating over other content rather than on a page (the ⌘L panel, Mail's recipient
    /// suggestions): it lifts as high as a hero.
    case floatingInput

    var radius: CGFloat {
        switch self {
        case .hero: MistKit.Radius.heroCard
        case .content: MistKit.Radius.card
        case .input, .floatingInput: MistKit.Radius.input
        case .inner: MistKit.Radius.innerCard
        }
    }
    var elevation: MistElevation {
        switch self {
        case .hero, .floatingInput: .hero
        case .content, .input: .card
        case .inner: .flat
        }
    }
    /// The padding `MistCard` puts around its content.
    var padding: EdgeInsets {
        switch self {
        case .hero: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        case .content, .input, .floatingInput: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        case .inner: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
        }
    }
}

/// A card's surface alone: fill, hairline and shadows. The shadows belong to the shape: on a composed card they
/// would also blur every child.
struct MistCardSurface: View {
    var style: MistCardStyle = .content
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        shape.themedFill(.mistCardFill)
            .mistShadow(style.elevation)
            .overlay { shape.strokeBorder(ThemedColor.mistHairline.swiftUIColor(theme: theme, appearance: appearance), lineWidth: MistKit.borderWidth) }
    }
}

/// Content on a kit card, padded by its style.
struct MistCard<Content: View>: View {
    var style: MistCardStyle = .content
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(style.padding).background { MistCardSurface(style: style) }
    }
}

extension View {
    /// Puts the view on a kit card's surface, without padding.
    func mistCardBackground(_ style: MistCardStyle = .content) -> some View { background { MistCardSurface(style: style) } }
    /// The elevation's two soft shadows.
    func mistShadow(_ elevation: MistElevation) -> some View { modifier(MistShadowModifier(elevation: elevation)) }
}

private struct MistShadowModifier: ViewModifier {
    let elevation: MistElevation
    @Environment(\.phiAppearance) private var appearance

    func body(content: Content) -> some View {
        let shadows = elevation.shadows
        if shadows.count == 2 {
            content
                .shadow(color: .black.opacity(shadows[0].opacity(appearance)), radius: shadows[0].blur / 2, y: shadows[0].y)
                .shadow(color: .black.opacity(shadows[1].opacity(appearance)), radius: shadows[1].blur / 2, y: shadows[1].y)
        } else {
            content
        }
    }
}

extension View {
    /// A drop zone inside a hero card: a dashed border on a faint tint. Focus deepens the tint and colors the dashes;
    /// a drag over it turns the border solid.
    func mistDropZone(focused: Bool, targeted: Bool) -> some View { modifier(MistDropZoneModifier(focused: focused, targeted: targeted)) }
}

private struct MistDropZoneModifier: ViewModifier {
    let focused: Bool
    let targeted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MistKit.Radius.dropZone, style: .continuous)
        content
            .background { shape.themedFill(focused || targeted ? .mistDropFillActive : .mistDropFill) }
            .overlay {
                shape.strokeBorder(style: targeted ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .themedForeground(focused || targeted ? .themeColor : .mistDropBorder)
            }
    }
}

/// An empty drop zone's prompt: a glyph above a centered line.
struct MistDropPrompt: View {
    var symbol = "arrow.down.doc"
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).themedForeground(.textTertiary)
            Text(text).mistText(.lead).lineSpacing(3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A rounded square in the chip fill holding a glyph, an app logo, a file's icon or a thumbnail.
struct MistIconTile: View {
    enum Content {
        case symbol(String)
        /// A template image, such as an app's glyph, in the primary ink like a symbol.
        case glyph(NSImage)
        /// A file's icon, inset in the tile.
        case icon(NSImage)
        /// A full-color app logo, aspect-fit within the chip.
        case logo(NSImage)
        /// An image filling the tile.
        case thumbnail(NSImage)
    }
    static let defaultSide: CGFloat = 38
    /// The share of the side a logo spans: wide logos stay legible in small tiles.
    static let logoFraction: CGFloat = 0.8
    /// The share of the side a glyph spans.
    static let glyphFraction: CGFloat = 0.5
    let content: Content
    var side = MistIconTile.defaultSide
    /// Outlines the tile, like a card, where it stands alone on the page (a launcher tile).
    var outlined = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MistKit.Radius.tile(side), style: .continuous)
        Group {
            switch content {
            case let .symbol(name):
                Image(systemName: name).font(.system(size: side * 0.45, weight: .regular)).themedForeground(.textPrimary)
            case let .glyph(image):
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: side * Self.glyphFraction, height: side * Self.glyphFraction).themedForeground(.textPrimary)
            case let .icon(image):
                Image(nsImage: image).resizable().scaledToFit().frame(width: side * 0.76, height: side * 0.76)
            case let .logo(image):
                Image(nsImage: image).renderingMode(.original).resizable().scaledToFit().frame(width: side * Self.logoFraction, height: side * Self.logoFraction)
            case let .thumbnail(image):
                Image(nsImage: image).resizable().scaledToFill().frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .background { shape.themedFill(.mistChipFill) }
        .clipShape(shape)
        .overlay {
            if outlined { shape.inset(by: MistKit.borderWidth / 2).themedStroke(.mistHairline, lineWidth: MistKit.borderWidth) }
        }
    }
}

/// A launcher: a large outlined icon tile over its name, opening what it names (the New Tab Page's apps). Under the
/// pointer the hover fill shows behind it, and the selected fill while pressed, on corners concentric with the tile's;
/// it shows the pointing hand inside a `MistKitHostingView`. An optional count badge sits on the tile's corner.
struct MistLauncherTile: View {
    static let tileSide: CGFloat = 64
    /// The hover fill's margin around the tile and name.
    static let padding: CGFloat = 8
    static let titleHeight: CGFloat = 16
    static let size = CGSize(width: tileSide + 2 * padding, height: padding + tileSide + 6 + titleHeight + padding)
    let content: MistIconTile.Content
    let title: String
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MistIconTile(content: content, side: Self.tileSide, outlined: true)
                    .overlay(alignment: .topTrailing) {
                        if let badge { MistBadge(text: badge).offset(x: 3, y: -3) }
                    }
                Text(verbatim: title).mistText(.secondary).lineLimit(1).frame(height: Self.titleHeight)
            }
            .padding(.vertical, Self.padding)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        }
        .buttonStyle(MistLauncherButtonStyle())
        .focusable(false)
        .accessibilityLabel(Text(verbatim: title))
    }
}

private struct MistLauncherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MistLauncherButtonBody(configuration: configuration) }
}

private struct MistLauncherButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MistKit.Radius.tile(MistLauncherTile.tileSide) + MistLauncherTile.padding,
                                     style: .continuous)
        configuration.label
            .contentShape(shape)
            .background {
                shape.themedFill(configuration.isPressed ? .mistSelectedFill : .mistHoverFill)
                    .opacity(configuration.isPressed || hovered ? 1 : 0)
            }
            .onHover { hovered = $0 }
            .mistPointingHand()
    }
}

/// A count on an icon's corner, like the Dock's: white on red, ringed in the page color so it cuts into the tile.
struct MistBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background { Capsule().themedFill(.mistBadgeFill) }
            .overlay { Capsule().themedStroke(.contentOverlayBackground, lineWidth: 2) }
            .fixedSize()
    }
}

/// An item as a row: a leading tile or preview, its name with a secondary line under it, and trailing content (a ring,
/// pills).
struct MistItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var titleStyle: MistTextStyle = .headline
    var titleLines = 1
    var subtitle: String?
    var subtitleTruncation: Text.TruncationMode = .middle
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).mistText(titleStyle).lineLimit(titleLines)
                    .truncationMode(titleLines == 1 ? .middle : .tail)
                if let subtitle {
                    Text(verbatim: subtitle).mistText(.secondary).lineLimit(1).truncationMode(subtitleTruncation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

extension MistItemRow where Leading == MistIconTile? {
    init(tile: MistIconTile? = nil, title: String, titleStyle: MistTextStyle = .headline, titleLines: Int = 1,
         subtitle: String? = nil, subtitleTruncation: Text.TruncationMode = .middle, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, titleStyle: titleStyle, titleLines: titleLines, subtitle: subtitle, subtitleTruncation: subtitleTruncation,
                  leading: { tile }, trailing: trailing)
    }
}

extension MistItemRow where Leading == MistIconTile?, Trailing == EmptyView {
    init(tile: MistIconTile? = nil, title: String, titleStyle: MistTextStyle = .headline, titleLines: Int = 1, subtitle: String? = nil,
         subtitleTruncation: Text.TruncationMode = .middle) {
        self.init(tile: tile, title: title, titleStyle: titleStyle, titleLines: titleLines, subtitle: subtitle, subtitleTruncation: subtitleTruncation) { EmptyView() }
    }
}

extension MistItemRow where Trailing == EmptyView {
    init(title: String, titleStyle: MistTextStyle = .headline, titleLines: Int = 1, subtitle: String? = nil, subtitleTruncation: Text.TruncationMode = .middle,
         @ViewBuilder leading: () -> Leading) {
        self.init(title: title, titleStyle: titleStyle, titleLines: titleLines, subtitle: subtitle, subtitleTruncation: subtitleTruncation,
                  leading: leading, trailing: { EmptyView() })
    }
}

/// Content beside a symbol tile at the top of an inner card, with trailing content (a status dot) beside the content's
/// first line: an activity entry in a log or transcript. A one-line entry's line is centered on the tile. Flat, so a
/// long list of them stays cheap to draw.
struct MistTileCard<Content: View, Trailing: View>: View {
    static var tileSide: CGFloat { 28 }
    let symbol: String
    /// The height of the content's first line, which is centered on the tile while the content is one line tall.
    let firstLineHeight: CGFloat
    /// The cap height of the content's font, for content made of lines of text. Content of more than one line then
    /// starts with its first line's capitals level with the tile's top, and the bottom padding counts from its last
    /// baseline, so the text block is framed as evenly as the tile. Nil keeps the first line centered on the tile.
    var capHeight: CGFloat? = nil
    /// Whether the content ends in a plain line of text, whose baseline the bottom padding counts from; false when it
    /// ends in a filled line (a diff's tint), which keeps the padding below the fill.
    var endsInText = true
    var padding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        MistTileCardLayout(tileSide: Self.tileSide, firstLineHeight: firstLineHeight, capHeight: capHeight, endsInText: endsInText) {
            MistIconTile(content: .symbol(symbol), side: Self.tileSide)
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mistCardBackground(.inner)
    }

    /// A font's line height, as text views lay out its lines; cached, since rows ask on every render.
    @MainActor static func lineHeight(_ font: NSFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize)"
        if let cached = MistTileCardLineHeights.values[key] { return cached }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        MistTileCardLineHeights.values[key] = height
        return height
    }
}

@MainActor private enum MistTileCardLineHeights {
    static var values: [String: CGFloat] = [:]
}

extension MistTileCard where Trailing == EmptyView {
    init(symbol: String, firstLineHeight: CGFloat, capHeight: CGFloat? = nil,
         padding: EdgeInsets = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12), @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, firstLineHeight: firstLineHeight, capHeight: capHeight, padding: padding,
                  content: content, trailing: { EmptyView() })
    }
}

/// Lays out a `MistTileCard`'s tile, content and trailing content in a row: the tile at the top, the content beside
/// it (its first line centered on the tile, or its text block starting at the tile's top once it runs past a line)
/// and the trailing content centered on the content's first line, but never above the tile's top, so a control taller
/// than the line (Run in background) keeps the card's padding.
private struct MistTileCardLayout: Layout {
    let tileSide: CGFloat
    let firstLineHeight: CGFloat
    let capHeight: CGFloat?
    let endsInText: Bool
    private let spacing: CGFloat = 10

    private struct Frames {
        var size: CGSize
        var content: CGRect
        var trailing: CGRect?
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> Frames {
        let trailing = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : nil
        let besideContent = tileSide + spacing + (trailing.map { spacing + $0.width } ?? 0)
        let contentProposal = ProposedViewSize(width: width.map { max(0, $0 - besideContent) }, height: nil)
        let content = subviews[1].dimensions(in: contentProposal)
        let firstBaseline = content[.firstTextBaseline], lastBaseline = content[.lastTextBaseline]
        let top: CGFloat
        if let capHeight, lastBaseline > firstBaseline + 1 {
            top = capHeight - firstBaseline
        } else {
            top = max(0, (tileSide - firstLineHeight) / 2)
        }
        let bottom = capHeight != nil && endsInText ? lastBaseline : content.height
        // A whole-point height keeps the card's outline crisp.
        let size = CGSize(width: width ?? besideContent + content.width, height: max(tileSide, (top + bottom).rounded()))
        return Frames(size: size, content: CGRect(x: tileSide + spacing, y: top, width: content.width, height: content.height),
                      trailing: trailing.map { CGRect(x: size.width - $0.width, y: max(0, top + (firstLineHeight - $0.height) / 2),
                                                       width: $0.width, height: $0.height) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: tileSide, height: tileSide))
        subviews[1].place(at: CGPoint(x: bounds.minX + frames.content.minX, y: bounds.minY + frames.content.minY),
                          proposal: ProposedViewSize(width: frames.content.width, height: nil))
        if let trailing = frames.trailing {
            subviews[2].place(at: CGPoint(x: bounds.minX + trailing.minX, y: bounds.minY + trailing.minY), proposal: ProposedViewSize(trailing.size))
        }
    }
}

/// An image shown whole at up to `maxSize`, never enlarged, on the inner card's corners: a staged image's preview.
struct MistImagePreview: View {
    let image: NSImage
    var maxSize = CGSize(width: 240, height: 96)

    var body: some View {
        let size = Self.fitted(image.size, in: maxSize)
        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: MistKit.Radius.field, style: .continuous))
    }

    /// Aspect-fits `size` into `bounds` without enlarging it.
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// The unread dot, in the theme color unless a status asks for another. Hollow, it's a ring: an agent chat's
/// background work still running after its turn ended.
struct MistDot: View {
    var color: ThemedColor = .themeColor
    var isHollow = false
    var body: some View {
        Group {
            if isHollow {
                Circle().inset(by: MistKit.dotRingWidth / 2).themedStroke(color, lineWidth: MistKit.dotRingWidth)
            } else {
                Circle().themedFill(color)
            }
        }
        .frame(width: MistKit.dotSide, height: MistKit.dotSide)
    }
}

// MARK: - Rows

enum MistRowStyle {
    case sidebar, list
    var radius: CGFloat { self == .sidebar ? MistKit.Radius.sidebarRow : MistKit.Radius.listRow }
}

extension View {
    /// A sidebar or list row's background: the hover fill under the pointer, the gray selected fill when selected.
    func mistRow(_ style: MistRowStyle, selected: Bool) -> some View { modifier(MistRowModifier(style: style, selected: selected)) }
    /// A page's sidebar tint.
    func mistSidebarBackground() -> some View { background { Rectangle().themedFill(.mistSidebarFill) } }
}

private struct MistRowModifier: ViewModifier {
    let style: MistRowStyle
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: style.radius, style: .continuous)
                    .themedFill(selected ? .mistSelectedFill : .mistHoverFill)
                    .opacity(selected || hovered ? 1 : 0)
            }
            .onHover { hovered = $0 }
    }
}

/// A sidebar row: a symbol, a title and an optional count, on `mistRow(.sidebar)`.
struct MistSidebarRow: View {
    var symbol: String?
    let title: String
    var count: String?
    var selected = false

    var body: some View {
        HStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14)).themedForeground(.textSecondary).frame(width: 18)
            }
            Text(title).mistText(.rowTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let count { Text(count).mistText(.count) }
        }
        .padding(.horizontal, 10)
        .frame(height: MistSidebarCellView.rowHeight)
        .mistRow(.sidebar, selected: selected)
    }
}

// MARK: - Fields

/// A text field in a well: the chip fill, and the theme color's ring while it has focus. Capsules for search, rounded
/// for form fields. A `nil` height fits a multi-line field. While the field edits, its field editor takes the kit's
/// selection and caret (`MistFieldEditors`), and the well rings by itself; `focused` rings it regardless.
struct MistFieldWell<Content: View>: View {
    enum Shape { case capsule, rounded }
    var shape: Shape = .capsule
    var symbol: String?
    var focused = false
    var height: CGFloat? = MistFieldWellView.height
    @ViewBuilder var content: Content
    @State private var editing = false

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).themedForeground(.textTertiary) }
            content.textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, shape == .capsule ? 12 : 8)
        .padding(.vertical, height == nil ? 6 : 0)
        .frame(height: height)
        .background {
            ZStack {
                well.themedFill(.mistChipFill)
                MistFieldWellProbe(editing: $editing)
            }
        }
        .overlay {
            ZStack {
                well.themedStroke(.mistHairline, lineWidth: MistKit.borderWidth).opacity(ringed ? 0 : 1)
                well.themedStroke(.mistFocusRing, lineWidth: 2).opacity(ringed ? 1 : 0)
            }
        }
    }

    private var ringed: Bool { focused || editing }
    private var well: RoundedRectangle {
        RoundedRectangle(cornerRadius: shape == .capsule ? MistFieldWellView.height / 2 : MistKit.Radius.field, style: .continuous)
    }
}

/// Finds when the text field inside a `MistFieldWell` edits: SwiftUI hides the field, so the well claims whichever
/// field editor works inside its frame.
private struct MistFieldWellProbe: NSViewRepresentable {
    @Binding var editing: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        let editing = $editing
        // Off SwiftUI's update pass: a claim reports at once.
        view.onEditing = { value in DispatchQueue.main.async { if editing.wrappedValue != value { editing.wrappedValue = value } } }
    }

    final class ProbeView: NSView {
        var onEditing: ((Bool) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onEditing?(false)
            MistFieldEditors.claim(self, owns: { [weak self] editor in
                guard let self, editor.window === window else { return false }
                let rect = editor.convert(editor.visibleRect, to: nil)
                return convert(bounds, to: nil).contains(NSPoint(x: rect.midX, y: rect.midY))
            }, focusChanged: { [weak self] in self?.onEditing?($0) })
        }
    }
}
