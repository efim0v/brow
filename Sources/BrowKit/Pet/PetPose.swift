// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// One posed instant of the pet: everything `PetCanvas` draws, and what the layer and the hit test need
/// from it. Every position is in window coordinates, like `PetZone`'s. Two frames of the same arguments
/// are equal bit for bit, which is what the determinism tests compare.
public struct PetFrame: Sendable, Equatable {
    /// The pet.
    public var pet: PetBody
    /// A second, fading pet: only while Reduce Motion crossfades the strip's pet out and the header's
    /// in, which overlap for 0.05 s. nil otherwise.
    public var echo: PetBody?
    /// Crumbs, sparkles, Zzz, rumble lines, the splash's ring: at most `PetTuning.Particles.maximumAlive`.
    public var particles: [PetParticle] = []
    /// The food: a bead of light that pops out of the number and is inhaled along an arc.
    public var bead: PetBead?
    /// A glint on the ripe digit before a meal: light added over the readout, never a moved or hidden
    /// glyph.
    public var glint: PetGlint?
    /// Below, hibernating: the light under the door, a line of glow along the notch's bottom edge.
    public var doorLight: PetDoorLight?
    /// The box of the body, arms and feet: the boop's hit test (with `PetTuning.Boop.hitSlop`) and the
    /// zone tests. `.null` while nothing is drawn.
    public var bodyBox: CGRect = .null
    /// Where the pet's own canvas sits: 64 × 44 pt at scale 1 up to 128 × 112 at scale 2, centred on
    /// the pet and grown only when a particle or the food needs more room.
    public var canvas: CGRect = .zero
    /// The camera: nothing is drawn inside it, in any dock state.
    public var notch: CGRect?
    /// Beside, the den's edge (`notch.minX`): the side of the pet next to it falls into the camera's
    /// shadow, so going in reads as going behind something.
    public var denEdge: CGFloat?
    /// The readouts' near edges, left and right of the zone: the pet's light stays under
    /// `PetTuning.Light.glowAtReadout` past them, so it never washes over the numbers.
    public var guardMinX: CGFloat?
    public var guardMaxX: CGFloat?
    /// Where food comes from and the colour of its dot (nil: grey), for the crumbs and the trace of that
    /// colour on the near rim.
    public var foodSource: CGPoint?
    public var foodDot: Severity?
    /// The display options the drawing follows: Reduce Motion, Reduce Transparency, Increase Contrast.
    public var motion = PetMotion()

    public init(pet: PetBody) {
        self.pet = pet
    }

    /// Nothing to draw: the pet is off, dozing, or has nowhere to be.
    public var isEmpty: Bool { pet.opacity <= 0.001 && (echo?.opacity ?? 0) <= 0.001 }
}

/// The pet's pose in one frame: Glim's rig channels, posed by `PetRig` and drawn by `PetCanvas`. Lengths
/// are points at scale 1 times `size`.
public struct PetBody: Sendable, Equatable {
    // MARK: Placement

    /// The point between the feet, in window coordinates.
    public var x: Double = 0
    /// Where the feet stand.
    public var floorY: Double = 0
    /// How far the feet are above the floor (a hop, the lunge).
    public var lift: Double = 0
    /// The zone's scale: 1 beside, 0.80 below, 0.82 on the pill, 2 in the panel.
    public var size: Double = 1
    /// 0 transparent ... 1 opaque.
    public var opacity: Double = 1

    // MARK: Body

    /// Vertical scale; the width follows so the area is kept (`sx = 1 / sy`).
    public var squash: Double = 1
    /// A real change of size: a full belly, a deep breath.
    public var girth: Double = 1
    /// Shear: how far the top moves per point of height (+ is right).
    public var lean: Double = 0
    /// Rotation about the contact point, radians (+ puts the top to the right).
    public var tilt: Double = 0
    /// Lying down: 0 sitting up ... 1 curled into a low loaf, asleep (at most 14 pt tall beside).
    public var curl: Double = 0
    /// 0 ... 1: full cheeks bulge the outline; `cheekBias` -1 the left is fuller ... 1 the right.
    public var cheekPuff: Double = 0
    public var cheekBias: Double = 0
    /// A swallowed bite on its way down, 0 at the mouth ... 1 in the belly; below 0, none.
    public var lump: Double = -1
    /// A fine shiver of the outline, already a smooth wave (a stretch's effort, a rumble).
    public var tremor: Double = 0
    /// The speed stretch along fast travel, area kept: `smear` along `smearAngle` (radians), 1 / smear
    /// across it.
    public var smear: Double = 1
    public var smearAngle: Double = 0
    /// 0 ... 1: a round belly bulging the lower outline, from the meter past the brim
    /// (`PetRigMeter.belly`): stuffed. None while curled up.
    public var belly: Double = 0

    // MARK: Face, painted on a sphere

    /// -1 the face looks left ... 1 right; `nod` -1 down ... 1 up; `spin` a whole turn about the
    /// vertical axis, radians (a twirl shows its back).
    public var turn: Double = 0
    public var nod: Double = 0
    public var spin: Double = 0
    /// The eyes inside the face, -1 ... 1.
    public var lookX: Double = 0
    public var lookY: Double = 0
    /// 1 open ... 0 shut.
    public var lidL: Double = 1
    public var lidR: Double = 1
    /// + the outer corners droop, - they lift.
    public var lidSlant: Double = 0
    /// 0 bean eyes ... 1 closed happy arcs.
    public var happy: Double = 0
    /// 0 ... 1 eyes squeezed shut with effort.
    public var squeeze: Double = 0
    public var eyeSize: Double = 1
    /// 0 ... 1 each: that eye alone closes into a happy arc, a wink.
    public var winkL: Double = 0
    public var winkR: Double = 0
    /// 0 ... 1: shining eyes, their catchlights bigger and a third pin of light: hope, never a tear.
    public var shine: Double = 0
    /// Points up; tilts in radians, + raises the inner end.
    public var browLiftL: Double = 0
    public var browLiftR: Double = 0
    public var browTiltL: Double = 0
    public var browTiltR: Double = 0
    /// 0 ... 1 (1 is a bite half the body wide); `mouthWide` multiplies the width.
    public var mouthOpen: Double = 0
    public var mouthWide: Double = 1
    /// -1 frown ... 1 grin.
    public var smile: Double = 0.4
    /// 0 ... 1 a closed, working mouth, rippling with `chewPhase`.
    public var chew: Double = 0
    public var chewPhase: Double = 0
    /// 0 ... 1 a lick at the corner of the mouth.
    public var tongue: Double = 0
    public var blush: Double = 0.4

    // MARK: Limbs

    /// Radians away from the arm's rest angle, + raised; the feet's lift in points.
    public var armL: Double = 0
    public var armR: Double = 0
    public var footL: Double = 0
    public var footR: Double = 0
    /// 0 ... 1 each: a little thumb standing up off the tip of that arm, a thumbs-up. Only while the
    /// arm is up giving one.
    public var thumbL: Double = 0
    public var thumbR: Double = 0

    // MARK: Light: the hunger meter

    /// 0 empty ... 1 full ... up to 1.12 overfull (below a hunger of 0).
    public var fullness: Double = 0.75
    /// The light's surface: its tilt (radians, world space) and a ripple on it.
    public var slosh: Double = 0
    public var wave: Double = 0
    public var wavePhase: Double = 0
    /// Emissive multiplier: the mood's and behaviour's glow (eager 1.2, asleep 0.6, hibernating 0.3).
    public var glow: Double = 1
    /// The satisfied flare as a bite lands in the belly.
    public var flash: Double = 0
    /// 0 ... 1: how much of the food source's colour the swallowed light carries on its way down. 0 when
    /// the pet is stuffed, where a green or red glow at the mouth of a full creature would read as nausea.
    public var lumpTint: Double = 1

    public init() {}
}

/// A bit of light around the pet, already placed for the frame.
public struct PetParticle: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A crumb of light; with a `streak` it trails along its motion.
        case crumb
        /// A four-point star.
        case sparkle
        /// A "z", drawn as strokes, not text.
        case zzz
        /// The soft pulse of light where a bite lands.
        case ring
        /// The hungry tummy's rumble line.
        case rumble
        /// A hiccup's bubble.
        case bubble
        /// A dust mote drifting by, which the eyes may follow.
        case mote
        /// A contented sigh's puff of breath: a soft little cloud.
        case puff
    }

    /// Which colour of the palette it takes; `dot` is the food source's status dot (nil: grey).
    public enum Tint: Sendable, Equatable {
        case crumbLight, crumbWarm, sparkle, zzz, ring, rumble, bubble, burst
        case dot(Severity?)
    }

    public var kind: Kind
    public var position: CGPoint
    public var size: Double
    public var opacity: Double
    public var angle: Double = 0
    /// Where it was a moment ago, relative to `position`: a crumb's streak.
    public var streak: CGVector = .zero
    public var tint: Tint
}

/// The food in flight: a bead of light popped out of the number, stretched by its speed, with a short
/// streak behind it.
public struct PetBead: Sendable, Equatable {
    public var position: CGPoint
    public var radius: Double
    /// Along the direction of travel, area kept.
    public var stretch: Double
    public var angle: Double
    public var opacity: Double
    /// Where it was over the last few hundredths of a second, newest first.
    public var trail: [CGPoint]
    /// The source readout's dot colour; nil is grey.
    public var dot: Severity?
}

/// A glint on the ripe digit: a four-point twinkle of added light.
public struct PetGlint: Sendable, Equatable {
    public var position: CGPoint
    public var size: Double
    public var opacity: Double
    public var angle: Double
}

/// Below, hibernating: a 1 pt line of glow along the notch's bottom edge, above where the pet went.
public struct PetDoorLight: Sendable, Equatable {
    public var minX: Double
    public var maxX: Double
    public var y: Double
    public var opacity: Double
}
