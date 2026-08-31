import CoreGraphics
import Testing

@testable import BackpocketKit

/// The divider drag. Two shipped bugs came out of this arithmetic — the
/// divider ignoring the first stretch of travel and then jumping, and the
/// divider pinning itself to a clamp the moment it moved — and neither was
/// catchable except by dragging a divider by hand.
@Suite("SplitDrag")
struct SplitDragTests {
    /// Wide enough that both column floors leave room to move: 260 + 200 of
    /// 900 still leaves 440 points of travel.
    private let wide: CGFloat = 900

    // MARK: Rendered width

    @Test func theColumnsKeepTheirFloorsHoweverNarrowThePanelGets() {
        let narrow = PanelMetrics.minLeftColumn + PanelMetrics.minNotesColumn

        // A fraction the user set on a wide panel must not squeeze a column
        // away when the window shrinks under it.
        for fraction in [NotesFraction.range.lowerBound, NotesFraction.range.upperBound] {
            let split = SplitDrag(fraction: fraction)
            let width = split.width(in: narrow)
            #expect(width >= PanelMetrics.minNotesColumn)
            #expect(narrow - width >= PanelMetrics.minLeftColumn)
        }
    }

    @Test func theLiveDragValueOverridesTheStoredOne() {
        var split = SplitDrag(fraction: 0.35)
        let before = split.width(in: wide)

        split.drag(translation: -90, in: wide)

        // Live while dragging, stored on release: the divider has to track the
        // pointer without writing a preference on every frame.
        #expect(split.width(in: wide) != before)
        #expect(split.stored == 0.35)
    }

    // MARK: Regression — rebase on the RENDERED split, not the stored one

    @Test func aDragOnAClampedPanelTracksThePointerFromTheFirstPixel() {
        // The bug: width() clamps the stored fraction to the column floors, so
        // at a narrow panel the stored and rendered splits can be far apart.
        // Rebasing on the stored one made the divider ignore the whole gap
        // before moving, then jump.
        let narrow = PanelMetrics.minLeftColumn + PanelMetrics.minNotesColumn + 20
        var split = SplitDrag(fraction: NotesFraction.range.upperBound)
        let rendered = split.width(in: narrow)
        #expect(split.stored * narrow > rendered, "the panel must actually be clamping")

        // Rightwards, away from the ceiling the render is pinned to: the
        // stored fraction sits past it, so a stored-fraction rebase spends the
        // whole gap before the divider budges.
        split.drag(translation: 10, in: narrow)

        // Ten points of travel, ten points of divider — no swallowed gap.
        #expect(abs(split.width(in: narrow) - (rendered - 10)) <= 1)
    }

    // MARK: Regression — translation is cumulative from the press

    @Test func holdingStillAfterADragLeavesTheDividerWhereItIs() {
        var split = SplitDrag(fraction: 0.35)

        split.drag(translation: -60, in: wide)
        let afterFirstFrame = split.width(in: wide)
        // The gesture keeps reporting the same cumulative translation while
        // the pointer rests. Re-adding it every frame was the bug.
        split.drag(translation: -60, in: wide)
        split.drag(translation: -60, in: wide)

        #expect(split.width(in: wide) == afterFirstFrame)
    }

    @Test func aDragBackToThePressPointReturnsTheDividerToWhereItStarted() {
        var split = SplitDrag(fraction: 0.35)
        let before = split.width(in: wide)

        split.drag(translation: -120, in: wide)
        split.drag(translation: -240, in: wide)
        split.drag(translation: 0, in: wide)

        // Cumulative translation means zero is the press point. Under the old
        // running-value rebase the divider had long since pinned to a clamp
        // and could not come back.
        #expect(split.width(in: wide) == before)
    }

    // MARK: Clamping

    @Test func aDragCannotPushTheSplitOutsideTheStoredRange() {
        var split = SplitDrag(fraction: 0.35)

        split.drag(translation: -5_000, in: wide)
        #expect(split.dragging == NotesFraction.range.upperBound)

        split = SplitDrag(fraction: 0.35)
        split.drag(translation: 5_000, in: wide)
        #expect(split.dragging == NotesFraction.range.lowerBound)
    }

    @Test func aSplitThatStartsOutsideTheRangeCanStillBeDraggedBothWays() {
        // The range is widened to admit the base: clamping a rendered split
        // that already sits outside it would kill the drag in one direction
        // outright, and the user could never recover the column.
        let outside = NotesFraction.range.upperBound + 0.1
        // Wide enough that the floors do not clamp the split as well, so the
        // out-of-range fraction really is what gets rendered.
        let roomy: CGFloat = 1_200
        var split = SplitDrag(fraction: outside)
        #expect(split.width(in: roomy) == (outside * roomy).rounded())

        split.drag(translation: -50, in: roomy)
        #expect(split.dragging == outside)

        split = SplitDrag(fraction: outside)
        split.drag(translation: 50, in: roomy)
        #expect(split.dragging! < outside)
    }

    @Test func aZeroWidthPanelIsNotDraggable() {
        var split = SplitDrag(fraction: 0.35)

        // GeometryReader reports zero before the first layout pass; dividing
        // by it would put a NaN in the preference.
        split.drag(translation: -50, in: 0)

        #expect(split.dragging == nil)
    }

    // MARK: Ending a drag

    @Test func releasingHandsBackTheDraggedFractionAndForgetsThePress() {
        var split = SplitDrag(fraction: 0.35)
        split.drag(translation: -90, in: wide)
        let dragged = split.dragging

        #expect(split.end() == dragged)

        // The next press must rebase on the freshly settled split, not on the
        // one the previous drag started from.
        #expect(split.startFraction == nil)
        #expect(split.dragging == nil)
    }

    @Test func releasingWithoutDraggingPersistsNothing() {
        var split = SplitDrag(fraction: 0.35)

        // A click on the divider is still a gesture. Writing the preference
        // here would round-trip the fraction through storage for no reason.
        #expect(split.end() == nil)
        #expect(split.stored == 0.35)
    }

    @Test func settlingAdoptsTheFractionAndDropsAnyLiveDrag() {
        var split = SplitDrag(fraction: 0.35)
        split.drag(translation: -90, in: wide)

        // What a fresh panel show does: the preference is the truth again,
        // and a drag that was somehow still live must not survive a reopen.
        split.settle(at: 0.5)

        #expect(split.stored == 0.5)
        #expect(split.dragging == nil)
        #expect(split.startFraction == nil)
    }
}
