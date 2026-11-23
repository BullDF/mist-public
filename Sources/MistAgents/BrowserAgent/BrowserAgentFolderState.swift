import Foundation

/// The idle clock of a chat whose own tab closes once nothing has needed it for `idleLifetime` (a Slack thread's chat).
struct AgentChatIdleTab: Equatable {
    private(set) var idleSince: Date?

    /// A hold stops the clock, and it restarts when the last hold clears.
    mutating func update(held: Bool, now: Date) {
        if held { idleSince = nil } else if idleSince == nil { idleSince = now }
    }

    var deadline: Date? { idleSince?.addingTimeInterval(BrowserAgentPreviewState.idleLifetime) }
}

/// The agent's clock is independent of both preview cards and user selection.
struct BrowserAgentFolderState: Equatable {
    static let titleMarker = "\u{2060}"
    static func isAgentFolderTitle(_ title: String) -> Bool { title.hasSuffix(titleMarker) }

    let windowId: Int
    let token: String
    var borrowed = false
    private(set) var members: [Int: Date] = [:]
    private(set) var workingTabId: Int?
    private(set) var turnActive = false
    private(set) var workedThisTurn = false

    mutating func join(_ tabId: Int, now: Date) {
        if members[tabId] == nil { members[tabId] = now }
    }

    mutating func remove(_ tabId: Int) {
        members[tabId] = nil
        if workingTabId == tabId { workingTabId = nil }
    }

    mutating func report(tabId: Int?, now: Date) {
        if workingTabId != tabId, let previous = workingTabId, members[previous] != nil {
            members[previous] = now
        }
        workingTabId = tabId
        if let tabId {
            if members[tabId] != nil { members[tabId] = now }
            workedThisTurn = true
        }
    }

    mutating func touch(tabId: Int, now: Date) {
        if members[tabId] != nil { members[tabId] = now }
    }

    mutating func setTurnActive(_ active: Bool, now: Date) {
        guard active != turnActive else { return }
        if !active, workedThisTurn, let tabId = workingTabId, members[tabId] != nil {
            members[tabId] = now
        }
        turnActive = active
        workedThisTurn = false
    }

    private func isExpirable(_ tabId: Int) -> Bool {
        !(tabId == workingTabId && turnActive && workedThisTurn)
    }

    var nextExpiry: Date? { nextExpiry(excluding: []) }

    func nextExpiry(excluding excluded: Set<Int>) -> Date? {
        members.filter { isExpirable($0.key) && !excluded.contains($0.key) }
            .map { $0.value.addingTimeInterval(BrowserAgentPreviewState.idleLifetime) }.min()
    }

    func dueTabIds(now: Date) -> Set<Int> {
        Set(members.filter {
            isExpirable($0.key) && now >= $0.value.addingTimeInterval(BrowserAgentPreviewState.idleLifetime)
        }.map(\.key))
    }
}
