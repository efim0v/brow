import AppKit
import XCTest
@testable import BrowKit

@MainActor
final class BrowMainMenuTests: XCTestCase {
    /// `NSMenuItem.target` is a zeroing weak reference, so the controller has to
    /// outlive the menu for the Settings item to keep its target — which is why
    /// `BrowApp.run()` parks the controller in a static.
    private var controller: BrowAppController!

    override func setUp() { super.setUp(); controller = BrowAppController() }
    override func tearDown() { controller = nil; super.tearDown() }

    private func appMenu() throws -> NSMenu {
        try XCTUnwrap(controller.makeMainMenu().items.first?.submenu)
    }

    /// The regression this guards: a non-nib `.accessory` app with no main menu
    /// has no working Cmd-Q, and Brow has no Dock icon or status item to quit
    /// from — `pkill` becomes the only exit.
    func testMainMenuCarriesQuitOnCommandQ() throws {
        let quit = try XCTUnwrap(appMenu().items.first { $0.title == "Quit Brow" })
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertNil(quit.target, "nil target so the action reaches NSApp through the responder chain")
    }

    func testMainMenuCarriesSettingsOnCommandComma() throws {
        let settings = try XCTUnwrap(appMenu().items.first { $0.title == "Settings…" })
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertTrue(settings.target is BrowAppController)
    }

    /// Without an Edit menu, Cmd-C/Cmd-V/Cmd-A are dead in the settings text fields —
    /// in the window whose main job is pasting a path.
    func testMainMenuCarriesEditForTheSettingsTextFields() throws {
        let main = controller.makeMainMenu()
        let edit = try XCTUnwrap(main.items.first { $0.title == "Edit" }?.submenu)
        let items = Dictionary(uniqueKeysWithValues: edit.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        XCTAssertEqual(items["Cut"]?.keyEquivalent, "x")
        XCTAssertEqual(items["Copy"]?.keyEquivalent, "c")
        XCTAssertEqual(items["Paste"]?.keyEquivalent, "v")
        XCTAssertEqual(items["Select All"]?.keyEquivalent, "a")
        XCTAssertEqual(items["Undo"]?.keyEquivalent, "z")
        XCTAssertEqual(items["Copy"]?.action, #selector(NSText.copy(_:)))
        for item in edit.items where !item.isSeparatorItem {
            XCTAssertNil(item.target, "\(item.title) must walk the responder chain to the focused field")
        }
    }

    func testMainMenuCarriesCloseOnCommandW() throws {
        let main = controller.makeMainMenu()
        let window = try XCTUnwrap(main.items.first { $0.title == "Window" }?.submenu)
        let close = try XCTUnwrap(window.items.first { $0.title == "Close" })
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(close.keyEquivalent, "w")
    }
}
