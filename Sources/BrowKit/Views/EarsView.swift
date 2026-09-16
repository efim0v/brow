import SwiftUI

/// The collapsed readouts. Black background so the view disappears into the
/// notch; on a pill (no notch) the same content sits on a dark rounded rect.
public struct EarsView: View {
    let aggregate: LimitsAggregate
    let earWidth: CGFloat
    let hasNotch: Bool

    public init(aggregate: LimitsAggregate, earWidth: CGFloat, hasNotch: Bool) {
        self.aggregate = aggregate
        self.earWidth = earWidth
        self.hasNotch = hasNotch
    }

    public var body: some View {
        HStack(spacing: 0) {
            ear(aggregate.leftEar, leading: true).frame(width: earWidth)
            if hasNotch { Spacer(minLength: 0) }
            ear(aggregate.rightEar, leading: false).frame(width: earWidth)
        }
        // Two fixed-width ears cannot compress, so the padding has to be paid for out
        // of the ear width (NotchGeometry.pillPadding), not added on top of it.
        .padding(.horizontal, hasNotch ? 0 : NotchGeometry.pillPadding)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: hasNotch ? 0 : 12, style: .continuous))
    }

    private func ear(_ r: EarReadout, leading: Bool) -> some View {
        HStack(spacing: 5) {
            if !leading { Spacer(minLength: 0) }
            if leading { dot(r) }
            HStack(spacing: 3) {
                if let initial = r.modelInitial {
                    Text(initial).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text(Formatting.percent(r.usedPercentage))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            if !leading { dot(r) }
            if leading { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 8)
    }

    private func dot(_ r: EarReadout) -> some View {
        Circle().fill(color(for: r)).frame(width: 7, height: 7)
    }

    static func color(for r: EarReadout) -> Color {
        if r.stale { return .gray }
        switch r.severity { case .ok: return .green; case .warning: return .orange; case .critical: return .red }
    }
    private func color(for r: EarReadout) -> Color { Self.color(for: r) }
}
