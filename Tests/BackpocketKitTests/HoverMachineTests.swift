import AppKit
import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// The keyboard-holds-hover arbitration. Several user-visible bugs came out of
/// this — the pointer stealing the highlight back while arrowing, a hover
/// replayed onto a row the pointer was nowhere near after the panel moved — so
/// each rule is pinned at its boundary rather than sampled.
@MainActor
@Suite("HoverMachine")
struct HoverMachineTests {
    private let container: ModelContainer
    private let first: PersistentIdentifier
    private let second: PersistentIdentifier

    /// Real identifiers: the machine stores what the rows hand it, and a
    /// PersistentIdentifier only exists for a model a context knows about.
    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        let context = ModelContext(container)
        let a = Item(content: "first")
        let b = Item(content: "second")
        context.insert(a)
        context.insert(b)
        first = a.persistentModelID
        second = b.persistentModelID
    }

    private let origin = NSPoint(x: 100, y: 100)

    @Test func afreshMachineHonorsEntriesAndTracksTheRowUnderThePointer() {
        var hover = HoverMachine()

        #expect(hover.accepts)
        let accepted = hover.enter(first, in: .clips)
        #expect(accepted)
        #expect(hover.hovered == first)

        let moved = hover.enter(second, in: .clips)
        #expect(moved)
        #expect(hover.hovered == second)
    }

    @Test func theKeyboardTakingOverDropsTheHighlightAndHoldsFurtherEntries() {
        var hover = HoverMachine()
        hover.enter(first, in: .clips)

        hover.suppress(at: origin)

        // A keystroke re-lays the list out under a stationary pointer, and the
        // rows sliding underneath fire entry. Honoring them would yank the
        // highlight straight back off the keyboard's selection.
        #expect(hover.hovered == nil)
        #expect(!hover.accepts)

        let accepted = hover.enter(second, in: .clips)
        #expect(accepted == false)
        #expect(hover.hovered == nil)
    }

    @Test func travelAtTheThresholdDoesNotLiftTheHold() {
        for point in [NSPoint(x: 112, y: 100), NSPoint(x: 100, y: 112)] {
            var hover = HoverMachine()
            hover.suppress(at: origin)

            _ = hover.pointerMoved(to: point)

            // Strictly greater than: exactly releaseDistance is still jitter.
            #expect(!hover.accepts)
        }
    }

    @Test func travelJustBelowTheThresholdDoesNotLiftTheHold() {
        var hover = HoverMachine()
        hover.suppress(at: origin)

        _ = hover.pointerMoved(to: NSPoint(x: 111.9, y: 111.9))

        #expect(!hover.accepts)
    }

    @Test func travelPastTheThresholdLiftsTheHoldOnEitherAxis() {
        for point in [NSPoint(x: 112.1, y: 100), NSPoint(x: 100, y: 87.9)] {
            var hover = HoverMachine()
            hover.suppress(at: origin)

            _ = hover.pointerMoved(to: point)

            // Hardware travel is the one thing a re-layout cannot synthesize.
            #expect(hover.accepts)
        }
    }

    @Test func anEntryHeldDuringTheHoldIsReplayedWhenTravelLiftsIt() {
        var hover = HoverMachine()
        hover.suppress(at: origin)
        hover.enter(second, in: .links)

        let replay = hover.pointerMoved(to: NSPoint(x: 300, y: 300))

        // The pointer may already be resting on that row, so no further entry
        // event would ever arrive — discarding it would leave the list with
        // no highlight at all until the pointer crossed a row boundary.
        #expect(replay?.id == second)
        // With links shown in both lists the id names two rows; the replay has
        // to land on the one the pointer is actually over.
        #expect(replay?.pane == .links)
    }

    @Test func liftingTheHoldWithNothingHeldReplaysNothing() {
        var hover = HoverMachine()
        hover.suppress(at: origin)

        #expect(hover.pointerMoved(to: NSPoint(x: 300, y: 300)) == nil)
        #expect(hover.accepts)
    }

    @Test func pointerMovementWithoutAHoldChangesNothing() {
        var hover = HoverMachine()
        hover.enter(first, in: .clips)

        let replay = hover.pointerMoved(to: NSPoint(x: 900, y: 900))

        // No anchor to measure against; movement must not disturb a highlight
        // the pointer is legitimately holding.
        #expect(replay == nil)
        #expect(hover.accepts)
        #expect(hover.hovered == first)
    }

    @Test func aClickLiftsTheHoldWithoutAnyTravel() {
        var hover = HoverMachine()
        hover.suppress(at: origin)

        hover.release()

        // Clicking is unambiguous mouse intent even from a pointer that never
        // moved a pixel — waiting for travel would ignore the click.
        #expect(hover.accepts)
        let accepted = hover.enter(first, in: .clips)
        #expect(accepted)
    }

    @Test func onlyTheRowHoldingTheHighlightMayClearIt() {
        var hover = HoverMachine()
        hover.enter(first, in: .clips)

        hover.exit(second)

        // Exits and entries race when the pointer crosses between adjacent
        // rows; a blind clear would blink the row just arrived on.
        #expect(hover.hovered == first)

        hover.exit(first)
        #expect(hover.hovered == nil)
    }

    @Test func aRelayoutDropsTheHighlightAndHeldEntryButNotTheHold() {
        var hover = HoverMachine()
        hover.suppress(at: origin)
        hover.enter(second, in: .clips)

        hover.dropHighlight()

        // Both named rows in a layout that no longer exists. The hold is a
        // separate question — the keyboard still owns the highlight, and
        // clearing the anchor here would let the re-layout's own entry events
        // take it straight back.
        #expect(hover.hovered == nil)
        #expect(!hover.accepts)
        #expect(hover.pointerMoved(to: NSPoint(x: 300, y: 300)) == nil)
    }

    @Test func resetForgetsTheHighlightTheHoldAndTheHeldEntry() {
        var hover = HoverMachine()
        hover.suppress(at: origin)
        hover.enter(second, in: .clips)

        hover.reset()

        // The mouse monitor outlives a panel hide, so an anchor from the
        // previous session is trivially far from wherever the panel is
        // re-summoned: without this the first pointer move would replay a
        // hover onto a row the pointer has never been near.
        #expect(hover.hovered == nil)
        #expect(hover.accepts)
        #expect(hover.pointerMoved(to: NSPoint(x: 900, y: 900)) == nil)
        #expect(hover == HoverMachine())
    }

    @Test func aHeldEntryIsClearedOnceItIsHonored() {
        var hover = HoverMachine()
        hover.suppress(at: origin)
        hover.enter(second, in: .clips)
        hover.release()

        hover.enter(second, in: .clips)

        // Honoring it consumes it: a stale held entry would replay on the
        // next hold-and-travel long after the pointer moved on.
        #expect(hover.pointerMoved(to: NSPoint(x: 900, y: 900)) == nil)
    }
}

/// Which panes Tab can reach. Focusing a pane the user cannot see advertises
/// actions against invisible rows.
@Suite("PaneOrder")
struct PaneOrderTests {
    @Test func clipsAreAlwaysVisible() {
        // With both optional sections off the panel is a single list, and Tab
        // has nowhere else to go.
        #expect(PaneOrder.visible(showsLinks: false, showsNotes: false) == [.clips])
        #expect(PaneOrder.next(after: .clips, showsLinks: false, showsNotes: false) == .clips)
    }

    @Test func eachSectionJoinsTabOrderOnlyWhileItIsOn() {
        #expect(PaneOrder.visible(showsLinks: true, showsNotes: false) == [.clips, .links])
        #expect(PaneOrder.visible(showsLinks: false, showsNotes: true) == [.clips, .notes])
        #expect(
            PaneOrder.visible(showsLinks: true, showsNotes: true) == [.clips, .links, .notes])
    }

    @Test func tabWrapsThroughTheVisiblePanesInOrder() {
        #expect(PaneOrder.next(after: .clips, showsLinks: true, showsNotes: true) == .links)
        #expect(PaneOrder.next(after: .links, showsLinks: true, showsNotes: true) == .notes)
        #expect(PaneOrder.next(after: .notes, showsLinks: true, showsNotes: true) == .clips)
    }

    @Test func tabSkipsASectionThatIsTurnedOff() {
        // The bug this prevents: Tab landing on the links pane while no links
        // section is drawn, so ↩ pastes a row nobody can see.
        #expect(PaneOrder.next(after: .clips, showsLinks: false, showsNotes: true) == .notes)
        #expect(PaneOrder.next(after: .clips, showsLinks: true, showsNotes: false) == .links)
        #expect(PaneOrder.next(after: .links, showsLinks: true, showsNotes: false) == .clips)
    }

    @Test func focusStrandedOnAHiddenPaneFallsBackToClips() {
        // The preference can be turned off while that pane holds focus; the
        // next Tab must recover rather than keep cycling off screen.
        #expect(PaneOrder.next(after: .notes, showsLinks: false, showsNotes: false) == .clips)
        #expect(PaneOrder.next(after: .links, showsLinks: false, showsNotes: true) == .clips)
    }

    @Test func everyVisiblePaneIsReachableByRepeatedTabbing() {
        // A cycle that skipped a pane, or got stuck on one, would strand the
        // keyboard: this walks the full ring for each configuration.
        for showsLinks in [false, true] {
            for showsNotes in [false, true] {
                let panes = PaneOrder.visible(
                    showsLinks: showsLinks, showsNotes: showsNotes)
                var seen: [Pane] = []
                var current = Pane.clips
                for _ in panes {
                    seen.append(current)
                    current = PaneOrder.next(
                        after: current, showsLinks: showsLinks, showsNotes: showsNotes)
                }
                #expect(seen == panes)
                #expect(current == .clips, "the ring must close")
            }
        }
    }
}
