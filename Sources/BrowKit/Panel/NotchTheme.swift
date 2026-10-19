// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// The open panel's colours and type, in one place.
///
/// Cream, Glim's own light, is the panel's only accent: the switch's thumb, the focus ring,
/// the primary buttons (cream with ink on it), links and the pin while pinned. Yellow
/// means one thing only: a session needs the user. Green, orange and red stay the limits'
/// severity colours. Everything else is white at three strengths on the black.
public enum NotchTheme {
    /// #FFEDC8, `PetPalette.cream`'s glow.
    public static let cream = PetPalette.Colors.cream.glow.color()
    /// #2A2218, drawn on cream.
    public static let ink = PetPalette.Colors.cream.ink.color()
    /// #FFD05C: a session needs the user.
    public static let needsYou = Color(.sRGB, red: 0xFF / 255, green: 0xD0 / 255, blue: 0x5C / 255)

    public static func primary(_ contrast: Bool = false) -> Color { Color.white.opacity(0.94) }
    public static func secondary(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.80 : 0.58) }
    public static func tertiary(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.60 : 0.36) }
    public static func hairline(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.25 : 0.09) }
    public static func card(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.09 : 0.055) }
    public static func cardEdge(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.25 : 0.07) }
    /// The switch's track.
    public static func track(_ contrast: Bool = false) -> Color { Color.white.opacity(contrast ? 0.14 : 0.075) }

    /// An account's colour, the calendar's: one dot before its name wherever it is named.
    public static func account(_ colorIndex: Int) -> Color { CalendarView.color(colorIndex) }
}

/// A 24 × 24 pt hit area around a 20 pt glyph: the panel's one size for icon buttons.
struct NotchIconLabel: View {
    let symbol: String
    var color: Color = Color.white.opacity(0.78)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

/// A keycap: "⌘1", shown on the switch and the footer while ⌘ is held.
struct NotchKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(NotchTheme.secondary())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.10)))
            .accessibilityHidden(true)
    }
}
