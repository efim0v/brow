// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import GroveAppKit
import GroveCore
import SwiftUI

/// What the shell's chrome does when it is clicked: the controller's.
@MainActor
struct NotchShellActions {
    var select: (NotchTab) -> Void = { _ in }
    var togglePin: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The open panel, installed ONCE in `NotchPanelModel.panel` and never rebuilt on a publish:
/// the band at the top (the strip's own readouts, on every section but Limits), the switch
/// row (while there are sections to switch between), the section's content and the footer.
/// One width and one height for every section, the outline's: switching sections or
/// pushing a screen never moves it.
struct NotchShellView: View {
    @ObservedObject var model: NotchPanelModel
    @ObservedObject var sections: NotchSections
    @ObservedObject var badges: NotchBadges
    /// The strip's readouts drawn in the band.
    @ObservedObject var store: LimitsStore
    let actions: NotchShellActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: NotchShellLayout {
        NotchShellLayout(frames: model.frames, showsSwitch: sections.showsSwitch, showEars: model.showEars)
    }

    /// The section in front: the model's, while it is registered; Limits otherwise.
    private var tab: NotchTab { sections.section(model.tab) == nil ? .limits : model.tab }

    var body: some View {
        let layout = layout
        let frames = model.frames
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: layout.showsSwitch ? layout.switchTop : layout.contentTop)
                if layout.showsSwitch {
                    NotchTabSwitch(tabs: sections.tabs, selected: tab, badges: badges, showsKeys: model.showsKeys,
                                   onSelect: actions.select) {
                        sections.section(tab)?.switchAccessory()
                    }
                    .frame(width: layout.contentWidth, height: NotchShellLayout.switchHeight)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: NotchSwitchFrame.self, value: geo.frame(in: .named(Self.space)))
                    })
                    Color.clear.frame(height: NotchShellLayout.contentGap)
                }
                content
                    .frame(width: layout.contentWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                Color.clear.frame(height: NotchShellLayout.contentBottomGap)
                if let section = sections.section(tab) {
                    NotchFooter(status: section.footerStatus(), accessory: section.footerAccessory(),
                                refresh: section.refreshButton(), pinned: model.pinned, showsKeys: model.showsKeys,
                                onPin: actions.togglePin, onSettings: actions.openSettings, onQuit: actions.quit)
                        .frame(width: layout.contentWidth)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: NotchFooterFrame.self, value: geo.frame(in: .named(Self.space)))
                        })
                }
            }
            .padding(.leading, layout.contentInsetX)
            .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .topLeading)
            if tab != .limits, model.showEars {
                band(layout)
            }
        }
        .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .foregroundStyle(.white)
        .environment(\.groveAccent, NotchTheme.cream)
        // The shell stays in the tree while the panel is closed: what moves on its own in a
        // section stands still until it opens again.
        .environment(\.groveIsShowing, model.expanded)
        .tint(NotchTheme.cream)
    }

    /// The shell's own coordinate space: the window's, origin top-left.
    static let space = "NotchShell"

    /// The section's content, crossfading with a 6 pt slide when the switch moves (a fade
    /// only under Reduce Motion).
    @ViewBuilder
    private var content: some View {
        let tab = tab
        ZStack(alignment: .top) {
            if let section = sections.section(tab) {
                section.content(layout: layout)
                    .id(tab)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(x: 6)),
                                              removal: .opacity.combined(with: .offset(x: -6))))
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab)
    }

    /// The strip's own readouts, at the strip's own place: the panel opened on another section
    /// keeps the top of the notch as it was, the pet on its ledge beside the camera.
    private func band(_ layout: NotchShellLayout) -> some View {
        let strip = PetLayout.window(model.frames.collapsed, in: model.frames)
        return EarsView(aggregate: store.aggregate, frames: model.frames, drawsBackground: false)
            .frame(width: strip.width, height: strip.height)
            .offset(x: strip.minX, y: strip.minY)
            .allowsHitTesting(false)
    }
}

/// Where the footer is, in the shell's space: the bottom row must always be inside the outline.
struct NotchFooterFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// Where the switch row is, in the shell's space: its trailing buttons stay inside the content's
/// inset, as the footer's do.
struct NotchSwitchFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

// MARK: - The switch

/// The section switch: a capsule track, one segment per section with a cream thumb under the
/// selected one, and the section's own actions on the trailing side. Holding ⌘ shows each
/// segment's shortcut.
struct NotchTabSwitch<Accessory: View>: View {
    let tabs: [NotchTab]
    let selected: NotchTab
    @ObservedObject var badges: NotchBadges
    let showsKeys: Bool
    let onSelect: (NotchTab) -> Void
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var contrast: ColorSchemeContrast { renderContrast ?? systemContrast }

    private var increased: Bool { contrast == .increased }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { tab in segment(tab) }
            }
            .padding(2)
            .background(Capsule().fill(NotchTheme.track(increased)))
            // The sections' names are never cut: what sits beside them (the search field)
            // gives way instead.
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
            Spacer(minLength: 4)
            // Offered the room first, so a field opens to its full width before the gap takes any.
            accessory()
                .layoutPriority(1)
        }
    }

    private func segment(_ tab: NotchTab) -> some View {
        let on = tab == selected
        let hint = "\(tab.title) (⌘\(tab.shortcut))"
        return Button { onSelect(tab) } label: {
            HStack(spacing: 5) {
                Text(tab.title).font(.system(size: 12, weight: on ? .semibold : .medium))
                badge(tab)
                if showsKeys { NotchKeycap(text: "⌘\(tab.shortcut)") }
            }
            .foregroundStyle(on ? Color.white : Color.white.opacity(increased ? 0.85 : 0.62))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background {
                if on {
                    Capsule().fill(NotchTheme.cream.opacity(increased ? 0.30 : 0.17))
                        .overlay(Capsule().strokeBorder(NotchTheme.cream.opacity(increased ? 0.5 : 0.12), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(accessibilityLabel(tab))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder
    private func badge(_ tab: NotchTab) -> some View {
        switch tab {
        case .projects where badges.projectsNeedYou > 0:
            Text("\(badges.projectsNeedYou)")
                .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(NotchTheme.ink)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(NotchTheme.needsYou))
        case .agents where badges.agentsActive:
            Circle().fill(NotchTheme.cream).frame(width: 5, height: 5)
                .shadow(color: NotchTheme.cream.opacity(0.8), radius: 3)
        default:
            EmptyView()
        }
    }

    private func accessibilityLabel(_ tab: NotchTab) -> String {
        switch tab {
        case .projects where badges.projectsNeedYou > 0:
            return "\(tab.title), \(badges.projectsNeedYou) need you"
        case .agents where badges.agentsActive:
            return "\(tab.title), talking now"
        default:
            return tab.title
        }
    }
}

// MARK: - The footer

/// The bottom row, on every section and never part of the scroll: one status line on the
/// left, then the section's own button (Limits' share), the pin, ⟳ and the ⚙ menu (the
/// version, Settings, Quit). Each button is a 24 × 24 pt hit area around a 20 pt glyph.
struct NotchFooter: View {
    let status: AnyView
    let accessory: AnyView
    let refresh: AnyView
    let pinned: Bool
    let showsKeys: Bool
    let onPin: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var contrast: ColorSchemeContrast { renderContrast ?? systemContrast }
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// Between two buttons.
    static let spacing: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NotchTheme.hairline(contrast == .increased)).frame(height: 1)
            HStack(spacing: Self.spacing) {
                status
                Spacer(minLength: 8)
                accessory
                Button(action: onPin) {
                    NotchIconLabel(symbol: pinned ? "pin.fill" : "pin",
                                   color: pinned ? NotchTheme.cream : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(pinned ? "Pinned: stays open until Esc or a click outside" : "Keep the panel open")
                .accessibilityLabel(pinned ? "Unpin the panel" : "Keep the panel open")
                if showsKeys { NotchKeycap(text: "⌘R") }
                refresh
                if showsKeys { NotchKeycap(text: "⌘,") }
                gear
            }
            .frame(height: NotchShellLayout.footerRow)
            Color.clear.frame(height: NotchShellLayout.footerBottom)
        }
    }

    /// ⚙: "Brow 0.4.x", Settings…, Quit Brow. The only Quit there is besides ⌘Q.
    @ViewBuilder
    private var gear: some View {
        if isSnapshotRender {
            NotchIconLabel(symbol: "gearshape")
        } else {
            Menu {
                ForEach(NotchGearMenu.items) { item in
                    switch item.kind {
                    case .version:
                        Button(item.title) {}.disabled(true)
                    case .settings:
                        Button(item.title, action: onSettings).keyboardShortcut(",", modifiers: .command)
                    case .separator:
                        Divider()
                    case .quit:
                        Button(item.title, action: onQuit).keyboardShortcut("q", modifiers: .command)
                    }
                }
            } label: {
                NotchIconLabel(symbol: "gearshape")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and Quit")
            .accessibilityLabel("Settings and Quit")
        }
    }
}

/// The ⚙ menu's items, as data: the live menu and the offscreen render of it draw the same.
enum NotchGearMenu {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case version, settings, separator, quit }
        let id: Int
        let kind: Kind
        let title: String
        let shortcut: String?
    }

    static var items: [Item] {
        [Item(id: 0, kind: .version, title: "Brow \(BrowVersion.current)", shortcut: nil),
         Item(id: 1, kind: .settings, title: "Settings…", shortcut: "⌘,"),
         Item(id: 2, kind: .separator, title: "", shortcut: nil),
         Item(id: 3, kind: .quit, title: "Quit Brow", shortcut: "⌘Q")]
    }
}
