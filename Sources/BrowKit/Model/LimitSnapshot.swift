import Foundation
import GroveCore

/// One account's last-known limits, dated by the fetch that produced them.
/// Persisted so a relaunch shows real numbers with their real age instead of
/// blanks until the first request returns.
public struct LimitSnapshot: Codable, Sendable, Equatable {
    public static let staleAfter: TimeInterval = 180

    public let organizationUuid: String
    public let fetchedAt: Date
    public let fiveHour: CapturedWindow?
    public let sevenDay: CapturedWindow?
    public let weeklyScoped: CapturedWindow?
    public let weeklyScopedModel: String?
    /// When `weeklyScoped` was obtained, if not at `fetchedAt`: a statusline capture
    /// refreshes the 5h and weekly windows but carries no model-scoped one, so the
    /// Fable bar keeps the API reading and its own, older, age.
    public let scopedFetchedAt: Date?

    public init(organizationUuid: String, fetchedAt: Date, fiveHour: CapturedWindow?,
                sevenDay: CapturedWindow?, weeklyScoped: CapturedWindow?, weeklyScopedModel: String?,
                scopedFetchedAt: Date? = nil) {
        self.organizationUuid = organizationUuid
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.weeklyScoped = weeklyScoped
        self.weeklyScopedModel = weeklyScopedModel
        self.scopedFetchedAt = scopedFetchedAt
    }

    /// The 5h and weekly windows from a newer statusline capture, the scoped window
    /// kept from this reading with its date. A window the capture lacks is kept too.
    public func merging(_ capture: StatuslineReading) -> LimitSnapshot {
        LimitSnapshot(organizationUuid: organizationUuid, fetchedAt: capture.capturedAt,
                      fiveHour: capture.fiveHour ?? fiveHour, sevenDay: capture.sevenDay ?? sevenDay,
                      weeklyScoped: weeklyScoped, weeklyScopedModel: weeklyScopedModel,
                      scopedFetchedAt: weeklyScoped == nil ? nil : (scopedFetchedAt ?? fetchedAt))
    }

    /// A reading with nothing but a statusline capture behind it.
    public init(organizationUuid: String, capture: StatuslineReading) {
        self.init(organizationUuid: organizationUuid, fetchedAt: capture.capturedAt,
                  fiveHour: capture.fiveHour, sevenDay: capture.sevenDay, weeklyScoped: nil, weeklyScopedModel: nil)
    }

    public func isScopedStale(now: Date) -> Bool {
        now.timeIntervalSince(scopedFetchedAt ?? fetchedAt) > Self.staleAfter
    }

    /// nil when the payload carries none of the windows Brow shows.
    public init?(organizationUuid: String, usage: OAuthUsage, now: Date) {
        func window(_ u: Double?, _ r: String?) -> CapturedWindow? {
            u.map { CapturedWindow(usedPercentage: min(max($0, 0), 100), resetsAt: r) }
        }
        let five = window(usage.fiveHour?.utilization, usage.fiveHour?.resetsAt)
        let seven = window(usage.sevenDay?.utilization, usage.sevenDay?.resetsAt)
        let scoped = window(usage.weeklyScoped?.utilization, usage.weeklyScoped?.resetsAt)
        guard five != nil || seven != nil || scoped != nil else { return nil }
        self.init(organizationUuid: organizationUuid, fetchedAt: usage.fetchedAt ?? now,
                  fiveHour: five, sevenDay: seven, weeklyScoped: scoped,
                  weeklyScopedModel: usage.weeklyScoped?.modelDisplayName)
    }

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > Self.staleAfter }

    // CapturedWindow lives in GroveCore and is not Codable; mirror it here rather
    // than widen a type other modules own.
    private enum CodingKeys: String, CodingKey { case organizationUuid, fetchedAt, fiveHour, sevenDay, weeklyScoped, weeklyScopedModel, scopedFetchedAt }
    private struct Window: Codable { let usedPercentage: Double; let resetsAt: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func window(_ key: CodingKeys) throws -> CapturedWindow? {
            try c.decodeIfPresent(Window.self, forKey: key).map { CapturedWindow(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
        }
        self.init(organizationUuid: try c.decode(String.self, forKey: .organizationUuid),
                  fetchedAt: try c.decode(Date.self, forKey: .fetchedAt),
                  fiveHour: try window(.fiveHour), sevenDay: try window(.sevenDay),
                  weeklyScoped: try window(.weeklyScoped),
                  weeklyScopedModel: try c.decodeIfPresent(String.self, forKey: .weeklyScopedModel),
                  scopedFetchedAt: try c.decodeIfPresent(Date.self, forKey: .scopedFetchedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(organizationUuid, forKey: .organizationUuid)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(fiveHour.map { Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay.map { Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }, forKey: .sevenDay)
        try c.encodeIfPresent(weeklyScoped.map { Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }, forKey: .weeklyScoped)
        try c.encodeIfPresent(weeklyScopedModel, forKey: .weeklyScopedModel)
        try c.encodeIfPresent(scopedFetchedAt, forKey: .scopedFetchedAt)
    }
}
