import AppKit

extension SpaceSessionController {
    /// Selects a live tab of this window, first switching to its Space when another one is showing.
    @MainActor
    func selectTab(_ tab: Tab, then completion: @escaping () -> Void = {}) {
        let select = { [weak self] in
            guard let self, self.browserState.tabs.contains(where: { $0 === tab }) else { return }
            self.window?.makeKeyAndOrderFront(nil)
            _ = ChromiumLauncher.sharedInstance().bridge?.activateSearchTab(
                withTabId: Int64(tab.guid), windowId: Int64(self.windowId))
            completion()
        }
        if let slot, slot.activeSpaceId != spaceId {
            slot.activate(spaceId: spaceId, onSwapSettled: select)
        } else {
            select()
        }
    }
}
