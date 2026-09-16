import Foundation
import GroveCore

public enum Severity: Sendable, Equatable { case ok, warning, critical }

/// What one ear shows: a used-percentage, an optional model initial (right ear
/// only, when the model-scoped weekly window is the stricter one) and flags.
public struct EarReadout: Sendable, Equatable {
    public let usedPercentage: Double
    public let modelInitial: String?
    public let severity: Severity
    public let stale: Bool
}

/// Tier-weighted aggregate over the visible accounts, computed the same way
/// Grove's "Overall" is (`RateLimitModel.aggregateRemaining`), expressed as used %.
public struct LimitsAggregate: Sendable, Equatable {
    public let fiveHour: Double
    public let weekly: Double
    public let weeklyScoped: ScopedWeekly?
    public let stale: Bool
    public let leftEar: EarReadout
    public let rightEar: EarReadout

    public struct ScopedWeekly: Sendable, Equatable {
        public let percentage: Double
        public let model: String
    }

    public static func severity(_ used: Double) -> Severity {
        used >= 90 ? .critical : used >= 70 ? .warning : .ok
    }

    public static func compute(accounts: [DiscoveredAccount], snapshots: [String: LimitSnapshot],
                               now: Date) -> LimitsAggregate {
        func used(_ pick: (LimitSnapshot) -> CapturedWindow?, onlyIfPresent: Bool) -> Double? {
            var contributors: [RateLimitModel.AccountWindow] = []
            for account in accounts {
                let window = snapshots[account.organizationUuid].flatMap(pick)
                if window == nil && onlyIfPresent { continue }
                contributors.append(.init(tier: account.tier, usedPercentage: window?.usedPercentage ?? 0))
            }
            guard !contributors.isEmpty else { return onlyIfPresent ? nil : 0 }
            return 100 * (1 - RateLimitModel.aggregateRemaining(contributors).fraction)
        }
        let five = used({ $0.fiveHour }, onlyIfPresent: false) ?? 0
        let weekly = used({ $0.sevenDay }, onlyIfPresent: false) ?? 0
        var scoped: ScopedWeekly?
        if let pct = used({ $0.weeklyScoped }, onlyIfPresent: true) {
            let newest = accounts.compactMap { snapshots[$0.organizationUuid] }
                .filter { $0.weeklyScoped != nil && $0.weeklyScopedModel != nil }
                .max { $0.fetchedAt < $1.fetchedAt }
            scoped = ScopedWeekly(percentage: pct, model: newest?.weeklyScopedModel ?? "Model")
        }
        let stale = accounts.isEmpty || accounts.contains { account in
            guard let snap = snapshots[account.organizationUuid] else { return true }
            return snap.isStale(now: now)
        }
        let left = EarReadout(usedPercentage: five, modelInitial: nil, severity: severity(five), stale: stale)
        let right: EarReadout
        if let scoped, scoped.percentage > weekly {
            right = EarReadout(usedPercentage: scoped.percentage, modelInitial: scoped.model.first.map(String.init),
                               severity: severity(scoped.percentage), stale: stale)
        } else {
            right = EarReadout(usedPercentage: weekly, modelInitial: nil, severity: severity(weekly), stale: stale)
        }
        return LimitsAggregate(fiveHour: five, weekly: weekly, weeklyScoped: scoped, stale: stale,
                               leftEar: left, rightEar: right)
    }
}
