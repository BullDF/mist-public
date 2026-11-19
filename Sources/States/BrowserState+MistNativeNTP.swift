import Foundation

extension BrowserState {
    /// Configure every arrival, including restored tabs, before mounting content.
    func configureMistNativeNTP(for tab: Tab) {
        tab.nativeNTPIsIncognito = isIncognito
        tab.updateMistNativeNTPForURL()
    }
}

extension Tab {
    static func shouldUseMistNativeNTP(url: String?, isIncognito: Bool?) -> Bool {
        isIncognito == false && url?.isNTP == true
    }

    /// URL updates cover initially empty bridge payloads and navigation back to NTP.
    /// Empty URLs alone never opt link-created tabs into the native page.
    func updateMistNativeNTPForURL() {
        if Self.shouldUseMistNativeNTP(url: url, isIncognito: nativeNTPIsIncognito) {
            usesNativeNTP = true
        }
    }
}
