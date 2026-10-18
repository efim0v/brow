// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// An sRGB colour as three numbers, because the canvas blends them: the pet's body mixes its light
/// with its drained shell by how hungry it is.
public struct PetRGB: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xFFC65C` is (255, 198, 92).
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public func color(opacity: Double = 1) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: min(max(opacity, 0), 1))
    }
}

/// The colours the pet is drawn in, one case per look, so a look can change without the rig changing.
/// Each is a whole set: the ink and the shade are matched to the light's hue, because an orange ink's
/// soft edges on a gold body read as orange.
public enum PetPalette: String, Sendable, Hashable, CaseIterable {
    /// The first look: honey-orange light in an amber shell, terracotta-brown when hungry. Kept to
    /// compare the others with.
    case original
    /// Gold light; hungry, a muted gold shell, so hunger reads as a lamp turned down rather than as
    /// brown; rose cheeks. Its glow is clearly not Brow's orange warning dot, which the original's
    /// nearly is.
    case paleGold
    /// A warm white with little saturation; hungry, a faded ivory. The least warm of the looks.
    case cream
    /// Yellow-green light; hungry, a pale sage-cream, the lantern out.
    case firefly

    public var colors: Colors {
        switch self {
        case .original: return .original
        case .paleGold: return .paleGold
        case .cream: return .cream
        case .firefly: return .firefly
        }
    }

    /// Every colour the canvas uses, by what it is for.
    public struct Colors: Sendable, Hashable {
        /// The light inside, from its hot core out to its edge: the pet fed.
        public var lightCore: PetRGB
        public var lightMid: PetRGB
        public var lightEdge: PetRGB
        /// The shell where the light has drained: the pet hungry.
        public var dimCore: PetRGB
        public var dimEdge: PetRGB
        /// The darker edge of a self-lit jelly.
        public var shade: PetRGB
        public var rim: PetRGB
        /// The glow around the body and the light on the floor under it. Also the panel meter's fill:
        /// the pet's accent, never a severity colour, so hunger never reads as a limit.
        public var glow: PetRGB
        public var limb: PetRGB
        public var limbDark: PetRGB
        /// The eyes, the brows and the line of the mouth.
        public var ink: PetRGB
        public var mouth: PetRGB
        public var tongue: PetRGB
        public var blush: PetRGB
        /// The satisfied flare as a bite lands in the belly, and the pulse of light it sends out.
        public var flare: PetRGB
        public var ring: PetRGB
        /// Bits of light: crumbs in two tones, sparkles, Zzz, the hungry tummy's rumble lines, the hiccup's
        /// bubble and its pop.
        public var crumbLight: PetRGB
        public var crumbWarm: PetRGB
        public var sparkle: PetRGB
        public var zzz: PetRGB
        public var rumble: PetRGB
        public var bubble: PetRGB
        public var burst: PetRGB
        /// Pale light is more luminous than orange at the same opacity, so each look scales its halo,
        /// floor light and trails by this, to throw the same light onto the digits as the original
        /// (`PetTuning.Light.glowAtReadout`).
        public var glowGain: Double
    }
}

extension PetPalette.Colors {
    public static let original = PetPalette.Colors(
        lightCore: PetRGB(hex: 0xFFEDB0), lightMid: PetRGB(hex: 0xFFC65C), lightEdge: PetRGB(hex: 0xF0922E),
        dimCore: PetRGB(hex: 0xCB7430), dimEdge: PetRGB(hex: 0x8E4219), shade: PetRGB(hex: 0x5C2208),
        rim: PetRGB(hex: 0xFFF4D6), glow: PetRGB(hex: 0xFFA83A), limb: PetRGB(hex: 0xE58A2C),
        limbDark: PetRGB(hex: 0xB0581C), ink: PetRGB(hex: 0x2A1206), mouth: PetRGB(hex: 0x5A160C),
        tongue: PetRGB(hex: 0xFF7A6A), blush: PetRGB(hex: 0xFF5F57), flare: PetRGB(hex: 0xFFEDB0),
        ring: PetRGB(hex: 0xFFC968), crumbLight: PetRGB(hex: 0xFFF6DF), crumbWarm: PetRGB(hex: 0xFFD98E),
        sparkle: PetRGB(hex: 0xFFF3D0), zzz: PetRGB(hex: 0xFFE6BC), rumble: PetRGB(hex: 0xFFB45A),
        bubble: PetRGB(hex: 0xFFE2A8), burst: PetRGB(hex: 0xFFE7B5), glowGain: 1.0)

    public static let paleGold = PetPalette.Colors(
        lightCore: PetRGB(hex: 0xFFF7D1), lightMid: PetRGB(hex: 0xFFEA8A), lightEdge: PetRGB(hex: 0xF2CF52),
        dimCore: PetRGB(hex: 0xDBBF58), dimEdge: PetRGB(hex: 0xA38934), shade: PetRGB(hex: 0x4D3D11),
        rim: PetRGB(hex: 0xFFF9E0), glow: PetRGB(hex: 0xFFDD61), limb: PetRGB(hex: 0xF0CC54),
        limbDark: PetRGB(hex: 0xB89637), ink: PetRGB(hex: 0x2A2410), mouth: PetRGB(hex: 0x4E1A24),
        tongue: PetRGB(hex: 0xFF8C9C), blush: PetRGB(hex: 0xFF7C92), flare: PetRGB(hex: 0xFFF7D1),
        ring: PetRGB(hex: 0xFFE27A), crumbLight: PetRGB(hex: 0xFFFBEA), crumbWarm: PetRGB(hex: 0xFFE68A),
        sparkle: PetRGB(hex: 0xFFFAE2), zzz: PetRGB(hex: 0xFFF0C0), rumble: PetRGB(hex: 0xF2D46A),
        bubble: PetRGB(hex: 0xFFF0B8), burst: PetRGB(hex: 0xFFF4CC), glowGain: 0.80)

    /// Cream, with a drained shell (`0xDCD0B6 → 0x9C907A`) deep enough for hunger, the meter the strip
    /// shows, to read at real size: a paler one (`0xECE2CA → 0xB5AA90`) sat so close to the light that
    /// it barely did. Still an ivory, not a taupe, which reads as grey stone.
    public static let cream = PetPalette.Colors(
        lightCore: PetRGB(hex: 0xFFFFF6), lightMid: PetRGB(hex: 0xFFF4D8), lightEdge: PetRGB(hex: 0xF5E2BC),
        dimCore: PetRGB(hex: 0xDCD0B6), dimEdge: PetRGB(hex: 0x9C907A), shade: PetRGB(hex: 0x4A4334),
        rim: PetRGB(hex: 0xFFFFFF), glow: PetRGB(hex: 0xFFEDC8), limb: PetRGB(hex: 0xF6E8C8),
        limbDark: PetRGB(hex: 0xCDBC96), ink: PetRGB(hex: 0x2A2218), mouth: PetRGB(hex: 0x4C1A26),
        tongue: PetRGB(hex: 0xFF8C9E), blush: PetRGB(hex: 0xFF7F98), flare: PetRGB(hex: 0xFFFFF6),
        ring: PetRGB(hex: 0xFFF3D6), crumbLight: PetRGB(hex: 0xFFFFFF), crumbWarm: PetRGB(hex: 0xFFF1D0),
        sparkle: PetRGB(hex: 0xFFFFFF), zzz: PetRGB(hex: 0xFFF6E2), rumble: PetRGB(hex: 0xEFDDB4),
        bubble: PetRGB(hex: 0xFFF6E0), burst: PetRGB(hex: 0xFFFFFF), glowGain: 0.75)

    public static let firefly = PetPalette.Colors(
        lightCore: PetRGB(hex: 0xFCFFE6), lightMid: PetRGB(hex: 0xEEF7A2), lightEdge: PetRGB(hex: 0xD2E36C),
        dimCore: PetRGB(hex: 0xDCE2B4), dimEdge: PetRGB(hex: 0xA0AA78), shade: PetRGB(hex: 0x333A1E),
        rim: PetRGB(hex: 0xFBFFE8), glow: PetRGB(hex: 0xDCF07C), limb: PetRGB(hex: 0xD8E87E),
        limbDark: PetRGB(hex: 0xA2B256), ink: PetRGB(hex: 0x1E2410), mouth: PetRGB(hex: 0x3E1A22),
        tongue: PetRGB(hex: 0xFF8C9E), blush: PetRGB(hex: 0xFF8CA0), flare: PetRGB(hex: 0xFCFFE6),
        ring: PetRGB(hex: 0xE6F59E), crumbLight: PetRGB(hex: 0xFBFFEC), crumbWarm: PetRGB(hex: 0xE8F4A0),
        sparkle: PetRGB(hex: 0xFCFFEA), zzz: PetRGB(hex: 0xF2FAD0), rumble: PetRGB(hex: 0xD8EC8A),
        bubble: PetRGB(hex: 0xF0F8C8), burst: PetRGB(hex: 0xF8FFE0), glowGain: 0.78)
}
