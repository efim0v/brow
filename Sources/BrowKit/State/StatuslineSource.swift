import Foundation
import GroveCore

/// The newest rate-limit reading Claude Code's own statusline left for an account:
/// `<configDir>/grove/usage/<session>.json`, written on every turn of every session
/// that runs as the account. For an account with sessions running it is the freshest
/// number there is — and free — while `api/oauth/usage` for that same token is
/// exactly what those sessions keep draining (one 429 per Brow poll, for hours).
/// No model-scoped window: the statusline never emits one, so Fable stays with the
/// API reading, dated separately.
public struct StatuslineReading: Sendable, Equatable {
    public let capturedAt: Date
    public let fiveHour: CapturedWindow?
    public let sevenDay: CapturedWindow?

    public init(capturedAt: Date, fiveHour: CapturedWindow?, sevenDay: CapturedWindow?) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public protocol StatuslineCaptures: Sendable {
    /// The newest capture with at least one window across the account's dirs.
    func latest(configDirs: [String]) -> StatuslineReading?
}

public struct FileStatuslineCaptures: StatuslineCaptures {
    public init() {}

    public func latest(configDirs: [String]) -> StatuslineReading? {
        var best: StatuslineReading?
        for dir in configDirs {
            for capture in UsageReader().read(configDir: dir, accountName: "") {
                guard let at = capture.capturedAt, capture.fiveHour != nil || capture.sevenDay != nil else { continue }
                if best.map({ at > $0.capturedAt }) ?? true {
                    best = StatuslineReading(capturedAt: at, fiveHour: capture.fiveHour, sevenDay: capture.sevenDay)
                }
            }
        }
        return best
    }
}
