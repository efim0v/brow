import Foundation
import Combine

/// Which calendar day the pointer is over, decided from the controller's own global
/// mouse monitor rather than SwiftUI's `onHover`. Brow is a non-activating agent and
/// its panel can never become key, and hover tracking areas only fire for the active
/// app — so `onHover` fired for no cell at all (a sweep down the grid logged zero
/// callbacks) except by luck. The cells report their frames in the hosting view's
/// space; `update(pointer:)` hit-tests and publishes only when the day changes.
@MainActor
public final class CalendarHoverTracker: ObservableObject {
    @Published public private(set) var hoveredDay: Date?
    /// Day (its start) → frame in the hosting view's coordinate space. Not published:
    /// a layout pass must not re-render the calendar.
    var frames: [Date: CGRect] = [:]

    nonisolated public init() {}

    /// `pointer` in the hosting view's space (origin top-left), nil when it left the panel.
    public func update(pointer: CGPoint?) {
        let day = pointer.flatMap { p in frames.first { $0.value.contains(p) }?.key }
        if day != hoveredDay { hoveredDay = day }
    }
}
