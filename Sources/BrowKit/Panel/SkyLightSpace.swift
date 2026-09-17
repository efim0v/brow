import AppKit
import Foundation

/// Keeps a window welded to the screen across Spaces switches.
///
/// When the user swipes between Spaces (or presses ⌃← / ⌃→), the WindowServer slides
/// every window of the outgoing and incoming Space — including windows that
/// `canJoinAllSpaces` — so a notch strip drawn as an ordinary panel visibly
/// detaches from the physical notch, slides away and slides back. The notch itself,
/// of course, does not move. What does stay put is a window that lives in a
/// *separate* space of its own, above the user's Spaces: that space is not part of
/// the transition. This is how boring.notch and NotchNook keep their strips still.
///
/// The calls are private SkyLight API (`CGS*`), resolved at runtime with `dlsym`, so
/// a macOS that renames or drops them degrades to the ordinary (sliding) behaviour
/// instead of failing to load — `init` returns nil and the caller logs it.
@MainActor
final class SkyLightSpace {
    private typealias ConnectionID = UInt32
    private typealias SpaceID = UInt64
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias SpaceCreate = @convention(c) (ConnectionID, UInt, CFDictionary?) -> SpaceID
    private typealias SpaceSetLevel = @convention(c) (ConnectionID, SpaceID, Int32) -> Void
    private typealias SpacesOp = @convention(c) (ConnectionID, CFArray) -> Void
    private typealias WindowsOp = @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private typealias SpaceDestroy = @convention(c) (ConnectionID, SpaceID) -> Void

    /// The highest absolute level SkyLight accepts — above the Spaces transition and
    /// above full-screen apps (the same value boring.notch uses).
    nonisolated static let topLevel: Int32 = Int32.max

    private let cid: ConnectionID
    private let space: SpaceID
    private let addWindows: WindowsOp
    private let removeWindows: WindowsOp
    private let hideSpaces: SpacesOp
    private let destroySpace: SpaceDestroy
    private(set) var windowNumbers: Set<Int> = []

    init?(level: Int32 = SkyLightSpace.topLevel) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self),
              let create = symbol("CGSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self),
              let show = symbol("CGSShowSpaces", as: SpacesOp.self),
              let hide = symbol("CGSHideSpaces", as: SpacesOp.self),
              let add = symbol("CGSAddWindowsToSpaces", as: WindowsOp.self),
              let remove = symbol("CGSRemoveWindowsFromSpaces", as: WindowsOp.self),
              let destroy = symbol("CGSSpaceDestroy", as: SpaceDestroy.self)
        else { return nil }
        cid = mainConnection()
        // The second argument "MUST be 1, otherwise Finder decides to draw desktop
        // icons" (boring.notch, CGSSpace.swift).
        space = create(cid, 1, nil)
        guard space != 0 else { return nil }
        setLevel(cid, space, level)
        show(cid, [NSNumber(value: space)] as CFArray)
        addWindows = add
        removeWindows = remove
        hideSpaces = hide
        destroySpace = destroy
    }

    /// Call AFTER the window is on screen (`orderFrontRegardless`): a window number
    /// only exists once the window has been ordered in.
    func add(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0, !windowNumbers.contains(number) else { return }
        addWindows(cid, [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
        windowNumbers.insert(number)
    }

    func remove(_ window: NSWindow) {
        let number = window.windowNumber
        guard windowNumbers.remove(number) != nil else { return }
        removeWindows(cid, [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    deinit {
        let spaces = [NSNumber(value: space)] as CFArray
        hideSpaces(cid, spaces)
        destroySpace(cid, space)
    }
}
