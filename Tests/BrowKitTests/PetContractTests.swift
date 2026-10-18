// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import BrowKit

/// The layer both halves of the pet are built on: the noise every quirk comes from, and the sums the
/// pet's numbers add up to (how long a meal takes, how fast hunger rises, how long each behaviour
/// lasts). A change that breaks one of these changes how the pet behaves, not just the code.
final class PetContractTests: XCTestCase {

    // MARK: - PetNoise

    /// SplitMix64's published first output for state 0: the mixer is the real one.
    func testSplitMixIsTheReferenceGenerator() {
        XCTAssertEqual(PetNoise.splitMix64(0), 0xE220_A839_7B1D_CDAF)
    }

    /// Pinned, because a pet keeps its quirks across launches and updates only while these hold.
    func testHashGivesTheSameNumbersOnEveryRun() {
        XCTAssertEqual(PetNoise.hash(0, PetNoise.Channel(0), 0), 0.13870941014555427)
        let seed: UInt64 = 1_311_768_467_294_899_695    // 0x1234567890ABCDEF, a seed far past 32 bits
        XCTAssertEqual(PetNoise.hash(seed, PetNoise.Channel(0x201), 0), 0.4880811995451152)
        XCTAssertEqual(PetNoise.hash(seed, PetNoise.Channel(0x201), 1), 0.5933027215065803)
        XCTAssertEqual(PetNoise.hash(1, PetNoise.Channel(0x100), 7), 0.6656516228647062)
        XCTAssertEqual(PetNoise.hash(2, PetNoise.Channel(0x200), -3), 0.16742632571020333)
    }

    func testHashIsAFractionSpreadOverTheUnitInterval() {
        var buckets = [Int](repeating: 0, count: 10)
        for index in 0..<10_000 {
            let x = PetNoise.hash(42, PetNoise.Channel(0x200), index)
            XCTAssertTrue(x >= 0 && x < 1, "\(x)")
            buckets[Int(x * 10)] += 1
        }
        // 1000 a bucket is fair; five standard deviations either side still fits in ±150.
        for count in buckets { XCTAssertTrue((850...1150).contains(count), "\(buckets)") }
    }

    /// Another channel, or another pet, is another stream: nothing is shared at the same index.
    func testChannelsAndSeedsAreSeparateStreams() {
        let first = (0..<100).map { PetNoise.hash(7, PetNoise.Channel(0x100), $0) }
        let otherChannel = (0..<100).map { PetNoise.hash(7, PetNoise.Channel(0x101), $0) }
        let otherPet = (0..<100).map { PetNoise.hash(8, PetNoise.Channel(0x100), $0) }
        XCTAssertEqual(Set(first).count, 100)
        XCTAssertTrue(zip(first, otherChannel).allSatisfy { $0 != $1 })
        XCTAssertTrue(zip(first, otherPet).allSatisfy { $0 != $1 })
    }

    // MARK: - What the numbers add up to

    /// How long each meal takes, full and as a nibble, by its chews, and the meal under Reduce Motion.
    func testMealsTakeTheirTimes() {
        func meal(_ size: PetMeal.Size, chews: Int, feast: Bool = false, reduceMotion: Bool = false) -> PetMeal {
            PetMeal(size: size, chews: chews, feast: feast, points: 3, reduceMotion: reduceMotion)
        }
        for (chews, total) in [(1, 1.34), (2, 1.66), (3, 1.98)] {
            XCTAssertEqual(meal(.full, chews: chews).duration, total, accuracy: 1e-9, "full, \(chews) chews")
        }
        for (chews, total) in [(1, 0.86), (2, 1.14), (3, 1.42)] {
            XCTAssertEqual(meal(.nibble, chews: chews).duration, total, accuracy: 1e-9, "nibble, \(chews) chews")
        }
        // The longest `eat` there is, a three-chew feast, and where a three-chew meal swallows.
        XCTAssertEqual(meal(.full, chews: 3, feast: true).duration, 2.38, accuracy: 1e-9)
        XCTAssertEqual(meal(.full, chews: 3).swallowStart, 1.62, accuracy: 1e-9)
        // A 0.15 s crossfade, 0.4 s a chew, a crossfade back.
        XCTAssertEqual(meal(.full, chews: 2, reduceMotion: true).swallowStart, 0.95, accuracy: 1e-9)
        XCTAssertEqual(meal(.full, chews: 2, reduceMotion: true).duration, 1.10, accuracy: 1e-9)
    }

    /// Hunger's calibration, worked out from `PetTuning.Hunger`'s constants.
    func testHungerKeepsItsCalibration() {
        typealias H = PetTuning.Hunger
        // One point of food is 18 minutes of hunger, and the break-even is 3.3 points an hour.
        XCTAssertEqual(H.perPoint / H.perHour * 60, 18, accuracy: 1e-9)
        XCTAssertEqual(H.perHour / H.perPoint, 3.33, accuracy: 0.01)
        // From 0 at the full rate: Peckish at 1 h 45 min, Hungry at 3 h 15 min, 100 at 5 h; from the
        // floor, 2 h 30 min back to 0.
        XCTAssertEqual((H.peckishFrom - H.contentAbove) / H.perHour * 60, 105, accuracy: 1e-9)
        XCTAssertEqual((H.hungryFrom - H.contentAbove) / H.perHour * 60, 195, accuracy: 1e-9)
        XCTAssertEqual(H.maximum / H.perHour, 5, accuracy: 1e-9)
        XCTAssertEqual(-H.minimum / H.perHour * 60, 150, accuracy: 1e-9)
        // The ends: Famished 4 h 30 min after 0, 1 h 15 min after Hungry. Stuffed takes about six points
        // from 0, about four from −10, a feast from 13 or below, and from the floor it lasts an hour.
        XCTAssertEqual((H.famishedFrom - H.contentAbove) / H.perHour * 60, 270, accuracy: 1e-9)
        XCTAssertEqual((H.famishedFrom - H.hungryFrom) / H.perHour * 60, 75, accuracy: 1e-9)
        XCTAssertEqual(-(H.fullAbove - H.moodHysteresis) / H.perPoint, 5.83, accuracy: 0.01)
        XCTAssertEqual((-10 - (H.fullAbove - H.moodHysteresis)) / H.perPoint, 4.17, accuracy: 0.01)
        XCTAssertEqual((H.fullAbove - H.moodHysteresis) + PetTuning.Plate.feastFrom * H.perPoint, 13, accuracy: 1e-9)
        XCTAssertEqual((H.fullAbove - H.minimum) / H.perHour * 60, 60, accuracy: 1e-9)
    }

    /// How long each behaviour lasts when nothing cuts it; the open ones have no length of their own.
    func testBehavioursLastTheirDurations() throws {
        let expected: [(PetBehaviour, TimeInterval?)] = [
            (.intro(noAccounts: false), 3.6), (.intro(noAccounts: true), 2.2),
            (.perk(.prompt), 0.5), (.perk(.freshData), 0.8),
            (.satisfied(.meal), 3.0), (.satisfied(.feast), 4.0), (.satisfied(.lick), 0.6),
            (.satisfied(.brim), 3.0), (.satisfied(.grateful), 3.0),
            (.boop(giggle: false), 0.6), (.boop(giggle: true), 1.2),
            (.celebrate(.streak(days: 7)), 2.4), (.celebrate(.goodWeek), 2.8),
            (.freshWindow, 1.0), (.fallAsleep, 2.6), (.wake, 2.7), (.rollOver, 1.0),
            (.enterDen(retreat: false), 3.2), (.enterDen(retreat: true), 1.6),
            (.leaveDen(stretch: true), 3.7), (.leaveDen(stretch: false), 1.6),
            (.peek, 2.2), (.dozeIn, 2.0), (.welcomeBack, 1.8),
            (.idle(.content), nil), (.settled(.hungry), nil), (.idle(.stuffed), nil), (.settled(.famished), nil),
            (.unsureIdle(.stuffed), nil), (.eager, nil), (.asleep, nil), (.drowsy, nil), (.stirring, nil),
            (.hibernating, nil), (.denWait, nil), (.unsureIdle(.full), nil), (.doze, nil), (.off, nil),
        ]
        for (behaviour, duration) in expected {
            if let duration {
                XCTAssertEqual(try XCTUnwrap(behaviour.duration), duration, accuracy: 1e-9, "\(behaviour)")
            } else {
                XCTAssertNil(behaviour.duration, "\(behaviour)")
            }
        }
        let feast = PetMeal(size: .full, chews: 3, feast: true, points: 9, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(PetBehaviour.eat(feast).duration), 2.38, accuracy: 1e-9)
    }

    /// The frame class each behaviour asks for, including the three that change class part-way: the
    /// wake, a streak's celebration and `off`.
    func testFrameClassesFollowTheTable() {
        let meal = PetMeal(size: .nibble, chews: 1, feast: false, points: 0.6, reduceMotion: false)
        XCTAssertEqual(PetBehaviour.idle(.hungry).frameClass(elapsed: 0), .idle)
        XCTAssertEqual(PetBehaviour.eager.frameClass(elapsed: 0), .idle)
        XCTAssertEqual(PetBehaviour.settled(.content).frameClass(elapsed: 0), .still)
        XCTAssertEqual(PetBehaviour.hibernating.frameClass(elapsed: 0), .still)
        XCTAssertEqual(PetBehaviour.asleep.frameClass(elapsed: 0), .sleep)
        XCTAssertEqual(PetBehaviour.stirring.frameClass(elapsed: 0), .sleep)
        XCTAssertEqual(PetBehaviour.eat(meal).frameClass(elapsed: 0), .fast)
        XCTAssertEqual(PetBehaviour.satisfied(.lick).frameClass(elapsed: 0), .action)
        XCTAssertEqual(PetBehaviour.satisfied(.brim).frameClass(elapsed: 1.5), .action)
        XCTAssertEqual(PetBehaviour.satisfied(.grateful).frameClass(elapsed: 1.5), .action)
        XCTAssertEqual(PetBehaviour.idle(.stuffed).frameClass(elapsed: 0), .idle)
        XCTAssertEqual(PetBehaviour.idle(.famished).frameClass(elapsed: 0), .idle)
        XCTAssertEqual(PetBehaviour.settled(.famished).frameClass(elapsed: 0), .still)
        XCTAssertEqual(PetBehaviour.denWait.frameClass(elapsed: 0), .off)
        XCTAssertEqual(PetBehaviour.peek.frameClass(elapsed: 0), .action)
        // The wake's shake, its last 0.5 s, runs fast; the stir and the stretch at the action rate.
        XCTAssertEqual(PetBehaviour.wake.frameClass(elapsed: 2.15), .action)
        XCTAssertEqual(PetBehaviour.wake.frameClass(elapsed: 2.25), .fast)
        // A streak's twirl runs fast; its first hop and its settle at the action rate. A good week has no
        // twirl.
        let streak = PetBehaviour.celebrate(.streak(days: 7))
        XCTAssertEqual(streak.frameClass(elapsed: 0.5), .action)
        XCTAssertEqual(streak.frameClass(elapsed: 1.3), .fast)
        XCTAssertEqual(streak.frameClass(elapsed: 2.0), .action)
        XCTAssertEqual(PetBehaviour.celebrate(.goodWeek).frameClass(elapsed: 1.3), .action)
        // Turned off: frames for the 0.2 s fade, then none.
        XCTAssertEqual(PetBehaviour.off.frameClass(elapsed: 0.15), .action)
        XCTAssertEqual(PetBehaviour.off.frameClass(elapsed: 0.25), .off)
        XCTAssertTrue(PetFrameClass.off < .still && .still < .sleep && .sleep < .idle && .idle < .action
                          && .action < .fast)
    }

    // MARK: - The readouts the zones are cut around

    /// The readout widths in `PetTuning.Readout` are what `EarsMetrics`' fonts really take: every strip
    /// zone is worked out from them, so a font change must fail here before it moves a zone onto a digit.
    @MainActor
    func testReadoutWidthsAreWhatTheFontsMeasure() throws {
        // Laid out at 8x, as the widths were measured, so to the eighth of a point. At 1x and 2x SwiftUI
        // rounds a text's frame up to the pixel: `100%` is 36 pt wide at 1x and 35.5 at 2x.
        func width(_ text: String, _ font: Font) throws -> CGFloat {
            let renderer = ImageRenderer(content: Text(text).font(font))
            renderer.scale = 8
            return CGFloat(try XCTUnwrap(renderer.cgImage, text).width) / 8
        }
        typealias R = PetTuning.Readout
        XCTAssertEqual(try width("—", EarsMetrics.readoutFont), R.dashWidth)
        XCTAssertEqual(try width("0%", EarsMetrics.readoutFont), R.oneDigitWidth)
        XCTAssertEqual(try width("41%", EarsMetrics.readoutFont), R.twoDigitWidth)
        XCTAssertEqual(try width("88%", EarsMetrics.readoutFont), R.twoDigitWidth, "tabular digits")
        XCTAssertEqual(try width("100%", EarsMetrics.readoutFont), R.threeDigitWidth)
        XCTAssertEqual(try width("F", EarsMetrics.initialFont), R.initialWidth)
    }

    func testPaletteColoursAreTheirHexValues() {
        XCTAssertEqual(PetRGB(hex: 0xFFC65C), PetRGB(red: 1, green: 198.0 / 255, blue: 92.0 / 255))
        XCTAssertEqual(PetPalette.original.colors.glow, PetRGB(hex: 0xFFA83A))
        XCTAssertEqual(PetPalette.paleGold.colors.glow, PetRGB(hex: 0xFFDD61))
        // The look the pet ships with: its light, and its drained shell, deep enough that hunger reads in
        // the strip.
        XCTAssertEqual(PetPalette.standard, .cream)
        XCTAssertEqual(PetPalette.cream.colors.lightCore, PetRGB(hex: 0xFFFFF6))
        XCTAssertEqual(PetPalette.cream.colors.dimCore, PetRGB(hex: 0xDCD0B6))
        XCTAssertEqual(PetPalette.cream.colors.dimEdge, PetRGB(hex: 0x9C907A))
    }

    /// Each look is its own set, and none throws more glow at the digits than the original does.
    func testEveryLookHasItsOwnColours() {
        let looks = PetPalette.allCases.map(\.colors)
        XCTAssertEqual(Set(looks).count, PetPalette.allCases.count)
        XCTAssertEqual(PetPalette.original.colors.glowGain, 1)
        for look in looks { XCTAssertTrue(look.glowGain > 0 && look.glowGain <= 1, "\(look.glowGain)") }
    }
}
