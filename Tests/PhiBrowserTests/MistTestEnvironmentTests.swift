import XCTest
@testable import Phi

final class MistTestEnvironmentTests: XCTestCase {
    func testHostedTestsUseIsolatedBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.bulldf.mist.tests",
                       "Run hosted tests through mist/scripts/test.sh to protect your Mist settings and data.")
        XCTAssertNotNil(FileSystemUtils.launchUserDataDirectory)
        XCTAssertEqual(FileSystemUtils.applicationSupportDirctory(), FileSystemUtils.launchUserDataDirectory)
    }

    func testPasswordKeyServiceKeepsInstalledVaultAndIsolatesTests() {
        XCTAssertEqual(MistPasswordKey.service(bundleIdentifier: "com.bulldf.mist"), "Mist Password Vault")
        XCTAssertEqual(MistPasswordKey.service(bundleIdentifier: "com.bulldf.mist.tests"),
                       "Mist Password Vault (com.bulldf.mist.tests)")
    }
}
