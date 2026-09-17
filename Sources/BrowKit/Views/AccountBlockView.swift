import SwiftUI
import GroveCore

/// One account: header line + up to three bars (5h, weekly, model weekly).
///
/// The header carries the two things the owner asked to have IN the panel, not in
/// Settings: copy the command that runs Claude Code as this account, and open a
/// Terminal already running it.
public struct AccountBlockView: View {
    let row: AccountRow
    let now: Date
    let claudePath: String
    @State private var copied = false

    public init(row: AccountRow, now: Date, claudePath: String = "claude") {
        self.row = row
        self.now = now
        self.claudePath = claudePath
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(tag).font(.system(size: 10)).foregroundStyle(tagColor).lineLimit(1)
                actions
            }
            bar("5h", row.snapshot?.fiveHour)
            bar("Weekly", row.snapshot?.sevenDay)
            if let scoped = row.snapshot?.weeklyScoped {
                bar(row.snapshot?.weeklyScopedModel ?? "Model", scoped)
            }
        }
    }

    /// Copy the launch command (a checkmark for a second confirms it), or open it in
    /// Terminal. Small, borderless, and right where the account is.
    private var actions: some View {
        let command = AddAccountFlow.launchCommand(dir: row.account.configDir)
        return HStack(spacing: 2) {
            Button {
                AddAccountFlow.copyToPasteboard(command)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy: \(command)")
            // Sign in again, in this account's own browser profile. Orange when the
            // server has rejected the token — that is the moment this button exists for.
            Button {
                AddAccountFlow.login(dir: row.account.configDir, claudePath: claudePath)
            } label: {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 11)).foregroundStyle(needsLogin ? Color.orange : Color.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sign in again (opens this account's own browser profile)")
            // Just the browser, as this account: claude.ai in the profile that holds
            // its Google/claude.ai session — no Terminal, no sign-in flow.
            Button {
                _ = AddAccountFlow.openBrowserProfile(dir: row.account.configDir)
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open claude.ai in this account's own browser profile")
        }
    }

    private var needsLogin: Bool {
        if case .error(let text) = row.status, text.contains("sign-in") { return true }
        return row.tokenStatus.contains("revoked") || row.tokenStatus.contains("no token")
    }

    private var tag: String {
        PanelText.accountTag(tier: row.account.tier, snapshot: row.snapshot, status: row.status, now: now)
    }
    private var tagColor: Color {
        switch row.status { case .ok: return .secondary; case .stale: return .secondary; case .error: return .orange }
    }

    /// A row whose snapshot is past `staleAfter` shows grey bars, the same signal the
    /// ears carry; the age itself is already in the tag. Asking the SNAPSHOT, not the
    /// status: `.error` outranks `.stale` in `LimitsStore.row(for:)`, so a failed fetch
    /// over a three-day-old capture used to paint it confident green.
    private var isStale: Bool { row.snapshot?.isStale(now: now) ?? true }

    private func bar(_ title: String, _ window: CapturedWindow?) -> some View {
        let used = window?.usedPercentage ?? 0
        let stale = isStale
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(EarsView.color(for: EarReadout(usedPercentage: used, modelInitial: nil,
                                                                 severity: LimitsAggregate.severity(used), stale: stale)))
                        .frame(width: max(0, geo.size.width * used / 100))
                }
            }
            .frame(height: 6)
            Text(window.map { Formatting.percent($0.usedPercentage) } ?? "—")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 36, alignment: .trailing)
            Text(window.map { Formatting.countdown($0.resetsAt, now: now) } ?? "not started")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).lineLimit(1)
        }
    }
}
