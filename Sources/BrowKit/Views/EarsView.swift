import SwiftUI

/// The collapsed readouts, drawn on the notch outline itself.
///
/// The whole frame is `NotchShape` in black — flared where it meets the screen edge,
/// rounded at the bottom — so the strip reads as the notch growing rather than a bar
/// stuck over the menu bar. Where the readouts sit inside it is `frames.placement`:
///
/// - `beside`: the two wings on either side of the notch, vertically centred, with the
///   notch-wide middle left empty (there is a camera behind it).
/// - `below`: one centred row in the `belowStripHeight` strip under the notch; the
///   notch's own height stays empty for the same reason.
/// - no notch (external display): the 180 × 24 pt pill, square-cornered and rounded,
///   with no flare to draw.
public struct EarsView: View {
    let aggregate: LimitsAggregate
    let frames: NotchFrames
    /// `NotchRootView` draws ONE black outline that grows on hover and hosts both this
    /// view and the panel inside it; it passes false so the strip does not paint a
    /// second, non-animating outline over the animated one.
    let drawsBackground: Bool

    public init(aggregate: LimitsAggregate, frames: NotchFrames, drawsBackground: Bool = true) {
        self.aggregate = aggregate
        self.frames = frames
        self.drawsBackground = drawsBackground
    }

    public var body: some View {
        content
            // The frame `NotchPanelController` proposes IS the notch, and `.background`
            // paints behind whatever `content` *measures*, not behind the proposal. Without
            // this, the `beside` branch (an HStack of Texts nothing pins to a height) took
            // its intrinsic ~15 pt and was centred, so the black strip was drawn 15 pt tall
            // floating 8.5 pt below the screen edge — the pill the same way. `below` was
            // immune only because its VStack pins both children explicitly.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if drawsBackground { background } }
    }

    @ViewBuilder
    private var content: some View {
        if frames.hasNotch, frames.placement == .below {
            VStack(spacing: 0) {
                // The notch itself: black, and empty.
                Color.clear.frame(height: frames.notchHeight)
                row(outward: false).frame(height: NotchGeometry.belowStripHeight)
            }
            // The flares widen the frame on each side; the readouts belong inside the
            // visible black, not under the bezel.
            .padding(.horizontal, frames.flare)
        } else {
            row(outward: true)
                // Two fixed-width ears cannot compress, so on the pill the padding has to
                // be paid for out of the ear width (NotchGeometry.pillPadding), not added
                // on top of it; with a notch the frame already carries the flares.
                .padding(.horizontal, frames.hasNotch ? frames.flare : NotchGeometry.pillPadding)
        }
    }

    /// `beside` needs the notch-wide gap between the wings; `below` and the pill are
    /// one contiguous row whose two halves meet in the middle.
    private func row(outward: Bool) -> some View {
        HStack(spacing: 0) {
            ear(aggregate.leftEar, leading: true, outward: outward).frame(width: frames.earWidth)
            if frames.hasNotch, frames.placement == .beside { Spacer(minLength: 0) }
            ear(aggregate.rightEar, leading: false, outward: outward).frame(width: frames.earWidth)
        }
    }

    @ViewBuilder
    private var background: some View {
        if frames.hasNotch {
            NotchShape(topFlare: frames.flare, bottomRadius: NotchGeometry.collapsedBottomRadius)
                .fill(Color.black)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
        }
    }

    /// `outward`: the readout hugs the outer edge of its wing, which is what keeps the
    /// notch-wide middle clear in `beside`. Otherwise it hugs the middle, so the two
    /// halves read as the one centred `● 14%   27% ●` row the strip needs.
    private func ear(_ r: EarReadout, leading: Bool, outward: Bool) -> some View {
        let spacerFirst = outward ? !leading : leading
        return HStack(spacing: 5) {
            if spacerFirst { Spacer(minLength: 0) }
            if leading { dot(r) }
            HStack(spacing: 3) {
                if let initial = r.modelInitial {
                    Text(initial).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text(PanelText.earsText(r, hasData: aggregate.hasData))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            if !leading { dot(r) }
            if !spacerFirst { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 8)
    }

    /// Grey next to the `—`: the severity of a reading we do not have is not `.ok`.
    private func dot(_ r: EarReadout) -> some View {
        Circle().fill(aggregate.hasData ? color(for: r) : Color.gray).frame(width: 7, height: 7)
    }

    static func color(for r: EarReadout) -> Color {
        if r.stale { return .gray }
        switch r.severity { case .ok: return .green; case .warning: return .orange; case .critical: return .red }
    }
    private func color(for r: EarReadout) -> Color { Self.color(for: r) }
}
