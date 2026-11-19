import Foundation

@MainActor
final class BrowserAgentScrollRestore {
    static let shared = BrowserAgentScrollRestore()
    private var turns = BrowserAgentScrollTurns()
    private var pending: [Int: (UUID, Task<Void, Never>)] = [:]

    func record(chat: UUID, tab: Tab) -> Task<Void, Never> {
        guard turns.record(chat: chat, tab: tab.guid) else { return pending[tab.guid]?.1 ?? Task {} }
        return enqueue(tab: tab, expression: Self.recordScript)
    }

    func mark(chat: UUID, tab: Int) { turns.mark(chat: chat, tab: tab) }

    func endTurn(chat: UUID) {
        let ended = turns.endTurn(chat: chat)
        for id in ended.restore.union(ended.cleanup) {
            guard let tab = SpaceSessionControllersManager.shared.getAllWindows()
                .compactMap({ $0.browserState }).flatMap({ $0.tabs }).first(where: { $0.guid == id }) else { continue }
            _ = enqueue(tab: tab, expression: ended.restore.contains(id) ? Self.restoreScript : Self.cleanupScript)
        }
    }

    /// A turn can end while its first report is recording. Serialize page
    /// operations per tab so cleanup never overtakes that record or a new turn.
    private func enqueue(tab: Tab, expression: String) -> Task<Void, Never> {
        let previous = pending[tab.guid]?.1
        let token = UUID()
        let task = Task { [self] in
            await previous?.value
            await evaluate(tab: tab, expression: expression)
            if pending[tab.guid]?.0 == token { pending[tab.guid] = nil }
        }
        pending[tab.guid] = (token, task)
        return task
    }

    private func evaluate(tab: Tab, expression: String) async {
        guard BrowserAgentTabPreview.hasLivePage(tab), let target = tab.webContentWrapper?.devToolsTargetId,
              let session = try? await AppDevToolsPageSession.open(targetId: target, timeout: 2) else { return }
        defer { session.close() }
        guard BrowserAgentTabPreview.hasLivePage(tab), target == tab.webContentWrapper?.devToolsTargetId else { return }
        AgentUserSpaceDriveRegistry.shared.appWillSendPageCommand(toTab: tab.guid)
        _ = try? await session.command("Runtime.evaluate", params: ["expression": expression, "returnByValue": true], timeout: 2)
    }

    private static let recordScript = """
    (() => { const k = Symbol.for('mist.agentScrollOrigin'); if (window[k]) return false; const root = document.scrollingElement || document.documentElement; const saved = [[root, scrollX, scrollY]]; for (const el of document.querySelectorAll('*')) { if (el === root) continue; const moved = el.scrollTop || el.scrollLeft; if (!moved && el.scrollHeight <= el.clientHeight && el.scrollWidth <= el.clientWidth) continue; const s = getComputedStyle(el); if (moved || /(auto|scroll|overlay)/.test(s.overflowX + s.overflowY)) saved.push([el, el.scrollLeft, el.scrollTop]) } Object.defineProperty(window, k, { value: saved, configurable: true }); return true })()
    """
    private static let restoreScript = """
    (() => { const k = Symbol.for('mist.agentScrollOrigin'); const saved = window[k]; if (!saved) return false; delete window[k]; const root = document.scrollingElement || document.documentElement; for (const [el, x, y] of saved) { if (!el.isConnected) continue; (el === root ? window : el).scrollTo({ left: x, top: y, behavior: 'instant' }) } return true })()
    """
    private static let cleanupScript = "delete window[Symbol.for('mist.agentScrollOrigin')]"
}
