// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Combine
import Foundation

// The pet in the app: the one place that reads the clocks, hears Brow and the Mac, keeps the brain, and
// hands the layer and the panel what they draw. The brain and the rig stay pure; every side effect of
// the pet lives here or in `PetSenses`.

// MARK: - What the views read

/// Everything the pet layer poses a frame from, held for it by `PetController` and read by
/// `PetLayerView` at every tick of its `TimelineView`. Only what should rebuild the view is published:
/// the frame rate, a redraw while paused, and the VoiceOver value. The timeline, the tracks and the
/// zones change far more often than that, and every tick reads them afresh anyway.
@MainActor
public final class PetLayer: ObservableObject {
    /// The `TimelineView`'s schedule. It changes at behaviour boundaries and gate changes, a few times a
    /// minute.
    @Published public internal(set) var rate: PetFrameRate = .paused
    /// Bumped to draw one more frame while paused: something changed under a frame that would
    /// otherwise stay on screen as it is (new zones, a new plan, the pet turned off).
    @Published public internal(set) var redraws = 0
    /// The strip element's VoiceOver value.
    @Published public internal(set) var accessibilityValue = ""
    /// `showPet`: off, the strip has no pet element for VoiceOver.
    @Published public internal(set) var isOn = true

    var timeline = PetTimeline()
    var pointer = PetPointerTrack()
    var dock = PetDockTrack()
    var zones: PetZones?
    var seed: UInt64 = 0
    var motion = PetMotion()
    var palette: PetPalette = .standard
    /// The instant a paused layer shows: where the behaviour it rests in has settled, so the frame left
    /// on screen is the doze or the den, not the first frame of a blend into it.
    var frozenAt: TimeInterval?
    /// The rig's clock, `ProcessInfo.systemUptime`: never `TimelineView`'s `context.date`, which is wall
    /// time. Offscreen renders pin it.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// `-petPerfLog`'s counters; nil unless it was asked for.
    var perf: PetPerfLog?
    let rig = PetRig()

    public init() {}

    /// The frame to draw now, nil for none.
    func frame() -> PetFrame? {
        frame(at: rate.paused ? max(now(), frozenAt ?? -.infinity) : now())
    }

    func frame(at t: TimeInterval) -> PetFrame? {
        // Before the brain has heard the readings it has planned nothing, and the rig poses an empty
        // timeline as a content pet at the anchor: nothing is drawn until there is a plan.
        guard !timeline.segments.isEmpty, let zones else { return nil }
        let frame = rig.pose(timeline, at: t, pointer: pointer, dock: dock, zones: zones, seed: seed, motion: motion)
        return frame.isEmpty ? nil : frame
    }

    /// The frame class of what plays at `t`, for `-petPerfLog`.
    func frameClass(at t: TimeInterval) -> PetFrameClass {
        guard let segment = timeline.segments.last(where: { $0.start <= t }) else { return .off }
        return segment.behaviour.frameClass(elapsed: t - segment.start)
    }
}

/// What the panel's header row shows: the state word, the detail line, the moment line, the meter and
/// the VoiceOver value. `PetController` publishes them at most once a second, and only while someone can
/// read them: the panel open, or VoiceOver running.
@MainActor
public final class PetPanelModel: ObservableObject {
    @Published public internal(set) var header = PetText.Header(word: "", detail: "", moment: nil)
    /// 0 to 100.
    @Published public internal(set) var meter: Double = 0
    @Published public internal(set) var accessibilityValue = ""
    /// `PanelView` reports where the Overall line's "5h" figure is, in window coordinates: where the
    /// pet's food comes from in the panel.
    var fiveHourFrameChanged: (CGRect) -> Void = { _ in }
    /// VoiceOver's "Pet" action on the header.
    var boop: () -> Void = {}

    public init() {}
}

// MARK: - The controller

/// Wires the store, the senses, the brain, the frame policy and the layer. It reads both clocks once per
/// event, sends the brain what Brow and the Mac say, sets one timer for whatever is due next, keeps
/// `pet.json`, and publishes only coarse state: the frame rate when it changes, and the words at most
/// once a second.
@MainActor
public final class PetController {
    public let layer = PetLayer()
    public let panel = PetPanelModel()

    private let store: LimitsStore
    private let petStore: PetStore
    private let clock: () -> PetTime
    private let usesSenses: Bool
    private let defaults: UserDefaults
    private(set) var brain: PetBrain
    private var saves = PetSaveSchedule()
    /// What `pet.json` was last written with, so a save that would change nothing but `savedAt` is
    /// skipped.
    private var lastWritten: PetSave?
    private var senses: PetSenses?
    private var watchers: PetHistoryWatchers?
    private var cancellables: Set<AnyCancellable> = []
    private var voiceOverObservation: NSKeyValueObservation?

    // What the controller last heard, mirrored for the gates, `.visible` and the zones.
    private var started = false
    /// `isOn`: the pet's own switch, and Brow in the notch.
    private(set) var showPet = true
    private var showEars = true
    private(set) var expanded = false
    private var windowVisible = true
    private var presence = PetPresence()
    private var systemAwake = true
    private var power = PetPower()
    private var motion = PetMotion()
    /// What the brain was last told, so a change is sent once.
    private var sentVisible: Bool?
    private var sentAccounts: [PetAccount]?
    private var names: [String: String] = [:]
    private var watchedDirs: [String] = []
    private var layout: Layout?
    private var fiveHourFrame: CGRect?
    /// When the last expand, collapse or relayout began, and how long its frames run.
    private var dockMotionUntil: TimeInterval = -.infinity
    private var timer: DispatchSourceTimer?
    /// The `PetTime.mono` the timer is set for, for the tests; nil with no timer.
    private(set) var timerDue: TimeInterval?
    private var wordsTimer: Timer?
    private var lastEarlyCheck: TimeInterval = -.infinity

    /// - Parameters:
    ///   - petStore: where `pet.json` lives; tests pass a temporary directory.
    ///   - clock: both clocks, read once per event.
    ///   - senses: false in tests, which send what the Mac would say themselves: no notification
    ///     observers, no presence timer, no file watchers.
    public init(store: LimitsStore, petStore: PetStore = PetStore(), clock: @escaping () -> PetTime = { PetTime.now() },
                senses: Bool = true, defaults: UserDefaults = .standard) {
        self.store = store
        self.petStore = petStore
        self.clock = clock
        self.usesSenses = senses
        self.defaults = defaults
        let (save, origin) = petStore.load(now: clock().wall)
        brain = PetBrain(restoring: save)
        if origin == .unreadable { BrowLog.pet.info("starting a new pet; pet.json was unreadable") }
        layer.seed = brain.seed
        if defaults.bool(forKey: "petPerfLog") { layer.perf = PetPerfLog() }
        panel.fiveHourFrameChanged = { [weak self] in self?.fiveHourFrame(changed: $0) }
        panel.boop = { [weak self] in self?.boop() }
    }

    // MARK: Launch and quit

    /// Sends the brain the whole state in one main-actor turn: the setting, the
    /// senses' first readings, whether the pet can be seen, the accounts. Called once the panel is on
    /// screen, so the first frame has its zones.
    public func start() {
        guard !started else { return }
        started = true
        showPet = Self.isOn(store.settings)
        showEars = store.settings.showEars
        layer.isOn = showPet
        handle(.showPet(showPet))
        if showPet { startSensing() }
        updateVisible()
        sendReadings(force: true)
        // `-petForceState idle|asleep|hibernating` pins the condition for a measurement.
        if let raw = defaults.string(forKey: "petForceState") {
            if let state = PetForcedState(rawValue: raw) {
                handle(.forceState(state))
            } else {
                BrowLog.pet.error("-petForceState \(raw, privacy: .public) is not idle, asleep or hibernating; ignored")
            }
        }
        // `objectWillChange` fires before the values change: read them a turn later, as the panel and
        // `LimitNotifier` do.
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.storeChanged() }
        }.store(in: &cancellables)
        if usesSenses {
            voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
                Task { @MainActor in self?.updateWordsTimer() }
            }
            layer.perf?.start()
        }
        updateWordsTimer()
    }

    /// Writes `pet.json` whatever the schedule says: Brow is quitting.
    public func flush() {
        save(at: clock())
        timer?.cancel()
        timer = nil
        timerDue = nil
        wordsTimer?.invalidate()
        wordsTimer = nil
        senses?.stop()
        watchers?.stop()
        layer.perf?.stop()
        cancellables.removeAll()
    }

    // MARK: From the panel controller

    /// `NotchPanelController.render()`: the frames and readouts the strip and the panel are drawn with.
    /// A new placement, display or `showEars` is a relayout: the pet fades out at the old place and in
    /// at the new one. A change of readout width is not: the zone follows the digits.
    /// `panelStage`: where the open panel's header row puts the pet's stage (its top-left corner, window
    /// coordinates); nil where `PanelView` has it.
    public func layout(frames: NotchFrames, aggregate: LimitsAggregate, showEars: Bool, panelStage: CGPoint? = nil) {
        let new = Layout(frames: frames, aggregate: aggregate, showEars: showEars, panelStage: panelStage)
        let old = layout
        layout = new
        let zones = PetLayout.zones(frames: frames, aggregate: aggregate, showEars: showEars, fiveHour: fiveHourFrame,
                                    panelStage: panelStage)
        let now = clock()
        if let old, let oldZones = layer.zones, old.key != new.key {
            appendDock(PetDockChange(t: now.mono, kind: .relayout(from: oldZones)), at: now.mono)
            dockMotionUntil = max(dockMotionUntil, now.mono + PetTuning.Hop.relayoutFadeOut + PetTuning.Hop.relayoutFadeIn)
        }
        let changed = zones != layer.zones
        layer.zones = zones
        if showEars != self.showEars {
            self.showEars = showEars
            updateVisible()
        }
        if changed { afterChange(at: now, redraw: true) }
    }

    /// The panel's "5h" figure moved (`PanelView`'s preference).
    func fiveHourFrame(changed rect: CGRect) {
        guard rect != fiveHourFrame, rect.width > 0 else { return }
        fiveHourFrame = rect
        if let layout {
            self.layout(frames: layout.frames, aggregate: layout.aggregate, showEars: layout.showEars,
                        panelStage: layout.panelStage)
        }
    }

    /// `NotchPanelController.mouseMoved`, the pointer in window coordinates. The rig follows the track;
    /// the brain hears the distance from the eyes of the zone the pet is in.
    public func pointerMoved(to location: CGPoint) {
        guard showPet else { return }
        let now = clock()
        layer.pointer.samples.append(PetPointerSample(t: now.mono, location: location))
        // The last 2 s and the one sample before them, for the gaze springs to start from.
        let horizon = now.mono - PetPointerTrack.history
        if let keep = layer.pointer.samples.lastIndex(where: { $0.t <= horizon }), keep > 0 {
            layer.pointer.samples.removeFirst(keep)
        }
        // A moving pointer is someone at the Mac: ask the senses now rather than at the next 5 s check,
        // so a settled or dozing pet answers the hand that came back, not five seconds later.
        if presence.inputIdle >= PetTuning.Presence.settled, now.mono - lastEarlyCheck >= 1 {
            lastEarlyCheck = now.mono
            senses?.checkPresence()
        }
        guard let eyes = eyes() else { return }
        let distance = hypot(Double(location.x - eyes.x), Double(location.y - eyes.y))
        handle(.pointer(distance: distance), at: now)
    }

    /// `setExpanded`, at the instant the outline's spring starts: the hop, glide or crossfade.
    public func dockChanged(expanded: Bool) {
        guard expanded != self.expanded else { return }
        self.expanded = expanded
        let now = clock()
        appendDock(PetDockChange(t: now.mono, kind: expanded ? .expand : .collapse), at: now.mono)
        // The crouch, the flight, the landing and the spring settle within a second; the readouts-off
        // fade and Reduce Motion's crossfade are shorter.
        dockMotionUntil = now.mono + Self.dockFrames
        updateVisible()
        if expanded { publishWords(at: now) }
        updateWordsTimer()
        afterChange(at: now, redraw: true)
    }

    /// The panel window's occlusion state.
    public func windowVisibility(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        updateVisible()
        afterChange(at: clock())
    }

    /// A click in the open panel, in window coordinates: a boop when it lands on the pet's body or
    /// within `PetTuning.Boop.hitSlop` of it.
    @discardableResult
    public func click(at point: CGPoint) -> Bool {
        guard showPet, expanded, let frame = layer.frame(at: clock().mono) else { return false }
        let slop = PetTuning.Boop.hitSlop
        guard frame.bodyBox.insetBy(dx: -slop, dy: -slop).contains(point) else { return false }
        boop()
        return true
    }

    /// A boop: a click on the pet, or VoiceOver's "Pet" action.
    public func boop() {
        guard showPet else { return }
        handle(.boop)
    }

    // MARK: From the store

    private func storeChanged() {
        let on = Self.isOn(store.settings)
        if on != showPet {
            showPet = on
            layer.isOn = showPet
            handle(.showPet(showPet))
            if showPet {
                startSensing()
                // On again, the data is judged afresh: what was used while it was off is a catch-up meal.
                sendReadings(force: true)
            } else {
                stopSensing()
            }
            updateWordsTimer()
        }
        sendReadings()
    }

    /// Whether the pet runs: its own switch, and Brow in the notch at all. Out of the notch there is
    /// nowhere to see it, so it is off as if its switch were: no frames, no timers, no file watchers,
    /// `pet.json` kept, and the time it was off is away time.
    static func isOn(_ settings: BrowSettings) -> Bool {
        settings.showPet && settings.showNotch
    }

    /// The visible accounts, when they differ from what the brain last heard. With no row yet and no
    /// scan landed, nothing: an empty list is then "not looked yet", and telling the brain "no
    /// accounts" would send a new pet into the den for its no-accounts intro seconds before its
    /// accounts arrive. The brain waits, and so does the pet.
    private func sendReadings(force: Bool = false) {
        let rows = store.rows
        guard !rows.isEmpty || store.hasScanned else { return }
        names = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let dirs = rows.flatMap { [$0.account.configDir] + $0.account.aliasDirs }
        if dirs != watchedDirs, showPet {
            watchedDirs = dirs
            watchers?.watch(configDirs: dirs)
        }
        let accounts = rows.map(PetAccount.init(row:))
        guard force || accounts != sentAccounts else { return }
        sentAccounts = accounts
        handle(.readings(accounts))
    }

    // MARK: The senses

    private func startSensing() {
        guard usesSenses else { return }
        if senses == nil {
            senses = PetSenses(onEvent: { [weak self] event, time in self?.sensed(event, at: time) },
                               onPower: { [weak self] power in self?.powerChanged(power) })
        }
        if watchers == nil {
            watchers = PetHistoryWatchers(onPrompt: { [weak self] in self?.handle(.prompt) })
        }
        watchedDirs = []
        senses?.start()
    }

    private func stopSensing() {
        senses?.stop()
        watchers?.stop()
        watchedDirs = []
    }

    /// What `PetSenses` heard, stamped with the instant it heard it.
    func sensed(_ event: PetEvent, at time: PetTime) {
        switch event {
        case .presence(let p): presence = p
        case .motion(let m): motion = m; layer.motion = m
        case .systemSleep: systemAwake = false
        case .systemWake: systemAwake = true
        default: break
        }
        handle(event, at: time)
        updateVisible()
        if case .systemSleep = event { save(at: time) }
    }

    private func powerChanged(_ power: PetPower) {
        self.power = power
        refreshRate(at: clock())
    }

    // MARK: The brain

    private func handle(_ event: PetEvent) {
        handle(event, at: clock())
    }

    private func handle(_ event: PetEvent, at time: PetTime) {
        let planned = brain.handle(event, at: time)
        layer.timeline = brain.timeline
        if case .pointer = event, planned.isEmpty {
            // The brain's fast path: at most a cue. The rate may change (the eyes follow the pointer at
            // the action rate), nothing else does.
            let before = layer.rate
            refreshRate(at: time)
            // The eyes took the action rate: the timer brings it back down half a second after the last
            // move near them. Each firing re-arms it from the latest sample, so a pointer that keeps
            // moving keeps the rate.
            if layer.rate != before { schedule(after: time) }
            return
        }
        afterChange(at: time, redraw: !planned.isEmpty)
    }

    /// `.visible`: the window on screen and not occluded, the display awake and
    /// unlocked, the session active, the Mac awake, and either the strip showing the pet or the panel
    /// open.
    private func updateVisible() {
        guard started else { return }
        let visible = windowVisible && !presence.displayAsleep && !presence.screenLocked && !presence.sessionInactive
            && systemAwake && (showEars || expanded)
        guard visible != sentVisible else { return }
        sentVisible = visible
        handle(.visible(visible))
        updateWordsTimer()
    }

    /// After every event but the pointer's: the save, the frame rate, the timer. `redraw`: what a paused
    /// layer shows may have changed (a new plan, new zones), so it draws its one frame again.
    private func afterChange(at now: PetTime, redraw: Bool = false) {
        guard started else { return }
        saveIfDue(at: now)
        let frozen = layer.frozenAt
        refreshRate(at: now)
        if layer.rate.paused, redraw || layer.frozenAt != frozen { layer.redraws &+= 1 }
        schedule(after: now)
    }

    // MARK: Frames

    /// How long an expand or collapse keeps the layer at the hop's rate: the expand's crouch, its
    /// longest flight, the landing and the spring's settle, with a little to spare.
    static let dockFrames: TimeInterval = 1.1

    /// The layer's schedule now: the policy's rate for the behaviour playing, raised while the pet hops,
    /// glides or fades between the strip and the panel, and held a moment before it pauses so the frame
    /// left on screen is the one the behaviour settles into.
    private func refreshRate(at now: PetTime) {
        let gates = frameGates(at: now.mono)
        var conditions = PetFrameConditions()
        conditions.onAC = power.onAC
        conditions.lowPower = power.lowPower
        conditions.reduceMotion = motion.reduceMotion
        conditions.inputIdle = presence.inputIdle
        if let eyes = eyes() {
            conditions.pointerNear = PetFramePolicy.pointerIsNear(layer.pointer, eyes: eyes, at: now.mono)
        }
        var rate = PetFramePolicy.rate(brain.timeline, at: now.mono, gates: gates, conditions: conditions)
        // The hop between the strip and the panel, and the idle's pounce: the two leaps the behaviour's
        // own class does not cover, drawn in the fast class.
        if now.mono < dockMotionUntil || idleFastWindow(after: now.mono)?.contains(now.mono) == true {
            rate = Self.faster(rate, PetFramePolicy.rate(for: .fast, gates: gates, conditions: conditions))
        }
        layer.frozenAt = rate.paused ? restingInstant(after: now.mono) : nil
        if rate != layer.rate { layer.rate = rate }
    }

    private func frameGates(at mono: TimeInterval) -> PetFrameGates {
        var gates = PetFrameGates()
        // Turned off, the pet still fades out over its 0.2 s: the `.off` segment's own class.
        gates.petOn = showPet || isFadingOut(at: mono)
        gates.displayAwake = !presence.displayAsleep
        gates.unlocked = !presence.screenLocked
        gates.sessionActive = !presence.sessionInactive
        gates.systemAwake = systemAwake
        gates.windowVisible = windowVisible
        // With the readouts hidden the pet lives in the panel only, and fades out with it.
        gates.showsPet = showEars || expanded || mono < dockMotionUntil
        // Away by input, the frames stop whatever the pet is doing, but only after the 2.0 s doze-in that
        // the same presence check started: someone reading without touching the Mac sees the pet settle
        // into its doze instead of jumping into it.
        gates.present = presence.inputIdle < PetTuning.Presence.away || playing(at: mono) == .dozeIn
        return gates
    }

    private func playing(at mono: TimeInterval) -> PetBehaviour? {
        brain.timeline.segments.last(where: { $0.start <= mono })?.behaviour
    }

    /// The pounce's wind-up and leap in the idle playing at `mono`, or the next one's
    /// (`PetRigIdle.fastWindow`).
    private func idleFastWindow(after mono: TimeInterval) -> Range<TimeInterval>? {
        guard let segment = brain.timeline.segments.last(where: { $0.start <= mono }) else { return nil }
        return PetRigIdle.fastWindow(after: mono, segment: segment, seed: brain.seed, reduceMotion: motion.reduceMotion)
    }

    private func isFadingOut(at mono: TimeInterval) -> Bool {
        guard let last = brain.timeline.segments.last(where: { $0.start <= mono }), case .off = last.behaviour else {
            return false
        }
        return mono - last.start < PetTuning.Behaviour.fadeOut
    }

    /// Where the behaviour that will be resting has settled: the first open-ended segment from now on,
    /// past its blend in. A doze is shown dozing, a pet curled in the den curled, never caught between.
    /// One fixed instant per resting segment, so a presence check while paused leaves the frame as it
    /// is instead of drawing it again; the layer never poses before now (`PetLayer.frame()`), and the
    /// brain keeps the segment playing at its memory horizon, so the rig can still pose it.
    private func restingInstant(after mono: TimeInterval) -> TimeInterval {
        let segments = brain.timeline.segments
        let current = segments.lastIndex(where: { $0.start <= mono }) ?? 0
        for segment in segments[current...] where segment.behaviour.duration == nil {
            return segment.start + Self.settle
        }
        return mono
    }

    /// Longer than any posture's blend into a behaviour that pauses the layer (`doze` 0.5 s, `denWait`
    /// 0.4 s).
    static let settle: TimeInterval = 0.6

    static func faster(_ a: PetFrameRate, _ b: PetFrameRate) -> PetFrameRate {
        switch (a, b) {
        case (.native, _), (_, .native): return .native
        case (.paused, let other), (let other, .paused): return other
        case (.fps(let x), .fps(let y)): return .fps(max(x, y))
        }
    }

    /// The pet's eyes in the zone it is in, for the pointer's distance: `Pointer.eyeHeight` above the
    /// anchor, at the zone's scale.
    private func eyes() -> CGPoint? {
        guard let zones = layer.zones, let zone = expanded ? zones.panel : zones.strip else { return nil }
        return CGPoint(x: zone.anchor.x, y: zone.anchor.y - CGFloat(PetTuning.Pointer.eyeHeight) * zone.scale)
    }

    private func appendDock(_ change: PetDockChange, at mono: TimeInterval) {
        var changes = layer.dock.changes
        changes.append(change)
        // The last expand or collapse however old, and every change of the last 2 s.
        let horizon = mono - PetDockTrack.history
        let lastMove = changes.lastIndex { $0.kind == .expand || $0.kind == .collapse }
        changes = changes.enumerated().filter { $0.element.t > horizon || $0.offset == lastMove }.map(\.element)
        layer.dock.changes = changes
    }

    // MARK: The timer

    /// One one-shot timer at whatever is due first: the brain's deadline, a change of frame class, the
    /// pointer leaving the eyes' range, the end of a hop, the next look at the save schedule. Every
    /// firing is a tick for the brain, whichever of these it was set for: a tick with nothing due
    /// changes nothing, and one that comes late only plays the brain's deadlines at their own instants,
    /// later than they should have been drawn.
    private func schedule(after now: PetTime) {
        timer?.cancel()
        timer = nil
        timerDue = nil
        guard showPet || isFadingOut(at: now.mono) else { return }
        var due: [TimeInterval] = []
        if let deadline = brain.nextDeadline(after: now) { due.append(deadline.mono) }
        if let change = PetFramePolicy.nextChange(brain.timeline, after: now.mono) { due.append(change) }
        if let near = layer.pointer.samples.last, now.mono - near.t <= PetTuning.Frames.pointerRecent {
            due.append(near.t + PetTuning.Frames.pointerRecent + 0.01)
        }
        if now.mono < dockMotionUntil { due.append(dockMotionUntil) }
        if let leap = idleFastWindow(after: now.mono) { due += [leap.lowerBound, leap.upperBound] }
        if let save = saves.nextCheck(brain: brain) { due.append(save) }
        guard let next = due.filter({ $0 > now.mono }).min() else { return }
        timerDue = next
        // Strict: what the brain commits at a deadline starts at the deadline's own instant, so a tick
        // that comes late is a beat cut short on screen, and `asyncAfter` lets the system defer a timer
        // by a tenth of its delay.
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(deadline: .now() + (next - now.mono), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.timerFired() } }
        source.resume()
        timer = source
    }

    /// The one-shot timer's work; tests call it at a clock they moved, rather than waiting for it.
    func timerFired() {
        timer?.cancel()
        timer = nil
        timerDue = nil
        let now = clock()
        // Always a tick: `nextDeadline(after: now)` names the deadline after the one that fired, so it
        // can never say that one is due. A tick with nothing due changes nothing.
        _ = brain.handle(.tick, at: now)
        layer.timeline = brain.timeline
        // A change of frame class, the pointer gone, a hop landed: what a paused layer shows may have
        // changed too.
        afterChange(at: now, redraw: true)
    }

    // MARK: pet.json

    /// The schedule's saves. One that would write the file as it already is, but for `savedAt`, is
    /// skipped: while the pet rests, paused or unseen, nothing else changes, and the every-10-minutes
    /// save would otherwise be the one thing waking the disk.
    private func saveIfDue(at now: PetTime) {
        guard saves.isDue(at: now.mono, brain: brain) else { return }
        let save = brain.save(at: now)
        if var written = lastWritten {
            written.savedAt = save.savedAt
            if written == save {
                saves.saved(at: now.mono, brain: brain)
                return
            }
        }
        write(save, at: now)
    }

    /// Writes `pet.json` whatever it holds: on `willSleep` and on quit.
    private func save(at now: PetTime) {
        write(brain.save(at: now), at: now)
    }

    private func write(_ save: PetSave, at now: PetTime) {
        do {
            try petStore.save(save)
            lastWritten = save
        } catch {
            BrowLog.pet.error("pet.json not saved: \(String(describing: error), privacy: .public)")
        }
        saves.saved(at: now.mono, brain: brain)
    }

    // MARK: The words

    /// Once a second while someone can read them: the panel open, or VoiceOver running while the strip
    /// can be seen (not with the display asleep or the screen locked, when nobody can reach it).
    private func updateWordsTimer() {
        let wanted = showPet
            && (expanded || (usesSenses && NSWorkspace.shared.isVoiceOverEnabled && sentVisible == true))
        if wanted, wordsTimer == nil {
            publishWords(at: clock())
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.publishWords(at: self.clock()) }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            wordsTimer = timer
        } else if !wanted {
            wordsTimer?.invalidate()
            wordsTimer = nil
        }
    }

    /// The header's words, the meter and the VoiceOver value at `now`. Each is published only when it
    /// changed, so an open panel re-renders when the words do, not every second.
    func publishWords(at now: PetTime) {
        let status = brain.status(at: now)
        let header = PetText.header(status, now: now.wall, timeZone: .current, calendar: .current, names: names)
        let value = PetText.voiceOverValue(status, now: now.wall, timeZone: .current, calendar: .current)
        if panel.header != header { panel.header = header }
        if panel.meter != status.meter { panel.meter = status.meter }
        if panel.accessibilityValue != value { panel.accessibilityValue = value }
        if layer.accessibilityValue != value { layer.accessibilityValue = value }
    }
}

extension PetController {
    /// What a relayout is judged on: the strip's place and shape and whether the readouts show. The
    /// expanded height is not in it: the window hangs from the top edge, so a taller panel moves no zone.
    struct Layout {
        var frames: NotchFrames
        var aggregate: LimitsAggregate
        var showEars: Bool
        var panelStage: CGPoint?

        var key: [CGFloat] {
            let notch = frames.notch ?? .zero
            return [frames.collapsed.minX, frames.collapsed.minY, frames.collapsed.width, frames.collapsed.height,
                    frames.expanded.minX, frames.expanded.maxY, frames.expanded.width, notch.minX, notch.width,
                    frames.placement == .below ? 1 : 0, frames.hasNotch ? 1 : 0, showEars ? 1 : 0]
        }
    }
}
