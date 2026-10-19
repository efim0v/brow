// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// The envelopes a message from another agent arrives in, read leniently.
final class AgentEnvelopeTests: XCTestCase {
    func testTheThreeEnvelopesAndWhoSentThem() {
        let cross = AgentEnvelope.all(in: "<cross-session-message from=\"uds:/tmp/cc-socks/41001.sock\" from-name=\"atlas\">\nDone.\nSecond line.\n</cross-session-message>")
        XCTAssertEqual(cross, [AgentEnvelope(kind: .crossSession,
                                             attributes: ["from": "uds:/tmp/cc-socks/41001.sock", "from-name": "atlas"],
                                             body: "Done.\nSecond line.")])
        XCTAssertEqual(cross.first?.senderName, "atlas")
        let team = AgentEnvelope.all(in: "<teammate-message teammate_id=\"scout\" color=\"blue\" summary=\"x\">\nIt depends on the clock.\n</teammate-message>")
        XCTAssertEqual(team.first?.senderName, "scout")
        XCTAssertEqual(team.first?.attributes["summary"], "x")
        let agent = AgentEnvelope.all(in: "<agent-message from=\"lumen\">\nOne FK is missing.\n</agent-message>")
        XCTAssertEqual(agent.first?.kind, .agent)
        XCTAssertEqual(agent.first?.senderName, "lumen")
    }

    /// Attributes in another order, one this reader has never seen, and two envelopes in
    /// one text.
    func testReadLeniently() {
        let text = "<cross-session-message from-name=\"atlas\" from-x=\"1\" from=\"uds:/tmp/cc-socks/41001.sock\">\nOne more thing.\n</cross-session-message>\n\n<teammate-message teammate_id=\"team-lead\">\nbye\n</teammate-message>"
        let found = AgentEnvelope.all(in: text)
        XCTAssertEqual(found.map(\.kind), [.crossSession, .teammate])
        XCTAssertEqual(found.first?.attributes["from"], "uds:/tmp/cc-socks/41001.sock")
        XCTAssertEqual(found.first?.attributes["from-x"], "1")
        XCTAssertEqual(found.first?.body, "One more thing.")
        XCTAssertEqual(found.last?.senderName, "team-lead")
    }

    func testPlainTextHasNone() {
        XCTAssertEqual(AgentEnvelope.all(in: "just a prompt"), [])
        XCTAssertEqual(AgentEnvelope.all(in: "<other-message>x</other-message>"), [])
        XCTAssertNil(AgentEnvelope(kind: .crossSession, attributes: [:], body: "x").senderName)
    }
}
