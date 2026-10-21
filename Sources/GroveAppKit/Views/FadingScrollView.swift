// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// A panel's scrolling part: a soft 14 pt fade at the top once it has scrolled, a 22 pt
/// fade at the bottom while there is more, and the system's overlay indicator. Offscreen,
/// where ImageRenderer draws no ScrollView, the content is clipped at `renderOffset`, and
/// the indicator is drawn only for a scrolled picture: macOS shows it while scrolling and
/// hides it at rest, where the bottom fade alone says there is more.
public struct FadingScrollView<Content: View>: View {
    var renderOffset: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.renderScrollOffset) private var environmentOffset
    @State private var scroll = ScrollState()

    public init(renderOffset: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.renderOffset = renderOffset
        self.content = content
    }

    struct ScrollState: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
        var above: Bool { offset > 0.5 }
        var below: Bool { offset + container < content - 0.5 }
    }

    public var body: some View {
        if isSnapshotRender {
            rendered
        } else {
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                            container: geometry.containerSize.height)
            } action: { _, new in
                if new != scroll { scroll = new }
            }
            .mask(Self.fades(above: scroll.above, below: scroll.below))
        }
    }

    private var rendered: some View {
        RenderedScroll(offset: renderOffset + environmentOffset, content: content)
    }

    static func fades(above: Bool, below: Bool) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
        }
    }
}

/// The offscreen stand-in for a scrolled `ScrollView`: the content at its own height, moved up
/// by `offset` — at most to its end — and clipped to the room it is given, with the fades and,
/// once scrolled, a 4 pt indicator. Given no height (a render at its natural size), it is as
/// tall as the content, like an unscrolled stack.
private struct RenderedScroll<Content: View>: View {
    let offset: CGFloat
    let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ViewportLayout(offset: offset) {
            content()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: RenderedHeight.self, value: geo.size.height)
                })
        }
        .clipped()
        .mask(GeometryReader { geo in
            let shown = scrolled(viewport: geo.size.height)
            FadingScrollView<EmptyView>.fades(above: shown > 0.5, below: shown + geo.size.height < height - 0.5)
        })
        .overlay(alignment: .topTrailing) {
            GeometryReader { geo in indicator(viewport: geo.size.height, width: geo.size.width) }
        }
        .onPreferenceChange(RenderedHeight.self) { height = $0 }
    }

    /// How far the content shows scrolled in `viewport`: `offset`, but never past its end.
    private func scrolled(viewport: CGFloat) -> CGFloat {
        min(offset, max(0, height - viewport))
    }

    @ViewBuilder
    private func indicator(viewport: CGFloat, width: CGFloat) -> some View {
        if height > viewport + 1, offset > 0 {
            let track = viewport - 8
            let thumb = max(28, track * viewport / height)
            let y = 4 + (track - thumb) * min(1, scrolled(viewport: viewport) / max(1, height - viewport))
            Capsule().fill(Color.white.opacity(0.38))
                .frame(width: 4, height: thumb)
                .offset(x: width - 6, y: y)
        }
    }
}

/// The content at its own height, placed `offset` up (at most to its end): as tall as the room
/// proposed, or as the content when no (or an unbounded) height is proposed.
private struct ViewportLayout: Layout {
    var offset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? content.sizeThatFits(.unspecified).width
        let natural = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let room = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: width, height: room ?? natural)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let natural = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let shown = min(offset, max(0, natural - bounds.height))
        content.place(at: CGPoint(x: bounds.minX, y: bounds.minY - shown), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The height of a rendered scroll's content.
private struct RenderedHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct RenderScrollOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Offscreen renders of a scrolled screen: how far its `FadingScrollView` is scrolled.
    public var renderScrollOffset: CGFloat {
        get { self[RenderScrollOffsetKey.self] }
        set { self[RenderScrollOffsetKey.self] = newValue }
    }
}
