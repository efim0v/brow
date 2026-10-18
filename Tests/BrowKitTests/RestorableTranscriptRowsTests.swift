// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// Settings › Workspaces lists what the safety net can put back; the words on each row.
final class RestorableTranscriptRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(cwd: String?, account: String?, daysAgo: Double) -> RestorableTranscript {
        RestorableTranscript(
            entry: VanishedTranscript(mirrorPath: "/m/k/-p/6f0c2a.jsonl", livePath: "/c/projects/-p/6f0c2a.jsonl",
                                      accountKey: "k", lastActivity: now.addingTimeInterval(-daysAgo * 86_400)),
            accountName: account, cwd: cwd)
    }

    func testARowNamesWhereTheSessionRanAndWhen() {
        let row = item(cwd: NSHomeDirectory() + "/Code/shop", account: "work", daysAgo: 3.4)
        XCTAssertEqual(RestorableTranscriptRows.place(row), "~/Code/shop")
        XCTAssertEqual(RestorableTranscriptRows.detail(row, now: now), "work · last active 3 days ago")
        XCTAssertEqual(RestorableTranscriptRows.detail(item(cwd: nil, account: "work", daysAgo: 0.2), now: now),
                       "work · last active today")
        XCTAssertEqual(RestorableTranscriptRows.detail(item(cwd: nil, account: nil, daysAgo: 1.5), now: now),
                       "last active yesterday")
        XCTAssertEqual(RestorableTranscriptRows.detail(row, now: now, name: { $0 == "work" ? "Work" : $0 }),
                       "Work · last active 3 days ago", "the account as the notch names it")
    }

    /// A transcript that records no folder is shown by its session id.
    func testWithoutAFolderTheSessionIdStandsIn() {
        XCTAssertEqual(RestorableTranscriptRows.place(item(cwd: nil, account: nil, daysAgo: 1)), "6f0c2a")
    }

    func testWhatRestoreSays() {
        XCTAssertEqual(RestorableTranscriptRows.outcome(asked: 1, restored: 1), "Put back.")
        XCTAssertEqual(RestorableTranscriptRows.outcome(asked: 3, restored: 3), "3 put back.")
        XCTAssertTrue(RestorableTranscriptRows.outcome(asked: 2, restored: 1).hasPrefix("1 of 2 put back"))
    }

    /// The Settings text promises nothing the safety net can't keep: no restore by
    /// itself, and the one source it can't see named.
    func testTheExplanationSaysNothingComesBackByItself() {
        let text = WorkspacesEngineSettings.safetyNetExplanation
        XCTAssertTrue(text.contains("Nothing comes back by itself"))
        XCTAssertTrue(text.contains("\u{2011}\u{2011}settings"), "the flag, with hyphens that don't break the line")
        XCTAssertFalse(text.contains("never keeps or restores"))
    }
}
