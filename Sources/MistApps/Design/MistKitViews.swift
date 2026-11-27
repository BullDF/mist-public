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
        /// A brand's square mark (an engine's logo) at a logo's size, in its own colors or, as a template, in the
        /// primary ink. `scale` evens out marks whose artwork is padded differently, so a row of them matches.
        case mark(NSImage, template: Bool, scale: CGFloat = 1)
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
            case let .mark(image, template, scale):
                Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFit()
                    .frame(width: side * Self.logoFraction * scale, height: side * Self.logoFraction * scale)
                    .themedForeground(.textPrimary)
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

/// An activity entry with a symbol tile, content, optional detail, and trailing content beside the first line.
/// Plain content and detail share a column. Flow paragraphs start beside the trailing control and wrap underneath it,
/// with the content view serving as their tap target.
struct MistTileCard<Content: View, Detail: View, Trailing: View>: View {
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
    var flowText: [AttributedString] = []
    var padding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    @ViewBuilder var content: Content
    /// Lines following the content, 5 pt below it (the transcript's line spacing); empty detail takes no room.
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        MistTileCardLayout(tileSide: Self.tileSide, firstLineHeight: firstLineHeight, capHeight: capHeight, endsInText: endsInText,
                           flowsText: !flowText.isEmpty) {
            MistIconTile(content: .symbol(symbol), side: Self.tileSide)
            content.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(flowText.indices, id: \.self) { paragraph in
                let tokens = Self.tokens(in: flowText[paragraph])
                ForEach(tokens.indices, id: \.self) { index in
                    Text(tokens[index].text)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .layoutValue(key: MistTileCardPart.self, value: .token(paragraph: paragraph, glued: tokens[index].glued))
                }
            }
            detail.frame(maxWidth: .infinity, alignment: .leading).layoutValue(key: MistTileCardPart.self, value: .detail)
            trailing.layoutValue(key: MistTileCardPart.self, value: .trailing)
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mistCardBackground(.inner)
    }

    /// A paragraph's words, each with the spaces after it. A word longer than `MistTileCardFlow.longWord` characters
    /// comes as one token per character, glued to the one before, so the flow can break it where a line ends.
    private static func tokens(in paragraph: AttributedString) -> [(text: AttributedString, glued: Bool)] {
        let characters = paragraph.characters
        var tokens: [(text: AttributedString, glued: Bool)] = []
        func append(_ range: Range<AttributedString.Index>) {
            let wordEnd = characters[range].lastIndex { !$0.isWhitespace }.map { characters.index(after: $0) } ?? range.upperBound
            guard characters.distance(from: range.lowerBound, to: wordEnd) > MistTileCardFlow.longWord else {
                tokens.append((AttributedString(paragraph[range]), false))
                return
            }
            var index = range.lowerBound
            while index < wordEnd {
                let next = characters.index(after: index)
                let end = next == wordEnd ? range.upperBound : next
                tokens.append((AttributedString(paragraph[index..<end]), index != range.lowerBound))
                index = next
            }
        }
        var start = characters.startIndex
        var inSpaces = false
        var hasWord = false
        for index in characters.indices {
            let isSpace = characters[index].isWhitespace
            if !isSpace {
                if inSpaces && hasWord {
                    append(start..<index)
                    start = index
                }
                hasWord = true
            }
            inSpaces = isSpace
        }
        if start < characters.endIndex {
            append(start..<characters.endIndex)
        }
        return tokens
    }
}

/// A font's line height, as text views lay out its lines, for a `MistTileCard`'s `firstLineHeight`; cached, since rows
/// ask on every render.
@MainActor enum MistTileCardMetrics {
    private static var lineHeights: [String: CGFloat] = [:]

    static func lineHeight(_ font: NSFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize)"
        if let cached = lineHeights[key] { return cached }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        lineHeights[key] = height
        return height
    }
}

extension MistTileCard where Detail == EmptyView {
    init(symbol: String, firstLineHeight: CGFloat, capHeight: CGFloat? = nil, endsInText: Bool = true,
         padding: EdgeInsets = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12),
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.init(symbol: symbol, firstLineHeight: firstLineHeight, capHeight: capHeight, endsInText: endsInText, padding: padding,
                  content: content, detail: { EmptyView() }, trailing: trailing)
    }
}

extension MistTileCard where Detail == EmptyView, Trailing == EmptyView {
    init(symbol: String, firstLineHeight: CGFloat, capHeight: CGFloat? = nil,
         padding: EdgeInsets = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12), @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, firstLineHeight: firstLineHeight, capHeight: capHeight, padding: padding,
                  content: content, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

private enum MistTileCardPart: LayoutValueKey, Equatable {
    case content, token(paragraph: Int, glued: Bool), detail, trailing
    static let defaultValue = MistTileCardPart.content
}

/// Centers a single line on the tile and aligns a taller text block's capitals with the tile's top. The trailing
/// content stays beside the first line and never rises above the tile. Plain content and detail are measured in the
/// narrowed column. Flow tokens use that column beside the control and the full column below it, as does the detail.
private struct MistTileCardLayout: Layout {
    let tileSide: CGFloat
    let firstLineHeight: CGFloat
    let capHeight: CGFloat?
    let endsInText: Bool
    let flowsText: Bool
    private let spacing: CGFloat = 10
    private let lineSpacing: CGFloat = 5
    private struct Frames {
        var size: CGSize
        var content: CGRect
        var detail: CGRect?
        var trailing: CGRect?
        var tokens: [MistTileCardFlow.Placement] = []
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> Frames {
        let detailView = subviews.first { $0[MistTileCardPart.self] == .detail }
        let trailing = subviews.first { $0[MistTileCardPart.self] == .trailing }.map { $0.sizeThatFits(.unspecified) }
            .flatMap { $0.width > 0 ? $0 : nil }
        let besideTile = tileSide + spacing
        let besideTrailing = besideTile + (trailing.map { spacing + $0.width } ?? 0)
        if flowsText {
            return flowed(width, subviews, detail: detailView, trailing: trailing, inset: besideTile)
        }
        func measure(_ view: LayoutSubview, inset: CGFloat) -> ViewDimensions {
            view.dimensions(in: ProposedViewSize(width: width.map { max(0, $0 - inset) }, height: nil))
        }
        let content = measure(subviews[1], inset: besideTrailing)
        let detail = detailView.map { measure($0, inset: besideTrailing) }.flatMap { $0.height > 0 ? $0 : nil }
        return stacked(content, detail, trailing: trailing, width: width ?? besideTrailing + content.width)
    }

    /// The content's top beside the tile: a one-line text block's line centered on the tile, a longer one's first
    /// capitals level with the tile's top.
    private func top(_ content: ViewDimensions, multiline: Bool) -> CGFloat {
        if let capHeight, multiline || content[.lastTextBaseline] > content[.firstTextBaseline] + 1 {
            return capHeight - content[.firstTextBaseline]
        }
        return max(0, (tileSide - firstLineHeight) / 2)
    }

    /// Where the bottom padding counts from for a text block placed at `y`.
    private func bottom(_ text: ViewDimensions, at y: CGFloat) -> CGFloat {
        y + (capHeight != nil && endsInText ? text[.lastTextBaseline] : text.height)
    }

    private func stacked(_ content: ViewDimensions, _ detail: ViewDimensions?, trailing: CGSize?, width: CGFloat) -> Frames {
        let top = top(content, multiline: detail != nil)
        let detailFrame = detail.map { CGRect(x: tileSide + spacing, y: top + content.height + lineSpacing, width: $0.width, height: $0.height) }
        let textBottom = max(tileSide, detail.map { bottom($0, at: detailFrame!.minY) } ?? bottom(content, at: top))
        let trailingFrame = trailing.map {
            CGRect(x: width - $0.width, y: max(0, top + (firstLineHeight - $0.height) / 2),
                   width: $0.width, height: $0.height)
        }
        // A whole-point height keeps the card's outline crisp.
        return Frames(size: CGSize(width: width, height: textBottom.rounded()),
                      content: CGRect(x: tileSide + spacing, y: top, width: content.width, height: content.height),
                      detail: detailFrame, trailing: trailingFrame)
    }

    private func flowed(_ offeredWidth: CGFloat?, _ subviews: Subviews, detail detailView: LayoutSubview?,
                        trailing: CGSize?, inset: CGFloat) -> Frames {
        let tokenViews = subviews.dropFirst(2).compactMap { view -> (LayoutSubview, Int, Bool)? in
            guard case let .token(paragraph, glued) = view[MistTileCardPart.self] else { return nil }
            return (view, paragraph, glued)
        }
        let tokens = tokenViews.map { view, paragraph, glued in
            MistTileCardFlow.Token(paragraph: paragraph, glued: glued, metrics: metrics(of: view, width: nil))
        }
        let trailingInset = trailing.map { spacing + $0.width } ?? 0
        let idealWidth = { inset + trailingInset + (Dictionary(grouping: tokens, by: \.paragraph).values
            .map { $0.reduce(0) { $0 + $1.metrics.size.width } }.max() ?? 0) }
        let width = offeredWidth.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth()
        let fullWidth = max(0, width - inset)
        let narrowWidth = max(0, fullWidth - trailingInset)
        let detail = detailView.map { $0.dimensions(in: ProposedViewSize(width: fullWidth, height: nil)) }
            .flatMap { $0.height > 0 ? $0 : nil }
        func layout(at top: CGFloat) -> (MistTileCardFlow.Result, CGRect?) {
            let trailingFrame = trailing.map {
                CGRect(x: width - $0.width, y: max(0, top + (firstLineHeight - $0.height) / 2),
                       width: $0.width, height: $0.height)
            }
            let flow = MistTileCardFlow.layout(tokens, fullWidth: fullWidth, narrowWidth: narrowWidth,
                                               trailing: trailingFrame, capHeight: capHeight, top: top, lineSpacing: lineSpacing) {
                metrics(of: tokenViews[$0].0, width: $1)
            }
            return (flow, trailingFrame)
        }
        var (flow, trailingFrame) = layout(at: max(0, (tileSide - firstLineHeight) / 2))
        if let capHeight, let firstLine = flow.lines.first, flow.isMultiline || detail != nil {
            (flow, trailingFrame) = layout(at: capHeight - firstLine.firstBaseline)
        }
        let content = flow.lines.reduce(CGRect.null) { $0.union($1.frame) }
        let detailY = max(flow.lines.last?.frame.maxY ?? 0, trailingFrame?.maxY ?? 0) + lineSpacing
        let detailFrame = detail.map { CGRect(x: inset, y: detailY, width: fullWidth, height: $0.height) }
        let textBottom = detail.map { bottom($0, at: detailY) }
            ?? flow.lines.last.map { capHeight != nil && endsInText ? $0.lastBaselineY : $0.frame.maxY } ?? 0
        let height = max(tileSide, trailingFrame?.maxY ?? 0, textBottom)
        return Frames(size: CGSize(width: width, height: height.rounded()),
                      content: content.isNull ? CGRect(x: inset, y: 0, width: 0, height: 0) : content.offsetBy(dx: inset, dy: 0),
                      detail: detailFrame, trailing: trailingFrame, tokens: flow.placements)
    }

    private func metrics(of view: LayoutSubview, width: CGFloat?) -> MistTileCardFlow.Metrics {
        let dimensions = view.dimensions(in: ProposedViewSize(width: width, height: nil))
        return .init(size: CGSize(width: dimensions.width, height: dimensions.height),
                     firstBaseline: dimensions[.firstTextBaseline], lastBaseline: dimensions[.lastTextBaseline])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(bounds.width, subviews)
        func place(_ subview: LayoutSubview, _ frame: CGRect, proposal: ProposedViewSize) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: proposal)
        }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: tileSide, height: tileSide))
        place(subviews[1], frames.content,
              proposal: ProposedViewSize(width: frames.content.width, height: flowsText ? frames.content.height : nil))
        let empty = CGRect(x: frames.content.minX, y: frames.content.maxY, width: 0, height: 0)
        var tokenIndex = 0
        for subview in subviews.dropFirst(2) {
            switch subview[MistTileCardPart.self] {
            case .token:
                let token = frames.tokens[tokenIndex]
                let frame = token.frame.offsetBy(dx: tileSide + spacing, dy: 0)
                // Use the same proposal as measurement so a token keeps its line breaks.
                place(subview, frame, proposal: ProposedViewSize(width: token.proposedWidth, height: nil))
                tokenIndex += 1
            case .detail:
                let frame = frames.detail ?? empty
                place(subview, frame, proposal: ProposedViewSize(width: frame.width, height: nil))
            case .trailing, .content:
                let frame = frames.trailing ?? empty
                place(subview, frame, proposal: ProposedViewSize(width: frame.width,
                      height: subview[MistTileCardPart.self] == .trailing ? frame.height : nil))
            }
        }
    }
}

enum MistTileCardFlow {
    struct Metrics {
        var size: CGSize
        var firstBaseline: CGFloat
        var lastBaseline: CGFloat
    }

    /// Words longer than this many characters break between any two characters where a line ends.
    static let longWord = 16

    struct Token {
        var paragraph: Int
        /// The token continues the previous token's word: a character of a long word.
        var glued = false
        var metrics: Metrics
    }

    struct Placement {
        var frame: CGRect
        var proposedWidth: CGFloat?
    }

    struct Line {
        var frame: CGRect
        var firstBaseline: CGFloat
        var lastBaselineY: CGFloat
    }

    struct Result {
        var placements: [Placement] = []
        var lines: [Line] = []

        var isMultiline: Bool {
            lines.count > 1 || lines.contains { $0.lastBaselineY > $0.frame.minY + $0.firstBaseline + 1 }
        }
    }

    static func layout(_ tokens: [Token], fullWidth: CGFloat, narrowWidth: CGFloat, trailing: CGRect?,
                       capHeight: CGFloat?, top: CGFloat, lineSpacing: CGFloat,
                       measure: (Int, CGFloat) -> Metrics) -> Result {
        var result = Result()
        var y = top
        var line: [Int] = []
        var used: CGFloat = 0
        var lineWidth: CGFloat = 0
        /// A line is narrow while its capitals would sit level with the trailing content or within a line spacing below it.
        func width(forLineStartingWith index: Int) -> CGFloat {
            let capitalsTop = y + (capHeight.map { tokens[index].metrics.firstBaseline - $0 } ?? 0)
            return trailing.map { capitalsTop < $0.maxY + lineSpacing } == true ? narrowWidth : fullWidth
        }
        func add(_ index: Int) {
            if line.isEmpty { lineWidth = width(forLineStartingWith: index) }
            line.append(index)
            used += tokens[index].metrics.size.width
        }
        /// Places the current line's tokens on their shared first baseline.
        func finishLine() {
            guard !line.isEmpty else { return }
            let baseline = line.map { tokens[$0].metrics.firstBaseline }.max() ?? 0
            let descent = line.map { tokens[$0].metrics.size.height - tokens[$0].metrics.firstBaseline }.max() ?? 0
            var x: CGFloat = 0
            for index in line {
                let metrics = tokens[index].metrics
                let frame = CGRect(origin: CGPoint(x: x, y: y + baseline - metrics.firstBaseline), size: metrics.size)
                result.placements.append(Placement(frame: frame, proposedWidth: nil))
                x += metrics.size.width
            }
            let frame = CGRect(x: 0, y: y, width: used, height: baseline + descent)
            result.lines.append(Line(frame: frame, firstBaseline: baseline, lastBaselineY: y + baseline))
            y = frame.maxY
            line = []
            used = 0
        }
        var paragraph = tokens.first?.paragraph
        var start = 0
        while start < tokens.count {
            // A word: this token and the glued tokens continuing it.
            var end = start + 1
            while end < tokens.count, tokens[end].glued, tokens[end].paragraph == tokens[start].paragraph { end += 1 }
            if tokens[start].paragraph != paragraph {
                finishLine()
                y += lineSpacing
                paragraph = tokens[start].paragraph
            }
            let wordWidth = tokens[start..<end].reduce(0) { $0 + $1.metrics.size.width }
            if !line.isEmpty && used + wordWidth > lineWidth { finishLine() }
            if line.isEmpty { lineWidth = width(forLineStartingWith: start) }
            if used + wordWidth <= lineWidth {
                for index in start..<end { add(index) }
            } else if end - start == 1 {
                // A single token wider than an empty line wraps inside itself.
                let wrapped = measure(start, lineWidth)
                let frame = CGRect(x: 0, y: y, width: lineWidth, height: wrapped.size.height)
                result.placements.append(Placement(frame: frame, proposedWidth: lineWidth))
                result.lines.append(Line(frame: frame, firstBaseline: wrapped.firstBaseline, lastBaselineY: y + wrapped.lastBaseline))
                y = frame.maxY
            } else {
                // A long word wider than an empty line fills each line with its characters, and the next word follows
                // its last character.
                for index in start..<end {
                    if !line.isEmpty && used + tokens[index].metrics.size.width > lineWidth { finishLine() }
                    add(index)
                }
            }
            start = end
        }
        finishLine()
        return result
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
