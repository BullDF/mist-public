// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// How the pill over a driven tab names the agent driving it.
final class AgentDriverBadgeTests: XCTestCase {

    // MARK: - The browser's own agent

    func testBrowserAgentUsesTheGlobeAndLocalizedName() {
        let name = AgentIdentity.mistBrowserAgent(pid: nil).displayName
        let badge = AgentDriverBadge.make(agentName: name)
        XCTAssertEqual(badge.label, name)
        XCTAssertEqual(badge.symbol, "globe")
        XCTAssertNil(badge.assetName)
    }

    // MARK: - Everyone else keeps their own identity

    /// pi-agent is a DIFFERENT product — an outside agent here — and must keep
    /// its own badge rather than being absorbed into Phi's.
    func testPiAgentKeepsItsOwnBadge() {
        for name in ["pi-agent.bundle", "pi-agent", "pi"] {
            let badge = AgentDriverBadge.make(agentName: name)
            XCTAssertEqual(badge.label, "Pi", "\(name) must not be labelled Phi")
            XCTAssertEqual(badge.assetName, "agent-pi")
        }
    }

    /// Two Grok products, one mark, two labels: the desktop app by its
    /// bundle name, the CLI by its signing id.
    func testGrokBotAndGrokBuildAreToldApart() {
        let bot = AgentDriverBadge.make(agentName: "Grok Bot")
        XCTAssertEqual(bot.label, "Grok Bot")
        XCTAssertEqual(bot.assetName, "agent-grokbot")
        let build = AgentDriverBadge.make(agentName: "xai-grok-pager")
        XCTAssertEqual(build.label, "Grok Build")
        XCTAssertEqual(build.assetName, "agent-grok")
    }

    /// The other brands still resolve, so the new branch did not shadow them.
    func testOtherAgentBrandsStillResolve() {
        let expected: [(String, String)] = [
            ("Claude Code", "agent-claude"),
            ("codex", "agent-openai"),
            ("Cursor", "agent-cursor"),
            ("hermes", "agent-hermes"),
            ("openclaw", "agent-openclaw"),
            ("grok", "agent-grok"),
            ("antigravity", "agent-antigravity"),
            ("copilot", "agent-copilot"),
            ("opencode", "agent-opencode"),
            ("qwen", "agent-qwen"),
            ("codebuddy", "agent-codebuddy"),
        ]
        for (name, asset) in expected {
            XCTAssertEqual(AgentDriverBadge.make(agentName: name).assetName,
                           asset, "\(name) lost its badge")
        }
    }
}
