// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import XCTest
@testable import Phi

final class AgentProcessDetailsTests: XCTestCase {

    // MARK: - The peer that could not be identified

    /// `AgentCDPListener.evaluate` refuses this identity outright, so the one
    /// thing that must never drift is which identities wear its key: exactly
    /// the stand-in, and nothing a real peer resolves to.
    func testOnlyTheStandInIsUnresolved() {
        XCTAssertTrue(AgentIdentity.unresolved.isUnresolved)
        XCTAssertEqual(AgentIdentity.unresolved.key, AgentIdentity.unresolvedKey)
        XCTAssertFalse(Self.identity(pid: getpid()).isUnresolved)
        XCTAssertFalse(AgentIdentity.unresolved.firstParty,
                       "the absence of an identity must never take the first-party pass")
    }

    /// The skill's own plumbing reaches the same refusal by the other road:
    /// the walk ran but found only our scripts, which act for whoever drives
    /// them. It must share the key — that is what makes it refused — while
    /// keeping the executable for the log line that names the delegation bug.
    func testOwnPlumbingResolvesToTheSameRefusal() {
        let plumbing = AgentIdentity.unresolvedOwnPlumbing(
            executablePath: "/opt/homebrew/bin/node")
        XCTAssertTrue(plumbing.isUnresolved)
        XCTAssertEqual(plumbing.key, AgentIdentity.unresolvedKey)
        XCTAssertEqual(plumbing.executablePath, "/opt/homebrew/bin/node")
        XCTAssertNil(plumbing.pid, "no agent behind it to echo back")
        XCTAssertFalse(plumbing.verified)
        XCTAssertFalse(plumbing.firstParty)
        XCTAssertNotEqual(plumbing.displayName, AgentIdentity.unresolved.displayName,
                          "the two roads to the refusal are told apart in the log")
    }

    /// The old behaviour minted an agent keyed to the skill DIRECTORY, so one
    /// "Always Allow" would have been inherited by every future process
    /// running anything out of it. Nothing may resolve to that key again.
    func testOwnPlumbingIsNoLongerAnAgentNamedPhiBrowser() {
        let plumbing = AgentIdentity.unresolvedOwnPlumbing(executablePath: "/bin/node")
        XCTAssertNotEqual(plumbing.key, "unsigned:phi-browser")
    }

    /// A real peer always resolves to something, so nothing legitimate is
    /// swept into the refusal: the walk falls back through the script, the
    /// signature, and finally an unsigned path, and only an unreadable peer
    /// pid produces no identity at all.
    func testALiveProcessNeverResolvesToTheStandIn() throws {
        let resolved = try XCTUnwrap(AgentPeerIdentity.resolveClaimed(pid: getpid()))
        XCTAssertFalse(resolved.isUnresolved)
        XCTAssertFalse(resolved.key.isEmpty)
    }

    /// The unresolved sentinel carries no process or path.
    func testTheStandInHasNothingToDisclose() {
        XCTAssertNil(AgentIdentity.unresolved.pid)
        XCTAssertTrue(AgentIdentity.unresolved.executablePath.isEmpty)
    }

    // MARK: - Helpers

    private static func identity(pid: pid_t?,
                                 key: String? = nil,
                                 executablePath: String = "/usr/bin/true") -> AgentIdentity {
        AgentIdentity(key: key ?? "unsigned:\(executablePath)",
                      displayName: "test-agent",
                      teamId: nil,
                      verified: false,
                      executablePath: executablePath,
                      pid: pid)
    }
}
