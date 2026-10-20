// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import BrowKit

/// `PetController`: what it tells the brain and when, the tracks and zones it keeps for the rig, the frame
/// rate it sets, the boop's hit test, the words and `pet.json`. The clock is a test's own, the accounts are
/// fictional and `pet.json` lives in a temporary directory; no senses run.
@MainActor
final class PetControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Setup {
        let pet: PetController
        let store: LimitsStore
        let clock: PetTestClock
        let dir: URL
        var petFile: URL { dir.appendingPathComponent("pet/pet.json") }
    }

    /// A pet that has had its intro, beside the 14" notch, started at `mono` on the monotonic clock.
    private func setup(_ accounts: [PetAppFixture.Account] = [.init()], scan: Bool = true, introDone: Bool = true,
                       placement: EarsPlacement = .beside, start: Bool = true, mono: TimeInterval = 10_000,
                       hunger: Double? = nil, edit: (inout BrowSettings) -> Void = { _ in }) async throws -> Setup {
        let (store, dir) = try await PetAppFixture.store(accounts, now: t0, edit: edit, scan: scan)
        let petStore = PetStore(directory: dir.appendingPathComponent("pet").path)
        if introDone {
            var save = PetSave(seed: 7, bornAt: t0.addingTimeInterval(-86_400))
            save.introDone = true
            save.savedAt = t0.addingTimeInterval(-60)
            if let hunger { save.hunger = hunger }
            try petStore.save(save)
        }
        let clock = PetTestClock(PetTime(wall: t0, mono: mono))
        let pet = PetController(store: store, petStore: petStore, clock: { clock.now }, senses: false,
                                defaults: UserDefaults(suiteName: "brow-pet-tests-\(UUID().uuidString)")!)
        pet.layout(frames: PetStage.frames(placement), aggregate: store.aggregate, showEars: true)
        if start { pet.start() }
        return Setup(pet: pet, store: store, clock: clock, dir: dir)
    }

    // MARK: Launch

    /// Before the first scan lands, no rows means "not looked yet": the brain hears nothing, plans
    /// nothing, and nothing is drawn. Once a scan has landed, an empty list is "no accounts".
    func testReadingsWaitForTheFirstScanWhenThereAreNoRows() async throws {
        let s = try await setup([], scan: false)
        XCTAssertFalse(s.store.hasScanned)
        XCTAssertTrue(s.pet.brain.timeline.segments.isEmpty)
        XCTAssertNil(s.pet.layer.frame(at: s.clock.now.mono))
        await s.store.bootstrap()
        XCTAssertTrue(s.store.hasScanned)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(s.pet.brain.condition, .noAccounts)
        XCTAssertFalse(s.pet.layer.timeline.segments.isEmpty)
    }

    /// With accounts the brain is told everything at start, the layer gets its plan, and an awake pet at
    /// rest draws at 30 frames a second.
    func testStartTellsTheBrainAndTheLayerDrawsAtThirty() async throws {
        let s = try await setup()
        XCTAssertEqual(s.pet.brain.condition, .awake(.content))
        XCTAssertEqual(s.pet.layer.timeline, s.pet.brain.timeline)
        XCTAssertEqual(s.pet.layer.seed, 7)
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
        XCTAssertNotNil(s.pet.layer.frame(at: s.clock.now.mono + 1))
        XCTAssertEqual(s.pet.layer.zones?.strip?.kind, .beside)
    }

    /// The pet's own file is written at start (a new seed must stick) and again on quit.
    func testPetJsonIsWrittenAtStartAndOnQuit() async throws {
        let s = try await setup(introDone: false)
        let first = PetStore(directory: s.petFile.deletingLastPathComponent().path).load(now: t0).save
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.petFile.path))
        s.clock.advance(120)
        s.pet.flush()
        let second = PetStore(directory: s.petFile.deletingLastPathComponent().path).load(now: t0.addingTimeInterval(200)).save
        XCTAssertEqual(second.seed, first.seed)
        XCTAssertEqual(second.savedAt.timeIntervalSince1970, t0.addingTimeInterval(120).timeIntervalSince1970, accuracy: 1)
    }

    /// The every-10-minutes save is skipped when it would write the same pet: away, the hunger clock
    /// stops and nothing in the file changes. Quitting writes it whatever it holds.
    func testAPetThatHasNotChangedIsNotWrittenAgain() async throws {
        let s = try await setup()
        let store = PetStore(directory: s.petFile.deletingLastPathComponent().path)
        let later = t0.addingTimeInterval(86_400)
        func saved() -> TimeInterval { store.load(now: later).save.savedAt.timeIntervalSince(t0) }
        XCTAssertEqual(saved(), 0, accuracy: 1)
        // Away from 5 s on, the numbers going stale at 575 s, then 21 minutes of nothing.
        for n in 0..<260 {
            s.clock.advance(5)
            s.pet.sensed(.presence(PetPresence(inputIdle: 700 + 5 * Double(n))), at: s.clock.now)
        }
        let stale = PetTuning.Stale.unsure - PetAppFixture.Account().age
        XCTAssertEqual(saved(), stale, accuracy: 1,
                       "written at the change of condition, with the hunger of the seconds before it went away, and not again")
        s.pet.flush()
        XCTAssertEqual(saved(), 1300, accuracy: 1, "written on quit")
    }

    // MARK: The pointer, the dock, the layout

    /// Every move goes on the track, which keeps 2 s and the sample before them; the brain hears the
    /// distance from the eyes, notices within 160 pt, and the eyes following raise the rate to 60.
    func testThePointerFeedsTheTrackTheBrainAndTheRate() async throws {
        let s = try await setup()
        let zone = try XCTUnwrap(s.pet.layer.zones?.strip)
        let eyes = CGPoint(x: zone.anchor.x, y: zone.anchor.y - 15)
        s.clock.advance(1)
        s.pet.pointerMoved(to: CGPoint(x: eyes.x - 60, y: eyes.y + 80))
        XCTAssertEqual(s.pet.brain.timeline.cues.last?.kind, .notice)
        XCTAssertEqual(s.pet.layer.rate, .fps(60))
        for _ in 0..<30 {
            s.clock.advance(0.1)
            s.pet.pointerMoved(to: CGPoint(x: eyes.x + 400, y: eyes.y + 300))
        }
        let samples = s.pet.layer.pointer.samples
        XCTAssertEqual(samples.count, 21, "the last 2 s, and the one sample before them")
        XCTAssertLessThanOrEqual(samples[0].t, s.clock.now.mono - PetPointerTrack.history)
        XCTAssertGreaterThan(samples[1].t, s.clock.now.mono - PetPointerTrack.history)
        XCTAssertEqual(s.pet.brain.timeline.cues.last?.kind, .release)
        XCTAssertEqual(s.pet.layer.rate, .fps(30), "far away, the eyes follow nothing")
    }

    /// The pointer comes near and stops there: half a second after its last move the eyes have nothing to
    /// follow, and the timer brings the rate back down with no other event. This one waits for the real
    /// timer on the main queue.
    func testThePointerRateFallsBackWhenThePointerStops() async throws {
        let s = try await setup()
        let zone = try XCTUnwrap(s.pet.layer.zones?.strip)
        let eyes = CGPoint(x: zone.anchor.x, y: zone.anchor.y - 15)
        s.clock.advance(1)
        s.pet.pointerMoved(to: CGPoint(x: eyes.x - 60, y: eyes.y + 80))
        XCTAssertEqual(s.pet.layer.rate, .fps(60))
        s.clock.advance(0.6)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(s.pet.layer.rate, .fps(30), "the eyes are idle again")
    }

    /// The timer walked the way the app walks it, each firing a moment after the deadline it was set
    /// for: every firing ticks the brain, so eager ends 90 s after the prompt, at that very instant, and
    /// not at whatever event comes next.
    func testEveryFiringOfTheTimerTicksTheBrain() async throws {
        let s = try await setup()
        s.clock.advance(1)
        s.pet.sensed(.prompt, at: s.clock.now)
        let prompt = s.clock.now.mono
        XCTAssertEqual(s.pet.layer.timeline.segments.last?.behaviour, .eager)
        var firings = 0
        while let deadline = s.pet.brain.nextDeadline(after: s.clock.now), deadline.mono < prompt + 95, firings < 500 {
            s.clock.advance(deadline.mono - s.clock.now.mono + 0.002)
            s.pet.timerFired()
            firings += 1
        }
        let playing = s.pet.layer.timeline.segments.last { $0.start <= prompt + 91 }
        XCTAssertEqual(playing?.behaviour, .idle(.content), "eager ends 90 s after the prompt")
        XCTAssertEqual(try XCTUnwrap(playing).start, prompt + PetTuning.Eager.afterPrompt, accuracy: 1e-6,
                       "at the deadline's own instant")
        XCTAssertEqual(s.pet.layer.timeline, s.pet.brain.timeline)
    }

    /// The pointer asks the senses for a fresh presence check once the pet may have settled: by the idle the
    /// last check found plus the time since it, since the brain settles the pet on its own clock and a check
    /// can be five seconds old.
    func testThePointerAsksForPresenceOnceThePetMayHaveSettled() {
        let check = PetPresence(inputIdle: 118)
        XCTAssertFalse(PetController.mayHaveSettled(check, heardAt: 1000, now: 1001.5))
        XCTAssertTrue(PetController.mayHaveSettled(check, heardAt: 1000, now: 1002), "settled since 1002")
        XCTAssertTrue(PetController.mayHaveSettled(PetPresence(inputIdle: 700), heardAt: 1000, now: 1000), "dozing")
        XCTAssertFalse(PetController.mayHaveSettled(PetPresence(), heardAt: nil, now: 1000))
    }

    /// The idle's pounce winds up and leaps faster than ambient motion may move at 30 fps: the timer is set
    /// for the start of its fast window, the layer draws it at the fast rate, and at the window's end it
    /// is back to 30.
    func testThePouncesLeapIsDrawnFast() async throws {
        // One of the pet's pounces, and a start a minute before it, in the idle it plays in.
        let k = try XCTUnwrap((12...400).first { PetRigIdle.rareKind($0, seed: 7) == .pounce })
        let pounce = PetRigIdle.rares.time(k, seed: 7)
        let s = try await setup(mono: pounce - 60)
        XCTAssertEqual(s.pet.layer.timeline.segments.last?.behaviour, .idle(.content))
        let fast = PetRigIdle.pounceFast
        s.clock.advance(55)
        s.pet.sensed(.presence(PetPresence(inputIdle: 0)), at: s.clock.now)
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
        XCTAssertEqual(try XCTUnwrap(s.pet.timerDue), pounce + fast.lowerBound, accuracy: 1e-9)
        s.clock.advance(pounce + fast.lowerBound + 0.002 - s.clock.now.mono)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .native, "the wind-up and the leap")
        XCTAssertEqual(try XCTUnwrap(s.pet.timerDue), pounce + fast.upperBound, accuracy: 1e-9)
        s.clock.advance(pounce + fast.upperBound + 0.002 - s.clock.now.mono)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
    }

    /// Opening the panel on a stuffed pet: the brain hears it, cues the greeting once the hop has landed,
    /// and the thumbs-up's rise is drawn fast past the hop's own frames, the timer waking at both ends.
    func testAGreetingsRiseIsDrawnFast() async throws {
        let s = try await setup(mono: 10_000, hunger: -46)
        XCTAssertEqual(s.pet.brain.timeline.segments.last?.behaviour, .idle(.stuffed))
        s.clock.advance(20)
        let opened = s.clock.now.mono
        s.pet.dockChanged(expanded: true)
        XCTAssertEqual(try XCTUnwrap(s.pet.timerDue), opened + PetTuning.Greet.after, accuracy: 1e-9)
        s.clock.advance(PetTuning.Greet.after + 0.002)
        s.pet.timerFired()
        let cue = try XCTUnwrap(s.pet.brain.timeline.cues.last { $0.kind == .greet })
        XCTAssertEqual(cue.t, opened + PetTuning.Greet.after, accuracy: 1e-9)
        XCTAssertEqual(s.pet.layer.timeline, s.pet.brain.timeline)
        let segments = s.pet.brain.timeline.segments
        let played = PetRigMoodBeats.gestures(in: segments[segments.count - 1], previous: segments.count > 1 ? segments[segments.count - 2] : nil,
                                              at: cue.t + 3, lookBack: 3.5, seed: 7, reduceMotion: false,
                                              cues: s.pet.brain.timeline.cues)
        let okay = try XCTUnwrap(played.first { $0.item == .beat(.okay) && $0.at >= cue.t })
        let fast = try XCTUnwrap(PetRigMoodBeats.fast(.okay))
        // Past the hop's own fast frames, the rise keeps them.
        s.clock.advance(PetController.dockFrames + 0.05 - (s.clock.now.mono - opened))
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .native, "the thumbs-up's rise")
        XCTAssertEqual(try XCTUnwrap(s.pet.timerDue), okay.at + fast.upperBound, accuracy: 1e-9)
        s.clock.advance(okay.at + fast.upperBound + 0.002 - s.clock.now.mono)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
    }

    /// `setExpanded` is a dock change at its own instant, and the hop draws at the fast rate until it has
    /// settled. Only the last expand or collapse is kept once it is older than 2 s.
    func testExpandAndCollapseAreDockChangesAndTheHopIsDrawnFast() async throws {
        let s = try await setup()
        let opened = s.clock.now.mono
        s.pet.dockChanged(expanded: true)
        XCTAssertEqual(s.pet.layer.dock.changes, [PetDockChange(t: opened, kind: .expand)])
        XCTAssertEqual(s.pet.layer.rate, .native)
        s.clock.advance(PetController.dockFrames + 0.05)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
        s.clock.advance(3)
        s.pet.dockChanged(expanded: false)
        XCTAssertEqual(s.pet.layer.dock.changes, [PetDockChange(t: s.clock.now.mono, kind: .collapse)])
    }

    /// The Ears picker moves the pet with a fade; a readout that changes width does not, its zone simply
    /// follows the digits.
    func testARelayoutFadesAndAWiderReadoutDoesNot() async throws {
        let s = try await setup()
        s.clock.advance(1)
        s.pet.layout(frames: PetStage.frames(.beside), aggregate: PetStage.aggregate(left: 100), showEars: true)
        XCTAssertTrue(s.pet.layer.dock.changes.isEmpty)
        XCTAssertEqual(s.pet.layer.zones?.strip?.bounds.minX, PetLayout.zones(frames: PetStage.frames(.beside),
            aggregate: PetStage.aggregate(left: 100), showEars: true, fiveHour: nil).strip?.bounds.minX)
        let before = s.pet.layer.zones
        s.pet.layout(frames: PetStage.frames(.below), aggregate: PetStage.aggregate(left: 100), showEars: true)
        XCTAssertEqual(s.pet.layer.dock.changes.last?.kind, .relayout(from: try XCTUnwrap(before)))
        XCTAssertEqual(s.pet.layer.zones?.strip?.kind, .below)
    }

    /// A click on the posed body (and 4 pt round it) in the open panel boops the pet; anywhere else, or
    /// with the panel closed, it does not.
    func testAClickOnThePetInThePanelBoopsIt() async throws {
        let s = try await setup()
        let panel = try XCTUnwrap(s.pet.layer.zones?.panel)
        let body = CGPoint(x: panel.anchor.x, y: panel.anchor.y - 20)
        XCTAssertFalse(s.pet.click(at: body), "collapsed, the strip takes no click")
        s.pet.dockChanged(expanded: true)
        s.clock.advance(1.5)
        XCTAssertFalse(s.pet.click(at: CGPoint(x: 300, y: 150)))
        XCTAssertTrue(s.pet.click(at: body))
        XCTAssertTrue(s.pet.brain.timeline.segments.contains { if case .boop = $0.behaviour { return true }; return false })
    }

    // MARK: Visibility and the setting

    /// An occluded window is a closed gate and an unseen pet for the brain.
    func testAnOccludedWindowPausesTheLayerAndHidesThePet() async throws {
        let s = try await setup()
        XCTAssertTrue(s.pet.brain.visibleFlag)
        s.pet.windowVisibility(false)
        XCTAssertFalse(s.pet.brain.visibleFlag)
        XCTAssertEqual(s.pet.layer.rate, .paused)
        s.pet.windowVisibility(true)
        XCTAssertEqual(s.pet.layer.rate, .fps(30))
    }

    /// Away by input: the presence check that finds 600 s without input starts the 2.0 s doze-in, which
    /// is drawn; then the doze, and no frames, the layer resting on the settled doze. Later checks leave
    /// that frame alone.
    func testTheDozeInIsDrawnAndThenTheFramesStop() async throws {
        let s = try await setup()
        s.clock.advance(5)
        s.pet.sensed(.presence(PetPresence(inputIdle: 605)), at: s.clock.now)
        let dozeIn = try XCTUnwrap(s.pet.layer.timeline.segments.last { $0.behaviour == .dozeIn })
        XCTAssertEqual(dozeIn.start, s.clock.now.mono)
        XCTAssertEqual(s.pet.layer.rate, .fps(30), "the doze-in plays")
        s.clock.advance(PetTuning.Behaviour.dozeIn + 0.002)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.timeline.segments.last?.behaviour, .doze)
        XCTAssertEqual(s.pet.layer.rate, .paused)
        XCTAssertEqual(s.pet.layer.frozenAt, dozeIn.start + PetTuning.Behaviour.dozeIn + PetController.settle)
        let redraws = s.pet.layer.redraws
        for n in 1...3 {
            s.clock.advance(5)
            s.pet.sensed(.presence(PetPresence(inputIdle: 607 + 5 * Double(n))), at: s.clock.now)
        }
        XCTAssertEqual(s.pet.layer.redraws, redraws, "a presence check redraws nothing while it dozes")
    }

    /// Off: the pet fades out over 0.2 s at the action rate, then the layer pauses with nothing drawn and
    /// no timer is left.
    func testTurningThePetOffFadesItOutThenStopsEverything() async throws {
        let s = try await setup()
        s.clock.advance(1)
        s.store.settings.showPet = false
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(s.pet.brain.condition, .off)
        XCTAssertEqual(s.pet.layer.rate, .fps(60))
        XCTAssertFalse(s.pet.layer.isOn)
        s.clock.advance(0.5)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .paused)
        XCTAssertNil(s.pet.layer.frame())
        XCTAssertNil(s.pet.brain.nextDeadline(after: s.clock.now))
    }

    /// The pet lives in the notch. With Brow out of it (Settings › General › Show Brow in the notch off)
    /// there is nowhere to see the pet, so it is off as if its own switch were: it fades out, then nothing
    /// is drawn and no timer is left. Back in the notch it is the same pet, awake again.
    func testOutOfTheNotchThePetIsOff() async throws {
        let s = try await setup()
        let seed = s.pet.brain.seed
        s.clock.advance(1)
        s.store.settings.showNotch = false
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(s.pet.brain.condition, .off)
        XCTAssertFalse(s.pet.layer.isOn)
        s.clock.advance(0.5)
        s.pet.timerFired()
        XCTAssertEqual(s.pet.layer.rate, .paused)
        XCTAssertNil(s.pet.layer.frame())
        XCTAssertNil(s.pet.brain.nextDeadline(after: s.clock.now))
        s.clock.advance(60)
        s.store.settings.showNotch = true
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(s.pet.layer.isOn)
        XCTAssertEqual(s.pet.brain.condition, .awake(.content))
        XCTAssertEqual(s.pet.brain.seed, seed, "the same pet")
    }

    /// Launched with Brow out of the notch, the pet starts off, though its own switch is on.
    func testLaunchedOutOfTheNotchThePetStartsOff() async throws {
        let s = try await setup(edit: { $0.showNotch = false })
        XCTAssertTrue(s.store.settings.showPet)
        XCTAssertEqual(s.pet.brain.condition, .off)
        XCTAssertFalse(s.pet.layer.isOn)
        XCTAssertNil(s.pet.brain.nextDeadline(after: s.clock.now))
    }

    // MARK: The words

    /// Opening the panel publishes the header's words, the meter and the VoiceOver value at once, from
    /// `PetText`.
    func testOpeningThePanelPublishesTheWords() async throws {
        let s = try await setup()
        s.pet.dockChanged(expanded: true)
        XCTAssertEqual(s.pet.panel.header.word, "Content")
        XCTAssertEqual(s.pet.panel.meter, 30, accuracy: 0.5)
        XCTAssertTrue(s.pet.panel.accessibilityValue.hasPrefix("Content. "))
        XCTAssertTrue(s.pet.panel.accessibilityValue.hasSuffix("Hunger 30 percent."))
        XCTAssertEqual(s.pet.layer.accessibilityValue, s.pet.panel.accessibilityValue)
    }

    // MARK: The panel

    /// The outline opens and closes on the very springs the hop is timed against.
    func testTheOutlineSpringsAreTheHopsSprings() {
        XCTAssertEqual(NotchPanelController.openAnimation, .spring(response: 0.32, dampingFraction: 0.86))
        XCTAssertEqual(NotchPanelController.closeAnimation, .spring(response: 0.26, dampingFraction: 1.0))
        XCTAssertEqual(NotchPanelController.openAnimation,
                       .spring(response: PetTuning.Hop.openResponse, dampingFraction: PetTuning.Hop.openDamping))
    }

    /// The header row and its stack spacing, 52 + 10 pt, only while the pet is on.
    func testTheHeaderAddsItsRowToThePanelsHeight() {
        let without = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 3], topInset: 40)
        let with = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 3], topInset: 40, pet: true)
        XCTAssertEqual(with - without, 62)
    }
}

/// What the controller adds per event, measured only when asked, in a release build:
///
///     PET_PERF=1 swift test -c release --filter PetControllerCostTests
///
/// A pointer move comes up to 120 times a second; a presence check every 5 s runs the whole after-event
/// path (the save schedule, the frame rate, the timer and the brain's next deadline).
@MainActor
final class PetControllerCostTests: XCTestCase {
    func testThePointerAndPresencePathsAreCheap() async throws {
        guard ProcessInfo.processInfo.environment["PET_PERF"] != nil else {
            throw XCTSkip("set PET_PERF=1 (and run with -c release) to measure the controller")
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, dir) = try await PetAppFixture.store([.init()], now: t0)
        let petStore = PetStore(directory: dir.appendingPathComponent("pet").path)
        var save = PetSave(seed: 7, bornAt: t0.addingTimeInterval(-86_400))
        save.introDone = true
        try petStore.save(save)
        let clock = PetTestClock(PetTime(wall: t0, mono: 10_000))
        let pet = PetController(store: store, petStore: petStore, clock: { clock.now }, senses: false,
                                defaults: UserDefaults(suiteName: "brow-pet-cost-\(UUID().uuidString)")!)
        pet.layout(frames: PetStage.frames(.beside), aggregate: store.aggregate, showEars: true)
        pet.start()
        // 100 s of a pointer circling 60 to 260 pt from the pet at 120 Hz.
        let moves = 12_000
        var started = ContinuousClock.now
        for n in 0..<moves {
            clock.advance(1.0 / 120)
            let a = Double(n) / 120
            pet.pointerMoved(to: CGPoint(x: 150 + (160 + 100 * sin(a / 3)) * cos(a), y: 30 + 120 * abs(sin(a))))
        }
        let pointer = PetPerfLog.seconds(ContinuousClock.now - started) / Double(moves)
        // An hour of presence checks every 5 s.
        let checks = 720
        started = ContinuousClock.now
        for n in 0..<checks {
            clock.advance(5)
            pet.sensed(.presence(PetPresence(inputIdle: Double(n % 30))), at: clock.now)
        }
        let presence = PetPerfLog.seconds(ContinuousClock.now - started) / Double(checks)
        print(String(format: "pet controller: a pointer move %.1f µs, a presence check %.1f µs", pointer * 1e6, presence * 1e6))
        pet.flush()
    }
}
