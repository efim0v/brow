import SwiftUI
import GroveCore

/// "My week": what the panel shows right now, as one picture to paste into a chat or
/// a post. Built only from `store.rows` (the visible accounts) and `store.aggregate`;
/// Brow keeps no history, so there is no chart over the week to draw.
///
/// Nothing that identifies an account goes in. Accounts are "Account 1", "Account 2"
/// in panel order unless `cardShowNames` is on, and then only a name typed in
/// Settings — never `displayName`, which falls back to the email and the folder. The
/// tier is left out too: the percentages are already relative to each plan, so all it
/// would add is what someone pays.
public struct WeekCardModel: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        let title: String
        /// nil: this window has no reading ("—").
        let used: Double?
        /// `Formatting.countdown`, "not started" without a window; empty on the
        /// overall row, which has no single reset.
        let resets: String
        let stale: Bool
    }

    public struct Account: Sendable, Equatable {
        /// nil when the card has one account: there is nothing to tell apart.
        let label: String?
        let lines: [Line]
    }

    /// nil with one account, where it would repeat the account's own numbers.
    let overall: [Line]?
    /// At most `shape.capacity`; the rest are counted in `more`.
    let accounts: [Account]
    let more: Int
    let stamp: String

    public static func make(rows: [AccountRow], aggregate: LimitsAggregate, settings: BrowSettings,
                            shape: CardShape, now: Date, timeZone: TimeZone = .current) -> WeekCardModel {
        let single = rows.count == 1
        let accounts = rows.prefix(shape.capacity).enumerated().map { index, row in
            Account(label: single ? nil : label(for: row, index: index, settings: settings),
                    lines: lines(for: row, now: now))
        }
        var overall: [Line]?
        if rows.count > 1 {
            // The panel's "Overall" line: `—` with no snapshot behind the aggregate,
            // never a fabricated 0 %.
            func stat(_ title: String, _ value: Double) -> Line {
                Line(title: title, used: aggregate.hasData ? value : nil, resets: "", stale: aggregate.stale)
            }
            overall = [stat("5h", aggregate.fiveHour), stat("Weekly", aggregate.weekly)]
            if let scoped = aggregate.weeklyScoped { overall?.append(stat(scoped.model, scoped.percentage)) }
        }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return WeekCardModel(overall: overall, accounts: accounts, more: rows.count - accounts.count,
                             stamp: f.string(from: now))
    }

    /// "Account N" by position in `rows`, or — only with `cardShowNames` on — the name
    /// set in Settings. An account without one stays numbered.
    static func label(for row: AccountRow, index: Int, settings: BrowSettings) -> String {
        if settings.cardShowNames,
           let name = settings.accounts[row.id]?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Account \(index + 1)"
    }

    /// The same three windows `AccountBlockView` draws, greyed by the same rules: the
    /// snapshot's age for 5h and Weekly, the scoped window's own age for the model.
    private static func lines(for row: AccountRow, now: Date) -> [Line] {
        let snapshot = row.snapshot
        func line(_ title: String, _ window: CapturedWindow?, stale: Bool) -> Line {
            Line(title: title, used: window?.usedPercentage,
                 resets: window.map { Formatting.countdown($0.resetsAt, now: now) } ?? "not started",
                 stale: stale)
        }
        let stale = snapshot?.isStale(now: now) ?? true
        var lines = [line("5h", snapshot?.fiveHour, stale: stale),
                     line("Weekly", snapshot?.sevenDay, stale: stale)]
        if let scoped = snapshot?.weeklyScoped {
            lines.append(line(snapshot?.weeklyScopedModel ?? "Model", scoped,
                              stale: snapshot?.isScopedStale(now: now) ?? true))
        }
        return lines
    }
}

extension CardShape {
    /// The card in points; the PNG is drawn at scale 2.
    var points: CGSize {
        switch self {
        case .wide: return CGSize(width: 600, height: 315)
        case .square: return CGSize(width: 540, height: 540)
        }
    }

    /// Accounts drawn; any beyond this are "+N more" in the footer.
    var capacity: Int { 4 }

    /// Wide: one row of columns. Square: one or two accounts stacked, three or four
    /// in a 2 × 2 grid.
    func columns(_ count: Int) -> Int {
        switch self {
        case .wide: return max(1, count)
        case .square: return count <= 2 ? 1 : 2
        }
    }
}

/// The card itself: the expanded notch hanging from the top of a tile in the app
/// icon's grey. Explicit colours throughout — `ImageRenderer` draws without the
/// panel's darkAqua appearance, so `.secondary` would come out dark on black.
struct WeekCardView: View {
    let model: WeekCardModel
    let shape: CardShape

    /// The app icon's tile and its two dots.
    private static let tile = Color(red: 0x7A / 255, green: 0x7B / 255, blue: 0x80 / 255)
    private static let green = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    private static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    private static let margin: CGFloat = 20
    private static let divider = Color.white.opacity(0.15)

    var body: some View {
        let size = shape.points
        VStack(alignment: .leading, spacing: 12) {
            header
            if let overall = model.overall {
                overallRow(overall)
                Self.divider.frame(height: 1)
            }
            accounts
            Spacer(minLength: 0)
            footer
        }
        .padding(EdgeInsets(top: 18, leading: 18 + NotchGeometry.flare, bottom: 16,
                            trailing: 18 + NotchGeometry.flare))
        .frame(width: size.width - 2 * Self.margin, height: size.height - Self.margin, alignment: .top)
        .background(NotchShape(topFlare: NotchGeometry.flare, bottomRadius: NotchGeometry.expandedBottomRadius)
            .fill(Color.black))
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Self.tile)
        // Resolves the severity colours (`EarsView.color`) to the panel's dark variants.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Code usage").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text(model.stamp).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func overallRow(_ lines: [WeekCardModel.Line]) -> some View {
        HStack(spacing: 14) {
            Text("Overall").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.title).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                    Text(line.used.map(Formatting.percent) ?? "—")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(line.used == nil ? Color.gray : color(line))
                }
            }
        }
    }

    @ViewBuilder
    private var accounts: some View {
        if model.accounts.isEmpty {
            Text("No Claude accounts").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
        } else {
            let columns = shape.columns(model.accounts.count)
            let grid = stride(from: 0, to: model.accounts.count, by: columns).map {
                Array(model.accounts[$0..<min($0 + columns, model.accounts.count)])
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(grid.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Self.divider.frame(height: 1) }
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, account in
                            block(account).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        // A short last row keeps the grid's column width.
                        ForEach(row.count..<columns, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
        }
    }

    private func block(_ account: WeekCardModel.Account) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let label = account.label {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            ForEach(Array(account.lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(line.title).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1).frame(width: 40, alignment: .leading)
                        bar(line)
                        Text(line.used.map(Formatting.percent) ?? "—")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                            .frame(width: 34, alignment: .trailing)
                    }
                    Text(line.resets).font(.system(size: 9.5)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
                }
            }
        }
    }

    /// Its own bar, not `AccountBlockView`'s: that one has the panel's widths and
    /// `.secondary` text.
    private func bar(_ line: WeekCardModel.Line) -> some View {
        let used = line.used ?? 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color(line)).frame(width: max(0, geo.size.width * used / 100))
            }
        }
        .frame(height: 6)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if model.more > 0 {
                Text("+\(model.more) more").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Circle().fill(Self.green).frame(width: 5, height: 5)
            Circle().fill(Self.orange).frame(width: 5, height: 5)
            Text("Brow").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.4))
        }
    }

    /// The dots' 70/90 rule, grey when stale.
    private func color(_ line: WeekCardModel.Line) -> Color {
        let used = line.used ?? 0
        return EarsView.color(for: EarReadout(usedPercentage: used, modelInitial: nil,
                                              severity: LimitsAggregate.severity(used), stale: line.stale))
    }
}
