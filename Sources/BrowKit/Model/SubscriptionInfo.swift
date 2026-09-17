import Foundation
import GroveCore

/// The billing facts `api/oauth/profile` gives for one organisation, dated by the
/// fetch. Persisted beside the snapshots and refreshed about once a day.
public struct SubscriptionInfo: Codable, Sendable, Equatable {
    public let organizationUuid: String
    public let status: String?
    public let billingType: String?
    public let createdAt: Date?
    public let fetchedAt: Date

    public init(organizationUuid: String, status: String?, billingType: String?, createdAt: Date?, fetchedAt: Date) {
        self.organizationUuid = organizationUuid
        self.status = status
        self.billingType = billingType
        self.createdAt = createdAt
        self.fetchedAt = fetchedAt
    }

    public init(organizationUuid: String, profile: OAuthProfile, fetchedAt: Date) {
        self.init(organizationUuid: organizationUuid, status: profile.subscriptionStatus,
                  billingType: profile.billingType, createdAt: profile.subscriptionCreatedAt, fetchedAt: fetchedAt)
    }

    /// Stripe bills on the anniversary of the subscription's start, so the next
    /// renewal is the first monthly anniversary after `now` — in UTC, where Stripe keeps
    /// its clock. An ESTIMATE: a plan change or a yearly plan moves the real date, and
    /// the endpoint does not say. nil for anything that is not an active Stripe
    /// subscription.
    public func nextRenewal(after now: Date) -> Date? {
        guard billingType == "stripe_subscription", status == "active", let createdAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for months in 1...120 {
            guard let date = calendar.date(byAdding: .month, value: months, to: createdAt) else { return nil }
            if date > now { return date }
        }
        return nil
    }
}
