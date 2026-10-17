// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// Settings says what is true on this Mac: a setup Grove made carries on as Grove had it,
/// a new one starts with nothing on — and what Capture the status line does is said once.
final class WorkspacesSettingsTextTests: XCTestCase {
    func testANewSetupIsToldNothingIsOnAndNothingAboutGrove() {
        for activation in [WorkspacesActivation.on, .paused, .off] {
            let text = WorkspacesSettingsTab.explanation(activation: activation, groveSetup: false)
            XCTAssertTrue(text.contains("the transcript safety net starts off for a new setup"), text)
            XCTAssertFalse(text.contains("you had in Grove"), "a new user never had Grove: \(text)")
        }
    }

    /// A Grove setup keeps its safety-net setting (on, in the README screenshot), so the
    /// text does not say it starts off.
    func testAGroveSetupIsToldItCarriesOn() {
        let text = WorkspacesSettingsTab.explanation(activation: .on, groveSetup: true)
        XCTAssertTrue(text.contains("runs the projects, accounts and settings you had in Grove"))
        XCTAssertTrue(text.contains("keeps the setting Grove gave it"))
        XCTAssertFalse(text.contains("starts off"))
        XCTAssertTrue(text.hasPrefix("Workspaces gives each feature"))
    }

    func testOffItSaysWhatStillRunsAndWhatTurningItOnDoes() {
        let text = WorkspacesSettingsTab.explanation(activation: .off, groveSetup: false)
        XCTAssertTrue(text.contains("Off, none of it runs, with one exception"))
        XCTAssertTrue(text.contains("Turned on, it keeps its projects"))
        XCTAssertFalse(WorkspacesSettingsTab.explanation(activation: .on, groveSetup: false).contains("Off, none"))
    }

    /// Once under the cards, in the words of the moment; nothing when no switch is shown.
    func testTheCaptureFootnote() {
        XCTAssertEqual(CaptureFootnote.text(activation: .on, waitsFor: nil, hasAccounts: true, hasDormantCaptures: false),
                       CaptureFootnote.capturing)
        XCTAssertNil(CaptureFootnote.text(activation: .on, waitsFor: nil, hasAccounts: false, hasDormantCaptures: false))
        XCTAssertEqual(CaptureFootnote.text(activation: .off, waitsFor: nil, hasAccounts: false, hasDormantCaptures: true),
                       DormantCaptureSwitch.explanation(activation: .off, waitsFor: nil))
        XCTAssertNil(CaptureFootnote.text(activation: .off, waitsFor: nil, hasAccounts: false, hasDormantCaptures: false))
        XCTAssertEqual(CaptureFootnote.text(activation: .paused, waitsFor: .anotherBrow, hasAccounts: false,
                                            hasDormantCaptures: true),
                       DormantCaptureSwitch.explanation(activation: .paused, waitsFor: .anotherBrow))
        // Off with Grove.app running: still off, and the switch waits for Grove to quit.
        let offUnderGrove = CaptureFootnote.text(activation: .off, waitsFor: .groveRunning, hasAccounts: false,
                                                 hasDormantCaptures: true)
        XCTAssertEqual(offUnderGrove, DormantCaptureSwitch.explanation(activation: .off, waitsFor: .groveRunning))
        XCTAssertNotEqual(offUnderGrove, DormantCaptureSwitch.explanation(activation: .off, waitsFor: nil))
        XCTAssertTrue(CaptureFootnote.capturing.contains("Turning it off puts your command back"))
    }
}
