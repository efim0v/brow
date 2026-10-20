// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// The one window: the switch between Limits and the sections Workspaces registers, hover and
/// pin, the keys of a pinned panel, the footer's menu and the pet's dock. The panel is never
/// ordered in (`drivesWindow` off) and the pointer is the test's own, so nothing is drawn on
/// the screen and nothing the user does with the mouse reaches the test.
@MainActor
final class NotchShellTests: XCTestCase {
    private let now = MadeUpLimits.morning()
    /// Inside the strip beside the 14" notch, and well away from the open panel.
    private let onStrip = NSPoint(x: 756, y: 966)
    private let away = NSPoint(x: 100, y: 100)

    private func store(count: Int = 2, settings: (inout BrowSettings) -> Void = { _ in }) throws -> LimitsStore {
        try MadeUpLimits.store(count: count, now: now, appDir: Fixture.tempDir("notch-shell").path, settings: settings)
    }

    private func controller(_ store: LimitsStore, pet: PetController? = nil, sections: [NotchTab] = [],
                            shown: Bool = true) -> (NotchPanelController, [NotchTab: StubSection]) {
        let controller = NotchPanelController(store: store, clock: PanelClock(now: { [now] in now }), pet: pet,
                                              onExpandedChange: { _ in }, onSettings: {})
        controller.drivesWindow = false
        controller.screen = { MadeUpLimits.screen14 }
        controller.now = { [now] in now }
        var stubs: [NotchTab: StubSection] = [:]
        for tab in sections {
            let stub = StubSection()
            stubs[tab] = stub
            controller.sections.register(tab, stub)
        }
        controller.render()
        if shown { controller.show() }
        addTeardownBlock { @MainActor in controller.hide() }
        return (controller, stubs)
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The switch row

    /// With Workspaces off there is one section and no switch: the panel is today's Limits panel.
    /// With sections, the switch row sits 8 pt under the band — the notch, plus the strip under it
    /// for the readouts below — on every section alike.
    func testTheSwitchRowIsThereOnlyWithSectionsAndAtOnePlace() throws {
        let store = try store()
        let (alone, _) = controller(store)
        XCTAssertFalse(alone.sections.showsSwitch)
        XCTAssertEqual(alone.sections.tabs, [.limits])
        let plain = NotchShellLayout(frames: alone.model.frames, showsSwitch: false, showEars: true)
        XCTAssertEqual(plain.contentTop, alone.model.frames.contentTopInset, "where today's panel starts")

        let (withProjects, _) = controller(store, sections: [.projects])
        XCTAssertTrue(withProjects.sections.showsSwitch)
        XCTAssertEqual(withProjects.sections.tabs, [.limits, .projects])
        let beside = NotchShellLayout(frames: withProjects.model.frames, showsSwitch: true, showEars: true)
        XCTAssertEqual(beside.switchTop, 40)
        XCTAssertEqual(beside.contentTop, 40 + 28 + 10)
        XCTAssertEqual(beside.contentWidth, 432)
        let below = NotchShellLayout(frames: NotchGeometry.frames(for: MadeUpLimits.screen14, expandedHeight: 600,
                                                                  placement: .below),
                                     showsSwitch: true, showEars: true)
        XCTAssertEqual(below.switchTop, 62)
    }

    /// The switch row and the footer are the content's width, 14 pt inside the black on each
    /// side: a section's trailing buttons (search, +) never reach the outline's edge.
    func testTheSwitchRowAndTheFooterStayInsideTheContentInset() throws {
        let (panel, _) = controller(try store(), sections: [.projects])
        panel.openPinned(on: .projects)
        final class Frames: @unchecked Sendable { var row: CGRect?; var footer: CGRect? }
        let frames = Frames()
        let view = NotchRootView(model: panel.model)
            .onPreferenceChange(NotchSwitchFrame.self) { frames.row = $0 }
            .onPreferenceChange(NotchFooterFrame.self) { frames.footer = $0 }
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
        let layout = NotchShellLayout(frames: panel.model.frames, showsSwitch: true, showEars: true)
        for frame in [try XCTUnwrap(frames.row), try XCTUnwrap(frames.footer)] {
            XCTAssertEqual(frame.minX, layout.contentInsetX, accuracy: 0.5)
            XCTAssertEqual(frame.width, layout.contentWidth, accuracy: 0.5)
        }
        XCTAssertEqual(try XCTUnwrap(frames.row).minY, layout.switchTop, accuracy: 0.5)
    }

    /// The shell stays in the tree while the panel is closed, invisible: its sections are told
    /// so (`groveIsShowing`), and what moves on its own in them stands still until it opens.
    func testASectionIsToldWhenThePanelIsClosed() throws {
        let (panel, _) = controller(try store())
        let probe = ShowingProbe()
        panel.sections.register(.projects, probe)
        panel.render()
        func drawn() -> Bool? {
            probe.seen = nil
            let renderer = ImageRenderer(content: NotchRootView(model: panel.model).environment(\.colorScheme, .dark))
            renderer.scale = 1
            _ = renderer.cgImage
            return probe.seen
        }
        panel.openPinned(on: .projects)
        XCTAssertEqual(drawn(), true)
        panel.dismiss(.escape)
        XCTAssertFalse(panel.model.expanded)
        XCTAssertEqual(drawn(), false, "still in the tree, told it is not on the screen")
    }

    /// Once the closing spring has settled the shell leaves the tree, so a closed panel evaluates
    /// nothing of its sections, whatever they read publishes. A section holding something a
    /// rebuild would lose (a form half filled, a creation's log) keeps it in.
    func testAClosedPanelLetsTheShellGoUnlessASectionHoldsSomething() async throws {
        let (panel, stubs) = controller(try store(), sections: [.projects])
        XCTAssertFalse(panel.model.shellLive, "never opened")
        panel.openPinned(on: .projects)
        XCTAssertTrue(panel.model.shellLive)
        panel.dismiss(.escape)
        XCTAssertTrue(panel.model.shellLive, "through the closing spring")
        await settle(NotchPanelController.closeSettle + 0.3)
        XCTAssertFalse(panel.model.shellLive, "settled")
        stubs[.projects]?.keepsAlive = true
        panel.openPinned(on: .projects)
        XCTAssertTrue(panel.model.shellLive)
        panel.dismiss(.escape)
        await settle(NotchPanelController.closeSettle + 0.3)
        XCTAssertTrue(panel.model.shellLive, "a form half filled stays")
    }

    /// The session card under the pointer is the controller's to say, from its own mouse
    /// monitors: the panel is never the active app's, and SwiftUI's hover does not fire there.
    func testTheCardUnderThePointerComesFromThePanelsOwnMonitors() async throws {
        let (panel, _) = controller(try store(), sections: [.projects])
        panel.openPinned(on: .projects)
        let hover = panel.model.cardHover
        hover.setFrames(["s-one": CGRect(x: 20, y: 200, width: 432, height: 60),
                         "s-two": CGRect(x: 20, y: 268, width: 432, height: 60)])
        let window = panel.model.frames.expanded
        func screen(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: window.minX + x, y: window.maxY - y) }
        panel.pointerMoved(to: screen(100, 230))
        XCTAssertEqual(hover.session, "s-one")
        panel.pointerMoved(to: screen(100, 300))
        XCTAssertEqual(hover.session, "s-two")
        panel.pointerMoved(to: screen(100, 264))
        XCTAssertNil(hover.session, "between two cards")
        panel.pointerMoved(to: screen(100, 300))
        // The cards move under a pointer that stays (a scroll): looked for again.
        hover.setFrames(["s-one": CGRect(x: 20, y: 280, width: 432, height: 60)])
        await settle(0.05)
        XCTAssertEqual(hover.session, "s-one")
        panel.dismiss(.escape)
        XCTAssertNil(hover.session, "a closed panel has nothing under the pointer")
    }

    /// The card under the pointer is told to the section's content only when it changes.
    func testTheCardUnderThePointerIsPublishedOnlyWhenItChanges() {
        let hover = NotchCardHover()
        hover.setFrames(["s-one": CGRect(x: 0, y: 0, width: 100, height: 50)])
        var published = 0
        let watch = hover.objectWillChange.sink { published += 1 }
        hover.update(pointer: CGPoint(x: 10, y: 10))
        hover.update(pointer: CGPoint(x: 20, y: 12))
        hover.update(pointer: CGPoint(x: 30, y: 14))
        XCTAssertEqual(hover.session, "s-one")
        XCTAssertEqual(published, 1)
        hover.update(pointer: nil)
        XCTAssertNil(hover.session)
        XCTAssertEqual(published, 2)
        watch.cancel()
    }

    // MARK: - Hover and pin

    /// Hovered, the panel opens with the pointer and closes half a second after it leaves.
    func testHoverOpensThePanelAndLeavingClosesIt() async throws {
        let (panel, _) = controller(try store())
        panel.pointerMoved(to: onStrip)
        XCTAssertTrue(panel.model.expanded)
        XCTAssertFalse(panel.model.pinned, "a hover never pins")
        XCTAssertFalse(panel.canBecomeKey, "nor takes the keyboard")
        panel.pointerMoved(to: away)
        XCTAssertTrue(panel.model.expanded, "not at once")
        await settle(0.8)
        XCTAssertFalse(panel.model.expanded)
    }

    /// Pinned, the panel takes the keyboard and stays when the pointer leaves; a click outside
    /// closes it, and it does not open again under a pointer that has not left.
    func testAPinnedPanelStaysUntilAClickOutsideAndThenWaitsForThePointerToLeave() async throws {
        let (panel, _) = controller(try store())
        panel.pointerMoved(to: onStrip)
        panel.pin()
        XCTAssertTrue(panel.model.pinned)
        XCTAssertTrue(panel.canBecomeKey)
        panel.pointerMoved(to: away)
        await settle(0.8)
        XCTAssertTrue(panel.model.expanded, "the pointer leaving does not close a pinned panel")

        panel.dismiss(.outsideClick)
        XCTAssertFalse(panel.model.expanded)
        XCTAssertFalse(panel.model.pinned)
        XCTAssertFalse(panel.canBecomeKey, "the keyboard goes back")
        panel.pointerMoved(to: onStrip)
        XCTAssertFalse(panel.model.expanded, "latched: the pointer has not left since")
        panel.pointerMoved(to: away)
        panel.pointerMoved(to: onStrip)
        XCTAssertTrue(panel.model.expanded, "once it has, hover works again")
    }

    /// The status item, Show Projects and a reopen open the panel pinned on their section.
    func testOpenPinnedOpensOnTheSectionAndPins() throws {
        let (panel, _) = controller(try store(), sections: [.projects])
        panel.openPinned(on: .projects)
        XCTAssertTrue(panel.isShowing(.projects))
        XCTAssertTrue(panel.model.pinned)
        XCTAssertEqual(panel.model.tab, .projects)
        panel.openPinned(on: .agents)
        XCTAssertEqual(panel.model.tab, .limits, "a section nobody registered opens Limits")
    }

    /// With "Show Brow in the notch" off there is no strip and no hover, and the panel still
    /// opens, pinned, from the menu bar, the Brow menu or a reopen.
    func testWithTheNotchOffThePanelStillOpensPinned() async throws {
        let (panel, _) = controller(try store(), sections: [.projects], shown: false)
        XCTAssertFalse(panel.isShown)
        panel.openPinned(on: .projects)
        XCTAssertTrue(panel.isShowing(.projects))
        XCTAssertTrue(panel.model.pinned)
        XCTAssertFalse(panel.model.showEars, "no strip to grow out of")
        panel.dismiss(.handOff)
        XCTAssertFalse(panel.model.expanded)
        await settle(NotchPanelController.closeSettle + 0.2)
        XCTAssertFalse(panel.isShown, "closed, it leaves no strip behind")
        panel.openPinned(on: .projects)
        XCTAssertFalse(panel.model.showEars, "and opens again without one")
    }

    /// With the notch off, the pin pressed again leaves a panel that closes when the pointer
    /// leaves it — Esc and a click outside are a pinned panel's — and nothing hovers it open.
    func testWithTheNotchOffAnUnpinnedPanelClosesWhenThePointerLeaves() async throws {
        let (panel, _) = controller(try store(), sections: [.projects], shown: false)
        panel.openPinned(on: .projects)
        panel.unpin()
        let window = panel.model.frames.expanded
        panel.pointerMoved(to: NSPoint(x: window.midX, y: window.maxY - 200))
        await settle(0.8)
        XCTAssertTrue(panel.model.expanded, "the pointer is still on it")
        panel.pointerMoved(to: away)
        await settle(0.8)
        XCTAssertFalse(panel.model.expanded)
        panel.pointerMoved(to: away)
        panel.pointerMoved(to: onStrip)
        XCTAssertFalse(panel.model.expanded, "no strip to hover open")
    }

    // MARK: - Which section it opens on

    /// The section the panel closed on is the one a hover opens it on again, for 15 minutes.
    func testTheSectionItClosedOnIsRememberedForFifteenMinutes() throws {
        final class Clock { var date: Date; init(_ date: Date) { self.date = date } }
        let clock = Clock(now)
        let (panel, _) = controller(try store(), sections: [.projects])
        panel.now = { clock.date }
        XCTAssertEqual(panel.remembered, .limits, "nothing closed yet")
        panel.openPinned(on: .projects)
        panel.dismiss(.escape)
        XCTAssertEqual(panel.remembered, .projects)

        panel.pointerMoved(to: away)
        panel.pointerMoved(to: onStrip)
        XCTAssertEqual(panel.model.tab, .projects, "a hover opens it where it was")
        panel.dismiss(.escape)

        clock.date = clock.date.addingTimeInterval(14 * 60)
        XCTAssertEqual(panel.remembered, .projects)
        clock.date = clock.date.addingTimeInterval(2 * 60)
        XCTAssertEqual(panel.remembered, .limits, "after 15 minutes: Limits")

        clock.date = now
        panel.openPinned(on: .projects)
        panel.dismiss(.escape)
        panel.sections.unregister(.projects)
        XCTAssertEqual(panel.remembered, .limits, "a section that went away is not remembered")
    }

    // MARK: - Keys

    /// Esc goes back a screen while the section has one to go back to, then closes the panel.
    func testEscapeGoesBackThenCloses() throws {
        let (panel, stubs) = controller(try store(), sections: [.projects])
        let projects = try XCTUnwrap(stubs[.projects])
        panel.openPinned(on: .projects)
        projects.popsOnEscape = true
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .escape)))
        XCTAssertTrue(panel.model.expanded, "the section went back a screen")
        projects.popsOnEscape = false
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .escape)))
        XCTAssertFalse(panel.model.expanded, "at its root Esc closes")
        XCTAssertEqual(projects.escapes, [true, false])
    }

    /// ⌘1 ⌘2 ⌘3 pick a section that is there, ⌃Tab goes round, and ⌘R and the section's own
    /// keys go to the section in front.
    func testTheKeysOfAPinnedPanel() throws {
        let (panel, stubs) = controller(try store(), sections: [.projects, .agents])
        panel.openPinned(on: .limits)
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .tab(.projects))))
        XCTAssertEqual(panel.model.tab, .projects)
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .tab(.agents))))
        XCTAssertEqual(panel.model.tab, .agents)
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .cycle(backwards: false))))
        XCTAssertEqual(panel.model.tab, .limits, "round")
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .cycle(backwards: true))))
        XCTAssertEqual(panel.model.tab, .agents)

        XCTAssertTrue(panel.handle(NotchKeyPress(command: .tab(.projects))))
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .refresh)))
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .section(.down))))
        XCTAssertEqual(stubs[.projects]?.refreshes, 1)
        XCTAssertEqual(stubs[.projects]?.keys, [.down])
        XCTAssertEqual(stubs[.agents]?.refreshes, 0)

        panel.sections.unregister(.agents)
        XCTAssertTrue(panel.handle(NotchKeyPress(command: .tab(.agents))))
        XCTAssertEqual(panel.model.tab, .projects, "⌘3 without Agents does nothing")
    }

    /// The key codes as a pinned panel reads them. In a text field the keys that move or
    /// confirm in it are the field's.
    func testKeyPressesMapToCommands() {
        func press(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = [],
                   editing: Bool = false) -> NotchKeyPress.Command? {
            NotchKeyPress(keyCode: code, characters: chars, modifiers: flags, editingText: editing).command
        }
        XCTAssertEqual(press(53), .escape)
        XCTAssertEqual(press(18, "1", .command), .tab(.limits))
        XCTAssertEqual(press(19, "2", .command), .tab(.projects))
        XCTAssertEqual(press(20, "3", .command), .tab(.agents))
        XCTAssertEqual(press(48, "\t", .control), .cycle(backwards: false))
        XCTAssertEqual(press(48, "\t", [.control, .shift]), .cycle(backwards: true))
        XCTAssertEqual(press(15, "r", .command), .refresh)
        XCTAssertEqual(press(43, ",", .command), .settings)
        XCTAssertEqual(press(12, "q", .command), .quit)
        XCTAssertEqual(press(13, "w", .command), .close)
        XCTAssertEqual(press(3, "f", .command), .section(.find))
        XCTAssertEqual(press(36, "\r", .command), .section(.openWithOptions))
        XCTAssertEqual(press(36, "\r"), .section(.open))
        XCTAssertEqual(press(126), .section(.up))
        XCTAssertEqual(press(125), .section(.down))
        XCTAssertEqual(press(51), .section(.delete))
        XCTAssertNil(press(36, "\r", editing: true), "↩ in a field is the field's")
        XCTAssertNil(press(51, editing: true), "so is ⌫")
        XCTAssertNil(press(126, editing: true))
        XCTAssertEqual(press(53, editing: true), .escape, "Esc still closes the search")
        XCTAssertNil(press(0, "a"), "typing is not a command")
    }

    /// On a layout without Latin letters the shortcuts are read by the key's place, as the
    /// menus of macOS read them: ⌘F on a Russian keyboard types "а". A Latin layout keeps its
    /// own letters.
    func testShortcutsWorkOnALayoutWithoutLatinLetters() {
        func press(_ code: UInt16, _ chars: String) -> NotchKeyPress.Command? {
            NotchKeyPress(keyCode: code, characters: chars, modifiers: .command, editingText: false).command
        }
        XCTAssertEqual(press(3, "а"), .section(.find))
        XCTAssertEqual(press(15, "к"), .refresh)
        XCTAssertEqual(press(12, "й"), .quit)
        XCTAssertEqual(press(13, "ц"), .close)
        XCTAssertEqual(press(43, "б"), .settings)
        XCTAssertEqual(press(3, "φ"), .section(.find), "Greek")
        XCTAssertEqual(press(19, "2"), .tab(.projects))
        XCTAssertNil(press(3, "u"), "Dvorak's key there is U: its ⌘F is where it puts F")
        XCTAssertEqual(press(14, "f"), .section(.find))
        XCTAssertNil(press(0, "ф"), "a key the panel has no shortcut on")
    }

    /// A click in another of Brow's windows closes a pinned panel — but not one in a menu the
    /// panel opened, nor on Brow's menu-bar item, whose own click opens or closes the panel.
    func testWhichOfBrowsOtherWindowsAClickClosesThePanelFrom() {
        final class NSStatusBarWindowStandIn: NSWindow {}
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let menu = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        menu.level = .popUpMenu
        let item = NSStatusBarWindowStandIn(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertFalse(NotchPanelController.isMenuWindow(settings) || NotchPanelController.isStatusItemWindow(settings))
        XCTAssertTrue(NotchPanelController.isMenuWindow(menu))
        XCTAssertTrue(NotchPanelController.isStatusItemWindow(item))
        XCTAssertFalse(NotchPanelController.isStatusItemWindow(nil))
    }

    // MARK: - The footer

    /// ⚙: the version, Settings… ⌘, and Quit Brow ⌘Q — Grove's footer held the only Quit button.
    func testTheGearMenu() {
        let items = NotchGearMenu.items
        XCTAssertEqual(items.map(\.kind), [.version, .settings, .separator, .quit])
        XCTAssertEqual(items[0].title, "Brow \(BrowVersion.current)")
        XCTAssertEqual(items[1].title, "Settings…")
        XCTAssertEqual(items[1].shortcut, "⌘,")
        XCTAssertEqual(items[3].title, "Quit Brow")
        XCTAssertEqual(items[3].shortcut, "⌘Q")
    }

    /// ⟳ on Limits is the forced refresh with its one gate.
    func testRefreshOnLimitsIsTheGatedForcedRefresh() throws {
        let store = try store()
        var refreshes = 0
        let limits = LimitsSection(store: store, clock: PanelClock(now: { [now] in now }), hover: CalendarHoverTracker(),
                                   pet: nil, onRefresh: { refreshes += 1 })
        limits.refresh()
        XCTAssertEqual(refreshes, 1)
    }

    // MARK: - The pet

    private func pet(for store: LimitsStore) throws -> PetController {
        let dir = try Fixture.tempDir("notch-shell-pet")
        let petStore = PetStore(directory: dir.appendingPathComponent("pet").path)
        var save = PetSave(seed: 7, bornAt: now.addingTimeInterval(-86_400))
        save.introDone = true
        try petStore.save(save)
        let pet = PetController(store: store, petStore: petStore, senses: false,
                                defaults: UserDefaults(suiteName: "brow-notch-shell-\(UUID().uuidString)")!)
        pet.start()
        return pet
    }

    private func moves(_ pet: PetController) -> [PetDockChange.Kind] {
        pet.layer.dock.changes.map(\.kind).filter { $0 == .expand || $0 == .collapse }
    }

    /// Glim hops into the header only on Limits: opened on Projects it stays on its ledge, and
    /// switching hops it between the two with today's hop.
    func testThePetHopsIntoTheHeaderOnlyOnLimits() throws {
        let store = try store()
        let pet = try pet(for: store)
        let (panel, _) = controller(store, pet: pet, sections: [.projects])
        panel.openPinned(on: .projects)
        XCTAssertEqual(moves(pet), [], "opened on Projects: no hop")
        XCTAssertFalse(pet.expanded)
        panel.select(.limits)
        XCTAssertEqual(moves(pet), [.expand])
        panel.select(.projects)
        XCTAssertEqual(moves(pet).last, .collapse)
        panel.dismiss(.escape)

        let other = try self.store()
        let onLimits = try self.pet(for: other)
        let (limits, _) = controller(other, pet: onLimits, sections: [.projects])
        limits.openPinned(on: .limits)
        XCTAssertEqual(moves(onLimits), [.expand], "opened on Limits: into the header")
    }

    /// With the readouts off there is no ledge beside the camera: off Limits the pet is not drawn.
    func testWithTheReadoutsOffThePetShowsOnlyOnLimits() throws {
        let store = try store { $0.showEars = false }
        let pet = try pet(for: store)
        let (panel, _) = controller(store, pet: pet, sections: [.projects])
        panel.openPinned(on: .projects)
        XCTAssertFalse(pet.expanded)
        XCTAssertNil(pet.layer.zones?.strip, "no strip zone: nowhere to sit off Limits")
        panel.select(.limits)
        XCTAssertTrue(pet.expanded)
        XCTAssertNotNil(pet.layer.zones?.panel)
    }
}

/// A section that notes whether its content is told it is on the screen.
@MainActor
private final class ShowingProbe: NotchSection {
    var seen: Bool?

    func content(layout: NotchShellLayout) -> AnyView { AnyView(ShowingProbeView(probe: self)) }
    func footerStatus() -> AnyView { AnyView(Text("probe")) }
    func refreshButton() -> AnyView { AnyView(EmptyView()) }
    func refresh() {}
}

private struct ShowingProbeView: View {
    let probe: ShowingProbe
    @Environment(\.groveIsShowing) private var showing

    var body: some View {
        probe.seen = showing
        return Color.clear
    }
}
