// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

// What the rig poses the pet in, besides the timeline: where it may be (zones), where the pointer has
// been, when the panel opened and closed (dock), and the display options. Every position is in window
// coordinates: points from the top-left corner of `NotchFrames.expanded`, y down. That is the space of
// `NotchRootView`, where the pet's layer lives, and the one `NotchPanelController.hostPoint(fromScreen:)`
// converts the pointer into. The window never moves, so the strip and the panel share it. A screen x is
// a window x plus `frames.expanded.minX`; on the pill, an x measured from the pill's left edge is a
// window x minus that edge.

/// Which of the pet's places a zone is.
public enum PetZoneKind: String, Sendable, Hashable, CaseIterable {
    /// In the left wing, between the 5-hour readout and the notch: the default.
    case beside
    /// In the 22 pt strip under the notch, left of the readouts.
    case below
    /// The 180 × 24 pt pill of a display without a notch.
    case pill
    /// The panel header's stage, at scale 2.
    case panel
}

/// The left readout's width class. A strip zone is fixed per class, and with tabular digits every
/// reading of a class is one width.
public enum PetReadoutWidth: Sendable, Hashable, CaseIterable {
    /// `—`: no reading yet.
    case dash
    /// `0%` to `9%`.
    case oneDigit
    /// `10%` to `99%`.
    case twoDigits
    /// `100%`: on screen only for the meal that fills the window and while asleep or drowsy.
    case threeDigits
}

/// Where the den is, seen from a zone.
public enum PetDen: Sendable, Equatable {
    /// Beside: the notch starts at `edgeX`, to the zone's right, and the pet goes in sideways.
    case side(edgeX: CGFloat)
    /// Below: the notch is above the strip, and the pet hops up into it, leaving light under the door.
    case overhead(CGRect)
    /// The pill and the panel have none: the pet curls up where it is.
    case none
}

/// One place the pet can be. `PetLayout` computes it from `NotchFrames` and the readouts; the controller
/// recomputes it on every render.
public struct PetZone: Sendable, Equatable {
    public var kind: PetZoneKind
    /// What every pose's box stays inside, the readouts' 4 pt gap already taken off. Only den poses
    /// pass it, on the den's side.
    public var bounds: CGRect
    /// The feet's centre at rest.
    public var anchor: CGPoint
    /// 1.0 beside, 0.80 below, 0.82 on the pill, 2.0 in the panel.
    public var scale: CGFloat
    /// 1.20 beside, 1.10 below, 1.15 on the pill; the panel keeps the beside limit
    /// (`PetLayout.panelMaxStretch`).
    public var maxStretch: CGFloat
    public var den: PetDen
    /// Where food comes from: the left readout's text centre in the strip, the Overall line's "5h"
    /// figure in the panel. The bite goes toward it.
    public var foodSource: CGPoint
    /// The colour of that readout's status dot, for the crumbs and the rim's tint; nil is the grey of
    /// a stale reading or of none (`EarsView.color(for:)`).
    public var foodDot: Severity?
}

/// The zones the rig needs at one instant.
public struct PetZones: Sendable, Equatable {
    /// The collapsed strip's zone; nil when nothing is drawn collapsed (readouts hidden), and the pet
    /// appears only in the panel.
    public var strip: PetZone?
    public var panel: PetZone
    /// The camera: nothing is ever drawn inside it, in any dock state; nil without a notch.
    public var notch: CGRect?
}

/// Where the pointer was, and when.
public struct PetPointerSample: Sendable, Equatable {
    /// `PetTime.mono`.
    public var t: TimeInterval
    /// Window coordinates. Anywhere on the screen, so often outside the window.
    public var location: CGPoint
}

/// The pointer's recent path, from the panel controller's mouse monitors. The eyes follow it with
/// springs, so the rig needs a little history, not just the last point.
public struct PetPointerTrack: Sendable, Equatable {
    /// In time order. The controller keeps every sample of the last `history` seconds and the one
    /// sample before them.
    public var samples: [PetPointerSample] = []

    /// Enough for the slowest gaze spring (the head, ω 9, ζ 0.9) to forget where it started.
    public static let history: TimeInterval = 2
}

/// The panel opening or closing, or the strip changing shape.
public struct PetDockChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `setExpanded(true)`, at the instant the outline's open spring starts: hop, glide or
        /// crossfade from the strip to the header.
        case expand
        /// `setExpanded(false)`: back to the strip.
        case collapse
        /// The Ears picker, a display change or the readouts turned on or off: fade out at `from`,
        /// fade in at the new zones.
        case relayout(from: PetZones)
    }

    /// `PetTime.mono`.
    public var t: TimeInterval
    public var kind: Kind
}

/// When the pet moved between the strip and the panel. Expanded at an instant means the last
/// `.expand` or `.collapse` at or before it was an `.expand`.
public struct PetDockTrack: Sendable, Equatable {
    /// In time order. The controller keeps the last `.expand` or `.collapse` however old, and every
    /// change of the last `history` seconds.
    public var changes: [PetDockChange] = []

    /// Longer than any hop, glide or fade, with room for the landing spring to settle.
    public static let history: TimeInterval = 2
}

/// The display options the pet follows, from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
/// and its two neighbours.
public struct PetMotion: Sendable, Hashable {
    /// No squash or stretch beyond ±2 %, no hop, glide or lunge (crossfades instead), idle is
    /// breathing at half amplitude and blinks, particles fade in place.
    public var reduceMotion = false
    /// No glow; the rim light stays.
    public var reduceTransparency = false
    /// The rim at 60 % and a 0.5 pt outline at 40 %.
    public var increaseContrast = false
}
