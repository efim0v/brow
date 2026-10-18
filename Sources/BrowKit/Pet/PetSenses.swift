// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.ps

// What the pet senses of the Mac: the person, the display and the session, power, the display options,
// the clock, and Claude Code being typed into. Everything here is outside the brain, so it may read
// clocks: each event is stamped once, here, and the brain takes the stamp as the event's time.

extension PetTime {
    /// Both clocks, read once: the wall clock and `ProcessInfo.systemUptime`, which stops while the
    /// Mac sleeps and never jumps.
    public static func now() -> PetTime {
        PetTime(wall: Date(), mono: ProcessInfo.processInfo.systemUptime)
    }
}

extension PetTuning.Eager {
    /// Writes to one `history.jsonl` this close together are one prompt: a single append can reach the
    /// watcher as two events. Nobody types two prompts a quarter of a second apart, and the brain would
    /// do nothing more with the second.
    public static let promptBurst: TimeInterval = 0.25
}

/// The power the frame policy caps by.
public struct PetPower: Sendable, Equatable {
    public var onAC = true
    public var lowPower = false

    public init(onAC: Bool = true, lowPower: Bool = false) {
        self.onAC = onAC
        self.lowPower = lowPower
    }

    /// `IOPSGetProvidingPowerSourceType` and `ProcessInfo.isLowPowerModeEnabled`, now.
    public static func current() -> PetPower {
        var onAC = true
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onAC = (type as String) == kIOPMACPowerKey
        }
        return PetPower(onAC: onAC, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Compares the two clocks between presence checks. The monotonic clock stops while the Mac sleeps; the
/// wall clock does not, and it jumps when it is set. So a wall gap much longer than the monotonic one
/// is a sleep whose wake notification was missed, and a smaller difference either way is the clock
/// being set. A difference after `NSSystemClockDidChange` is the clock being set, however large.
public struct PetClockWatch: Sendable, Equatable {
    public enum Finding: Sendable, Equatable {
        case steady
        /// The wall clock moved this much more than the monotonic one: set by hand or by the network.
        case jumped(by: TimeInterval)
        /// More than `PetTuning.Presence.missedCheck` passed on the wall clock that the monotonic one
        /// never saw: the Mac slept.
        case slept(for: TimeInterval)
    }

    private var last: PetTime?
    /// `NSSystemClockDidChange` came since the last check.
    private var clockSet = false

    public init() {}

    public mutating func check(_ time: PetTime) -> Finding {
        defer {
            last = time
            clockSet = false
        }
        guard let last else { return .steady }
        let drift = time.wall.timeIntervalSince(last.wall) - (time.mono - last.mono)
        if drift > PetTuning.Presence.missedCheck && !clockSet { return .slept(for: drift) }
        if abs(drift) > PetTuning.Clock.jump { return .jumped(by: drift) }
        return .steady
    }

    /// `NSSystemClockDidChange`: whatever the next check finds was the clock being set.
    public mutating func clockWasSet() { clockSet = true }

    /// After a wake the notification announced, so the first check after it is not a second one.
    public mutating func reset() {
        last = nil
        clockSet = false
    }
}

// MARK: - history.jsonl

/// Watches the visible accounts' `history.jsonl`, which Claude Code appends to on every prompt typed.
/// It asks macOS to say when the file is written and never opens it for reading: `O_EVTONLY` and a
/// vnode source, so all it learns is "written now". One watcher per directory, the account's config dir
/// and each alias dir, by their real path, so two spellings of one folder are one watcher.
@MainActor
public final class PetHistoryWatchers {
    private let onPrompt: @MainActor () -> Void
    private var watchers: [String: PetHistoryWatcher] = [:]

    public init(onPrompt: @escaping @MainActor () -> Void) {
        self.onPrompt = onPrompt
    }

    /// Follows the visible accounts: watchers for new directories, none left for gone ones.
    public func watch(configDirs: [String]) {
        let home = NSHomeDirectory()
        let wanted = Set(configDirs.compactMap { ClaudeCodeActivity.canonicalConfigDir($0, cwd: nil, home: home) })
        for (dir, watcher) in watchers where !wanted.contains(dir) {
            watcher.cancel()
            watchers[dir] = nil
        }
        for dir in wanted.sorted() where watchers[dir] == nil {
            let watcher = PetHistoryWatcher(directory: dir) { [weak self] in self?.onPrompt() }
            watchers[dir] = watcher
            watcher.arm()
        }
    }

    /// The pet off: every watcher closed.
    public func stop() {
        for watcher in watchers.values { watcher.cancel() }
        watchers = [:]
    }

    var directories: [String] { watchers.keys.sorted() }
}

/// One directory's `history.jsonl`.
@MainActor
final class PetHistoryWatcher {
    let directory: String
    private let onPrompt: @MainActor () -> Void
    private var file: DispatchSourceFileSystemObject?
    private var folder: DispatchSourceFileSystemObject?
    private var reopen: DispatchWorkItem?
    /// The file did not exist when last looked at: its appearing is a prompt being written.
    private var missing = false
    /// `ProcessInfo.systemUptime` of the last prompt passed on.
    private var lastPrompt: TimeInterval = -.infinity

    init(directory: String, onPrompt: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onPrompt = onPrompt
    }

    private var path: String { directory + "/history.jsonl" }

    /// Watches the file if it is a regular file of this directory's own. Missing, the directory is
    /// watched until it appears. A symlink is not watched: it is shared with other accounts and says
    /// nothing about this one (`ClaudeCodeActivity.lastPrompt` explains), but the directory is, in
    /// case it becomes a file of its own.
    func arm() {
        cancelSources()
        switch kind() {
        case .regular:
            missing = false
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return watchFolder() }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let events = source?.data else { return }
                MainActor.assumeIsolated { self?.fileChanged(events) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            file = source
        case .missing:
            missing = true
            watchFolder()
        case .other:
            missing = false
            watchFolder()
        }
    }

    func cancel() {
        cancelSources()
        reopen?.cancel()
        reopen = nil
    }

    private enum Kind { case regular, missing, other }

    private func kind() -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        return info.st_mode & S_IFMT == S_IFREG ? .regular : .other
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            // Replaced or moved away: look again in a second, when whatever replaced it is in place.
            cancelSources()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.arm() } }
            reopen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PetTuning.Eager.watcherReopen, execute: work)
            return
        }
        if events.contains(.write) || events.contains(.extend) { prompt() }
    }

    /// One append can reach the vnode source as two events, and a file created with its first line can
    /// be seen appearing and then written: either way it is one prompt.
    private func prompt() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPrompt >= PetTuning.Eager.promptBurst else { return }
        lastPrompt = now
        onPrompt()
    }

    private func watchFolder() {
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }          // no such directory: nothing to watch
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.folderChanged() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folder = source
    }

    /// Something in the directory changed: the file may have arrived.
    private func folderChanged() {
        guard kind() == .regular else { return }
        let appeared = missing
        arm()
        // Claude Code creates the file with the first prompt in it; by the time it is open to watch,
        // that write has happened.
        if appeared { prompt() }
    }

    private func cancelSources() {
        file?.cancel()
        file = nil
        folder?.cancel()
        folder = nil
    }
}

// MARK: - The Mac

/// The person, the display and the session, power, the display options and the clock, as events for the
/// brain (and power for the frame policy). Start it when the pet is on, stop it when it is off: off,
/// nothing here runs.
@MainActor
public final class PetSenses {
    public private(set) var presence = PetPresence()
    public private(set) var power = PetPower()
    public private(set) var motion = PetMotion()
    /// False from `willSleepNotification` to `didWakeNotification`.
    public private(set) var systemAwake = true

    private let onEvent: @MainActor (PetEvent, PetTime) -> Void
    private let onPower: @MainActor (PetPower) -> Void
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    /// The power source's own reference to the senses, released in `stop()`.
    private var powerContext: Unmanaged<PetSenses>?
    private var clockWatch = PetClockWatch()
    private static let jumpReport = OneShot()

    /// - Parameters:
    ///   - onEvent: every event for the brain, with the instant it was sensed.
    ///   - onPower: the power source or Low Power Mode changed; read the frame policy again.
    public init(onEvent: @escaping @MainActor (PetEvent, PetTime) -> Void,
                onPower: @escaping @MainActor (PetPower) -> Void) {
        self.onEvent = onEvent
        self.onPower = onPower
    }

    /// Reads the current state, sends it (`presence`, `motion`, `timeZone`), and starts listening.
    public func start() {
        guard observers.isEmpty else { return }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        presence.screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        presence.sessionInactive = !(session?[kCGSessionOnConsoleKey as String] as? Bool ?? true)
        presence.displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        power = PetPower.current()
        motion = Self.currentMotion()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayChanged(asleep: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayChanged(asleep: false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionChanged(active: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionChanged(active: true) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.displayOptionsChanged() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.lockChanged(locked: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.lockChanged(locked: false) }
        let local = NotificationCenter.default
        observe(local, .NSSystemClockDidChange) { senses in
            senses.clockWatch.clockWasSet()
            senses.send(.clockChanged)
        }
        observe(local, .NSSystemTimeZoneDidChange) { senses in
            NSTimeZone.resetSystemTimeZone()
            senses.send(.timeZone(TimeZone.current))
        }
        observe(local, .NSProcessInfoPowerStateDidChange) { $0.powerChanged() }
        startPowerSource()

        send(.motion(motion))
        send(.timeZone(TimeZone.current))
        check()
        scheduleChecks()
    }

    public func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        powerContext?.release()
        powerContext = nil
        clockWatch.reset()
    }

    /// A presence check now, between the 5 s ones: the controller asks when the pointer moves while the
    /// last check found the person settled or away, so the pet answers someone coming back at once.
    public func checkPresence() {
        guard !observers.isEmpty else { return }
        check()
    }

    /// Seconds since the last input of any kind.
    public static func inputIdle() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return max(0, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any))
    }

    public static func currentMotion() -> PetMotion {
        let workspace = NSWorkspace.shared
        return PetMotion(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                         reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                         increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    // MARK: Presence

    /// One presence check: every 5 s while the display is awake and the session active, and at each
    /// notification. A check that finds more wall time than monotonic time since the last one is a
    /// sleep whose wake was missed, or the clock being set.
    private func check() {
        let now = PetTime.now()
        switch clockWatch.check(now) {
        case .steady:
            break
        case .slept(let gap):
            BrowLog.pet.info("the Mac slept \(Int(gap), privacy: .public) s without a wake notification")
            awake(at: now)
        case .jumped(let drift):
            if Self.jumpReport.fire() {
                BrowLog.pet.info("the clock jumped \(Int(drift), privacy: .public) s; hunger and animation run on the monotonic clock")
            }
            onEvent(.clockChanged, now)
            // The clock is often set right after a wake, so a jump this far forward may also hide a
            // sleep whose wake notification never came. Saying the Mac is awake is harmless if it
            // already knew, and without it a missed wake would leave the pet unseen until the next one.
            if drift > PetTuning.Presence.missedCheck { awake(at: now) }
        }
        presence.inputIdle = Self.inputIdle()
        onEvent(.presence(presence), now)
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard !presence.displayAsleep, !presence.sessionInactive, systemAwake else { return }
        let timer = Timer(timeInterval: PetTuning.Presence.checkEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = PetTuning.Presence.checkTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func displayChanged(asleep: Bool) {
        presence.displayAsleep = asleep
        check()
        scheduleChecks()
    }

    private func sessionChanged(active: Bool) {
        presence.sessionInactive = !active
        check()
        scheduleChecks()
    }

    private func lockChanged(locked: Bool) {
        presence.screenLocked = locked
        check()
    }

    private func systemWillSleep() {
        systemAwake = false
        send(.systemSleep)
        scheduleChecks()
    }

    private func systemDidWake() {
        systemAwake = true
        // The notification says it; the next check must not say it again from the clocks.
        clockWatch.reset()
        send(.systemWake)
        check()
        scheduleChecks()
    }

    /// The clocks say the Mac slept and no wake notification came. Since `willSleep` stopped the 5 s
    /// checks, a missed wake would also leave them stopped: they start again here.
    private func awake(at now: PetTime) {
        onEvent(.systemWake, now)
        guard !systemAwake else { return }
        systemAwake = true
        scheduleChecks()
    }

    // MARK: Display options, power

    private func displayOptionsChanged() {
        let new = Self.currentMotion()
        guard new != motion else { return }
        motion = new
        send(.motion(new))
    }

    private func powerChanged() {
        let new = PetPower.current()
        guard new != power else { return }
        power = new
        onPower(new)
    }

    /// The run-loop source holds a retained reference to the senses until `stop()` removes it and lets
    /// go, so its callback can never reach a `PetSenses` that was released without being stopped.
    private func startPowerSource() {
        let retained = Unmanaged.passRetained(self)
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let senses = Unmanaged<PetSenses>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { senses.powerChanged() }
        }, retained.toOpaque())?.takeRetainedValue() else {
            retained.release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
        powerContext = retained
    }

    // MARK: Plumbing

    private func send(_ event: PetEvent) {
        onEvent(event, PetTime.now())
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (PetSenses) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, observer))
    }
}
