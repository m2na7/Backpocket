import Testing

@testable import BackpocketKit

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
