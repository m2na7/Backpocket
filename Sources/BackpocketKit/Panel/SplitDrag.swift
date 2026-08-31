import CoreGraphics

/// How much of the panel's width the notes column takes, and the arithmetic of
/// dragging the divider that sets it.
///
/// Stored as a fraction so the split survives a resize, but rendered in points
/// with a floor under each column, so the two can disagree — and every bug
/// this type has had came from mixing them up. A value type with no SwiftUI:
/// the drag is pure arithmetic, and it was the one piece of the panel that
/// could only be checked by dragging a divider by hand.
struct SplitDrag: Equatable {
    /// The user's setting, as last persisted.
    private(set) var stored: CGFloat
    /// The live value while the divider is being dragged, so the divider
    /// tracks the pointer without writing a preference per frame.
    private(set) var dragging: CGFloat?
    /// The rendered split the current drag started from.
    private(set) var startFraction: CGFloat?

    init(fraction: CGFloat) {
        stored = fraction
    }

    /// The notes column's width in points.
    func width(in total: CGFloat) -> CGFloat {
        let fraction = dragging ?? stored
        // The fraction is what the user set, but both columns keep a floor in
        // points: shrinking the window must never squeeze one of them away.
        let ceiling = max(total - PanelMetrics.minLeftColumn, PanelMetrics.minNotesColumn)
        return min(max((total * fraction).rounded(), PanelMetrics.minNotesColumn), ceiling)
    }

    /// One frame of the drag. `translation` is the gesture's own, which is
    /// cumulative from the press rather than per-frame.
    mutating func drag(translation: CGFloat, in total: CGFloat) {
        guard total > 0 else { return }
        // The press rebases on the split as RENDERED, not as stored: width()
        // clamps the stored fraction to the column floors, and at a narrow
        // panel the two can be far apart — the divider would then ignore the
        // first stretch of travel and jump.
        let base = startFraction ?? width(in: total) / total
        startFraction = base
        // translation is cumulative from the press, so it is applied to the
        // fraction AT the press. Rebasing on the running value would re-add
        // the whole travel every frame and pin the divider to a clamp.
        // The stored range is widened to admit the base: clamping a rendered
        // split that sits outside it would kill the drag in one direction
        // outright.
        dragging = min(
            max(
                base - translation / total,
                min(NotesFraction.range.lowerBound, base)),
            max(NotesFraction.range.upperBound, base)
        )
    }

    /// The drag ended. Returns the fraction to persist, if the divider moved
    /// at all; the caller writes it out and hands back what actually landed,
    /// since storing it clamps.
    mutating func end() -> CGFloat? {
        let dragged = dragging
        startFraction = nil
        dragging = nil
        return dragged
    }

    /// Adopts a fraction from the preference — a fresh panel show, or the
    /// value that came back from storing a finished drag.
    mutating func settle(at fraction: CGFloat) {
        stored = fraction
        dragging = nil
        startFraction = nil
    }
}
