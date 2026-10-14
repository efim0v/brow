import AppKit
import Combine
import UserNotifications

public enum NotificationAuthorization: Sendable, Equatable { case unknown, notDetermined, allowed, denied, unavailable }

/// What `LimitNotifier` needs from Notification Center. A protocol because the real
/// center cannot exist outside an app bundle: tests and `swift run` get a stand-in.
public protocol NotificationPosting: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Asks macOS for `[.alert, .sound]` and answers with the status that follows.
    func requestAuthorization() async -> NotificationAuthorization
    func post(_ notice: LimitNotice) async
    func removePending()
    func removePending(ids: [String])
}

/// `UNUserNotificationCenter`. Local notifications only: nothing here talks to a server.
final class SystemNotifications: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter.current()` traps without an app bundle (`swift run`,
    /// `swift test`).
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .allowed
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { BrowLog.notify.error("authorization request failed: \(error.localizedDescription, privacy: .public)") }
        return await authorization()
    }

    func post(_ notice: LimitNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.kind == .reset ? nil : .default
        // Scheduled with the system, so a reset notice is on time even if the Mac
        // sleeps through it or Brow has quit.
        let trigger = notice.deliverAt.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        do { try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger)) }
        catch { BrowLog.notify.error("notification \(notice.id, privacy: .public) not added: \(error.localizedDescription, privacy: .public)") }
    }

    /// Brow schedules nothing but reset notices, so clearing every pending request is
    /// clearing those.
    func removePending() { center.removeAllPendingNotificationRequests() }

    func removePending(ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }

    /// Brow is frontmost while Settings is open; without this a test notification
    /// sent from there would go straight to the list, unseen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click does nothing special: opening the panel would need its private `setExpanded`.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// A bare executable has no Notification Center. Says so once and posts nothing.
final class UnavailableNotifications: NotificationPosting {
    private static let report = OneShot()

    private func log() {
        if Self.report.fire() { BrowLog.notify.error("no app bundle; limit warnings cannot be posted") }
    }

    func authorization() async -> NotificationAuthorization { log(); return .unavailable }
    func requestAuthorization() async -> NotificationAuthorization { log(); return .unavailable }
    func post(_ notice: LimitNotice) async { log() }
    func removePending() {}
    func removePending(ids: [String]) {}
}

/// Watches the store, runs `LimitWarnings` over every change and hands what it finds
/// to Notification Center — only once macOS allows it, and asking only once the user
/// has turned warnings on.
@MainActor
public final class LimitNotifier: ObservableObject {
    @Published public private(set) var authorization: NotificationAuthorization = .unknown

    private let poster: NotificationPosting
    private let now: () -> Date
    private var warnings = LimitWarnings()
    /// Reset notices handed to macOS and not due yet, by id. Hidden accounts never
    /// notify, so the ones for an account that leaves the panel are taken back.
    private var pendingResets: [String: Date] = [:]
    /// The last settings seen, for the on/off edges in `settingsChanged`.
    private var settings: BrowSettings?
    private var cancellables: Set<AnyCancellable> = []
    private var activeObserver: (any NSObjectProtocol)?
    /// Posts and removals, one after another in the order they were decided: a reset
    /// notice still being added must not land after the removal that was meant for it.
    private(set) var delivery: Task<Void, Never>?
    /// The permission request in flight, if any.
    private(set) var permissionRequest: Task<Void, Never>?

    init(poster: NotificationPosting, now: @escaping () -> Date = { Date() }) {
        self.poster = poster
        self.now = now
    }

    func start(store: LimitsStore) {
        settings = store.settings
        // `objectWillChange` fires BEFORE the values change: read them a turn later,
        // as the panel does.
        store.objectWillChange.sink { [weak self, weak store] _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.evaluate(rows: store.rows, settings: store.settings)
            }
        }.store(in: &cancellables)
        // `@Published` fires in `willSet`: the new value is the argument.
        store.$settings.sink { [weak self] in self?.settingsChanged(to: $0) }.store(in: &cancellables)
        // Picks up a change made in System Settings, which Brow is not told about.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshAuthorization() }
            }
        permissionRequest = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshAuthorization()
            // Warnings already on: the user opted in before, so the question is theirs.
            if self.settings?.notifyLimits == true, self.authorization == .notDetermined {
                await self.requestPermission()
            }
        }
        evaluate(rows: store.rows, settings: store.settings)
    }

    func stop() {
        cancellables.removeAll()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver); self.activeObserver = nil }
    }

    func refreshAuthorization() async {
        authorization = await poster.authorization()
    }

    func requestPermission() async {
        authorization = await poster.requestAuthorization()
    }

    func sendTest() {
        let levels = LimitWarnings.sanitized(settings?.notifyThresholds ?? LimitWarnings.defaultLevels)
        let notice = LimitNotice(id: "test", kind: .test, title: "Brow",
                                 body: NoticeText.testBody(levels: levels), deliverAt: nil)
        enqueue { [poster] in await poster.post(notice) }
    }

    /// Runs even while notifications are denied, so the baselines stay what they would
    /// have been; only the posting waits for `.allowed`.
    ///
    /// The status is asked again, not read from `authorization`: a change made in System
    /// Settings is announced to nobody, Brow (an accessory app behind a non-activating
    /// panel) may not become active again for days, and at launch the first read may
    /// not have come back yet.
    func evaluate(rows: [AccountRow], settings: BrowSettings) {
        let now = self.now()
        let notices = warnings.evaluate(rows: rows, settings: settings, now: now)
        let shown = rows.map { "reset.\($0.id)." }      // `LimitNotice.id`
        pendingResets = pendingResets.filter { $0.value > now }
        let gone = pendingResets.keys.filter { id in !shown.contains { id.hasPrefix($0) } }.sorted()
        if !gone.isEmpty {
            for id in gone { pendingResets[id] = nil }
            enqueue { [poster] in poster.removePending(ids: gone) }
        }
        for notice in notices where notice.kind == .reset { pendingResets[notice.id] = notice.deliverAt }
        guard !notices.isEmpty else { return }
        enqueue { [weak self, poster] in
            let status = await poster.authorization()
            if let self, self.authorization != status { self.authorization = status }
            guard status == .allowed else {
                BrowLog.notify.info("\(notices.count) notice(s) not posted: notifications are not allowed")
                return
            }
            for notice in notices { await poster.post(notice) }
        }
    }

    func settingsChanged(to new: BrowSettings) {
        let old = settings ?? new
        settings = new
        if new.notifyLimits && !old.notifyLimits {
            permissionRequest = Task { @MainActor [weak self] in
                guard let self else { return }
                if self.authorization == .unknown { await self.refreshAuthorization() }
                if self.authorization == .notDetermined { await self.requestPermission() }
            }
        }
        if (old.notifyLimits && !new.notifyLimits) || (old.notifyResets && !new.notifyResets) {
            pendingResets.removeAll()
            enqueue { [poster] in poster.removePending() }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = delivery
        delivery = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
