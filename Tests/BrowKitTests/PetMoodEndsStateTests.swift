// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The two ends of the meter through the state machine: the brain's mood and the rig's reading of it agree
/// across meals, boops, rest and absence.
final class PetMoodEndsStateTests: XCTestCase {
    let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))

    /// A pet fed `points` from `hunger`, booped a second into the satisfaction that follows: the brain's
    /// timeline, and the boop's segment.
    private func boopedAfterAMeal(from hunger: Double, points: Double) throws -> (pet: PetHarness, boop: PetSegment) {
        var pet = PetHarness(hunger: hunger)
        pet.accounts[0].five = 10
        pet.start()
        pet.accounts[0].five = 10 + points
        pet.refresh(at: 20)
        pet.run(to: 23)
        let satisfied = try XCTUnwrap(pet.played(20...23).first { if case .satisfied = $0.behaviour { return true }; return false })
        pet.send(.boop, at: satisfied.start + 1)
        pet.run(to: satisfied.start + 1.3)
        let boop = try XCTUnwrap(pet.played(20...30).first { if case .boop = $0.behaviour { return true }; return false })
        return (pet, boop)
    }

    private func boopPosture(_ pet: PetHarness, _ boop: PetSegment) -> PetPosture {
        var script = PetReelScript()
        script.timeline = pet.brain.timeline
        let scene = PetMoodEndsTests.scene(script, at: boop.start + 0.3, zones: zones)
        return PetRigActions.posture(boop.behaviour, elapsed: 0.3, scene: scene, start: boop.start)
    }

    /// Booped during the brim, a pet the meal has just made stuffed is booped as a stuffed pet, not in the
    /// face of the Full pet it was before the meal.
    func testABoopAfterTheMealThatMadeItStuffedIsAStuffedPets() throws {
        let (pet, boop) = try boopedAfterAMeal(from: -10, points: 6)
        XCTAssertEqual(pet.brain.mood, .stuffed)
        XCTAssertTrue(pet.played(20...30).contains { $0.behaviour == .satisfied(.brim) })
        let posture = boopPosture(pet, boop)
        XCTAssertEqual(posture.body.glow, PetPosture.stuffed.body.glow, accuracy: 1e-9)
        XCTAssertEqual(posture.body.armL, PetPosture.stuffed.body.armL, accuracy: 1e-9, "the nubs on the belly")
    }

    /// Booped during the grateful beat, a famished pet the meal has fed out of it is no longer famished: no
    /// shining eyes on tiptoe after the food.
    func testABoopAfterAFamishedPetsMealIsNoLongerFamished() throws {
        let (pet, boop) = try boopedAfterAMeal(from: 96, points: 3)
        XCTAssertEqual(pet.brain.mood, .hungry)
        XCTAssertTrue(pet.played(20...30).contains { $0.behaviour == .satisfied(.grateful) })
        let posture = boopPosture(pet, boop)
        XCTAssertEqual(posture.body.shine, 0, accuracy: 1e-9)
        XCTAssertEqual(posture.foodLean, 0, accuracy: 1e-9)
        XCTAssertEqual(posture.body.glow, PetPosture.content.body.glow, accuracy: 1e-9, "a boop's own face, as at any mood between the ends")
    }

    /// At rest the boop keeps the mood it rests in, as before.
    func testABoopAtRestKeepsTheEnd() throws {
        for (hunger, mood) in [(-46.0, PetMood.stuffed), (96, .famished)] {
            var pet = PetHarness(hunger: hunger)
            pet.start()
            pet.send(.boop, at: 30)
            pet.run(to: 31)
            let boop = try XCTUnwrap(pet.played(0...31).first { if case .boop = $0.behaviour { return true }; return false })
            XCTAssertEqual(boopPosture(pet, boop).body.glow, PetPosture.mood(mood).body.glow, accuracy: 1e-9, "\(mood)")
        }
    }
}
