import Foundation

/// Chat-owned working tabs, independent of view lifetimes.
struct BrowserAgentPreviewState: Equatable {
    let principalId: String
    let windowId: Int
    private(set) var tabId: Int?
    struct Card: Equatable {
        let tabId: Int
        var lastWorked: Date
        var chat: UUID? = nil
        var chatWorking = false
    }
    /// Live checks shorten it with the defaults key `BrowserAgentIdleLifetime` (seconds), read at launch.
    static let idleLifetime: TimeInterval = {
        let seconds = UserDefaults.standard.double(forKey: "BrowserAgentIdleLifetime")
        return seconds > 0 ? seconds : 5 * 60
    }()
    static let maxVisibleCards = 3
    private(set) var cards: [Card] = [] { didSet { if cards.isEmpty { cardAspect = nil } } }
    private(set) var turnActive = false
    private(set) var workedThisTurn = false
    var reportOrder: UInt64 = 0
    var cardAspect: CGFloat? { didSet { if cards.isEmpty { cardAspect = nil } } }

    @discardableResult
    mutating func report(principal: String?, tabId: Int?, live: Bool, now: Date) -> Bool {
        guard live, principal == principalId else { return false }
        if self.tabId != tabId, let index = cards.firstIndex(where: { $0.tabId == self.tabId }) {
            cards[index].lastWorked = now
        }
        if let tabId {
            var updated = cards.filter { $0.tabId != tabId }
            updated.insert(Card(tabId: tabId, lastWorked: now), at: 0)
            cards = updated
            workedThisTurn = true
        }
        self.tabId = tabId
        return true
    }

    mutating func setTurnActive(_ active: Bool, now: Date) {
        guard active != turnActive else { return }
        if !active, workedThisTurn, let index = cards.firstIndex(where: { $0.tabId == tabId }) {
            cards[index].lastWorked = now
        }
        turnActive = active
        workedThisTurn = false
    }

    mutating func dismiss(tabId: Int) { cards.removeAll { $0.tabId == tabId } }

    mutating func upsertChild(_ chat: UUID, tabId: Int, working: Bool, now: Date, insertIfMissing: Bool = true) {
        if let index = cards.firstIndex(where: { $0.chat == chat }) {
            let previous = cards[index]
            guard previous.chatWorking != working || previous.tabId != tabId else { return }
            var updated = cards
            updated.remove(at: index)
            let card = Card(tabId: tabId, lastWorked: now, chat: chat, chatWorking: working)
            updated.insert(card, at: working ? 0 : index)
            cards = updated
        } else if insertIfMissing {
            cards.insert(Card(tabId: tabId, lastWorked: now, chat: chat, chatWorking: working), at: 0)
        }
    }

    mutating func removeTab(_ tabId: Int) {
        dismiss(tabId: tabId)
        if self.tabId == tabId { self.tabId = nil }
    }

    /// A child chat's card stays while the child is open: closing it or its tab removes the card.
    private func isExpirable(_ card: Card) -> Bool {
        if card.chat != nil { return false }
        return !(card.tabId == tabId && turnActive && workedThisTurn)
    }

    var nextExpiry: Date? {
        cards.filter(isExpirable).map { $0.lastWorked.addingTimeInterval(Self.idleLifetime) }.min()
    }

    @discardableResult mutating func expire(now: Date) -> Bool {
        let expired = Set(cards.filter { isExpirable($0) && now >= $0.lastWorked.addingTimeInterval(Self.idleLifetime) }.map(\.tabId))
        cards.removeAll { expired.contains($0.tabId) }
        return !expired.isEmpty
    }

    enum Mount: Equatable { case hidden, live, still, agent }
    func mount(card tabId: Int, chatVisible: Bool, tabExists: Bool) -> Mount {
        guard chatVisible, tabExists, cards.contains(where: { $0.tabId == tabId }) else { return .hidden }
        if cards.first(where: { $0.tabId == tabId })?.chat != nil { return .agent }
        guard tabId == self.tabId else { return .still }
        return .live
    }

    static func visibleCardCount(cardHeights: [CGFloat], spacing: CGFloat, chipHeight: CGFloat,
                                 availableHeight: CGFloat, narrow: Bool) -> Int {
        guard !cardHeights.isEmpty else { return 0 }
        let cap = min(cardHeights.count, narrow ? 1 : maxVisibleCards)
        for count in stride(from: cap, through: 1, by: -1) {
            let height = cardHeights.prefix(count).reduce(0, +) + CGFloat(count - 1) * spacing
                + (count < cardHeights.count ? spacing + chipHeight : 0)
            if height <= availableHeight { return count }
        }
        return 1
    }
}

enum BrowserAgentPreviewLayout {
    static func chatTrailingInset(pageWidth: CGFloat, cardLeading: CGFloat) -> CGFloat {
        let inset = max(0, pageWidth - cardLeading + 16 - 24)
        return pageWidth - inset - 48 >= 360 ? inset : 0
    }

    static func bodyHeight(width: CGFloat, aspect: CGFloat) -> CGFloat {
        min(500, max(150, (width - 2) * aspect))
    }

    /// Every card's size. Each card is a third of the chip and its spacing shorter than a card at full
    /// width, so three cards and the chip fit wherever three full cards would; it narrows by what its
    /// page loses in height, so the page still fills its width.
    static func cardSize(pageWidth: CGFloat, aspect: CGFloat, spacing: CGFloat, chipHeight: CGFloat) -> CGSize {
        let fullWidth = max(1, min(400, pageWidth - 32))
        let fullBody = bodyHeight(width: fullWidth, aspect: aspect)
        let shrink = ((spacing + chipHeight) / 3).rounded(.up)
        let page = min(fullBody, (fullWidth - 2) * aspect)
        let lost = max(0, page - (fullBody - shrink))
        // Whole points, so cards at different offsets round to the same size.
        return CGSize(width: max(1, (fullWidth - lost / aspect).rounded()), height: (fullBody + 37).rounded() - shrink)
    }
}

/// Screenshot coordinates use document CSS pixels; frozen frames use image pixels.
enum BrowserAgentScreenshotGeometry {
    struct FullPageTiling: Equatable {
        var scale: CGFloat
        var pixelWidth: Int
        var pixelHeight: Int
        var tileHeight: CGFloat
        var count: Int
        var coveredHeight: CGFloat
        var truncated: Bool

        func rect(_ index: Int, pageWidth: CGFloat) -> CGRect {
            let y = CGFloat(index) * tileHeight
            return CGRect(x: 0, y: y, width: pageWidth, height: min(tileHeight, coveredHeight - y))
        }
    }

    static let fullPageTileLimit = 10

    static func fullPageTiling(page: CGSize, viewport: CGSize) -> FullPageTiling? {
        guard page.width > 0, page.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let v = modelSize(for: viewport).width / viewport.width
        let preferred = min(v, 0.75), readable = min(v, 0.6)
        let single = modelSize(for: page).width / page.width
        guard single < preferred else { return nil }
        let top = min(preferred, 1568 / page.width)
        let minimum = min(readable, top)
        let limit = CGFloat(fullPageTileLimit)
        let fit = min(1568 * limit / page.height, sqrt(1_150_000 * limit / (page.width * page.height)))
        var scale = max(minimum, min(top, fit))
        let pixelWidth = max(1, Int(floor(page.width * scale)))
        scale = CGFloat(pixelWidth) / page.width
        let pixelHeight = max(1, min(1568, Int(floor(1_150_000 / CGFloat(pixelWidth)))))
        let tileHeight = CGFloat(pixelHeight) / scale
        let needed = ceil(page.height / tileHeight)
        let count = Int(min(limit, needed))
        return FullPageTiling(scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            tileHeight: tileHeight, count: count, coveredHeight: min(page.height, CGFloat(count) * tileHeight),
            truncated: needed > limit)
    }

    static func needsBeyondViewport(rect: CGRect, viewport: CGRect, fullPage: Bool) -> Bool {
        fullPage || rect.minX < viewport.minX || rect.minY < viewport.minY
            || rect.maxX > viewport.maxX || rect.maxY > viewport.maxY
    }

    // Keep model pixels stable across Claude/Codex: no implicit model resize.
    static func modelSize(for size: CGSize) -> CGSize {
        let scale = min(1, boundScale(for: size))
        let width = max(1, floor(size.width * scale))
        // The returned coordinate scale is width / CSS width. Derive height
        // from that same scale so narrow, tall viewport clicks do not drift.
        let height = min(floor(size.height * scale), floor(size.height * width / max(1, size.width)))
        return CGSize(width: width, height: max(1, height))
    }

    private static func boundScale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1568 / max(size.width, size.height), sqrt(1_150_000 / (size.width * size.height)))
    }

    static func closeUpScale(for size: CGSize) -> CGFloat { min(4, boundScale(for: size)) }

    static func fullPageScale(for size: CGSize, dpr: CGFloat, maxScale: CGFloat) -> CGFloat {
        let ratio = max(1, dpr)
        // Return output pixels per CSS pixel. clip.scale is this value / DPR;
        // a Retina screen must not halve the largest safe saved image again.
        var clipScale = min(maxScale / ratio, 16_384 / (max(size.width, size.height) * ratio))
        let width = ceil(size.width * ratio * clipScale), height = ceil(size.height * ratio * clipScale)
        if width * height > 64_000_000 {
            let areaScale = sqrt(64_000_000 / (width * height))
            clipScale *= min((floor(width * areaScale) - 1) / width, (floor(height * areaScale) - 1) / height)
        }
        return (clipScale * ratio).nextDown
    }

}
