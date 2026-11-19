import Foundation
import XCTest

extension XCTestCase {
    /// A UserDefaults suite removed when the test ends. Its name is an absolute path in the
    /// temporary directory: a suite named in `~/Library/Preferences` leaves its plist behind,
    /// since cfprefsd writes it back seconds after `removePersistentDomain` and a file delete.
    func makeTestDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(type(of: self)).\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        return (defaults, suite)
    }
}
