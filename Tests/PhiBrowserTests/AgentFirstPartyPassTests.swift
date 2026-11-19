// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AgentFirstPartyPassTests: XCTestCase {
    func testOwnCodeOutsideTheBrowserIsUnresolved() {
        let identity = AgentIdentity.unresolvedOwnCode(executablePath: "/Applications/Mist.app/Contents/MacOS/Phi")
        XCTAssertTrue(identity.isUnresolved)
        XCTAssertFalse(identity.firstParty)
        XCTAssertEqual(identity.key, AgentIdentity.unresolvedKey)
        XCTAssertNil(identity.teamId)
        XCTAssertFalse(identity.verified)
    }

    func testResolvedIdentitiesAreNeverFirstParty() {
        let own = AgentIdentity.mistBrowserAgent(pid: nil)
        let identity = AgentIdentity(
            key: own.key, displayName: own.displayName,
            teamId: FileSystemUtils.teamId, verified: true,
            executablePath: "/usr/local/bin/node", pid: 4321)
        XCTAssertFalse(identity.firstParty)
    }

    func testMistBrowserAgentKeepsItsFirstPartyIdentity() {
        XCTAssertTrue(AgentIdentity.mistBrowserAgent(pid: nil).firstParty)
    }
}
