import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// The one-lit-row invariant, and the "did the user ask for this" question the
/// preview card hangs on. Both used to be spread across a view: a pane field, a
/// selection per pane, and a flag with six writers that nothing could catch
/// being forgotten.
@MainActor
@Suite("PanelSelection")
struct PanelSelectionTests {
    private let container: ModelContainer
    private let ids: [PersistentIdentifier]

    /// Real identifiers: a PersistentIdentifier only exists for a model some
    /// context knows about, and the selection stores exactly what the rows
    /// hand it.
    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        let context = ModelContext(container)
        ids = (0..<6).map { index in
            let item = Item(content: "row \(index)")
            context.insert(item)
            return item.persistentModelID
        }
    }

    /// Three rows in clips, two in links, one in notes — enough for every pane
    /// to hold a distinct selection.
    private var rows: PaneRows {
        PaneRows(
            clips: Array(ids[0...2]),
            links: Array(ids[3...4]),
            notes: [ids[5]]
        )
    }

    private var allPanes: [Pane] { [.clips, .links, .notes] }

    // MARK: The invariant

    @Test func theLitRowAlwaysBelongsToTheFocusedPane() {
        var selection = PanelSelection()
        selection.selectTopRows(in: rows)

        for pane in allPanes {
            selection.focus(pane, in: rows, origin: .user)

            // Every pane keeps its own memory, but `selected` may only ever
            // report the focused one: reading another pane's row here is what
            // made ⌘⌫ delete a row the user was not looking at.
            #expect(selection.pane == pane)
            #expect(selection.selected == selection[pane])
            #expect(rows[pane].contains(selection.selected!))
        }
    }

    @Test func hoveringAnotherPanesRowMovesTheFocusWithTheHighlight() {
        var selection = PanelSelection()
        selection.selectTopRows(in: rows)

        selection.select(ids[3], in: .links, origin: .user)

        // Selecting without focusing left the previous pane's row glowing as a
        // second highlight, and the footer chips aimed at it.
        #expect(selection.pane == .links)
        #expect(selection.selected == ids[3])
    }

    @Test func eachPaneRemembersItsOwnRowAcrossFocusChanges() {
        var selection = PanelSelection()
        selection.select(ids[2], in: .clips, origin: .user)
        selection.select(ids[4], in: .links, origin: .user)

        selection.focus(.clips, in: rows, origin: .user)
        #expect(selection.selected == ids[2])

        // Tab returns the user to the row they left, not to the top of the
        // pane — that is the whole reason the memory is per pane.
        selection.focus(.links, in: rows, origin: .user)
        #expect(selection.selected == ids[4])
    }

    // MARK: Origin — the flag that used to be forgettable

    @Test func aSelectionThatCameFromTheUserStaysUserDriven() {
        var selection = PanelSelection()
        selection.selectTopRows(in: rows)
        #expect(selection.isAutomatic)

        selection.select(ids[1], in: .clips, origin: .user)
        #expect(!selection.isAutomatic)
    }

    @Test func everySelectionSourceThatIsNotTheUserLeavesItAutomatic() {
        // The bug this catches: a preview card popping open on a row the user
        // never aimed at, while they were still typing. Each of these is one
        // of the old flag's writers, checked against the same rule.
        var selection = PanelSelection()

        selection.select(ids[0], in: .clips, origin: .user)
        selection.selectTopRows(in: rows)
        #expect(selection.isAutomatic)

        selection.select(ids[0], in: .clips, origin: .user)
        selection.focus(.links, in: rows, origin: .automatic)
        #expect(selection.isAutomatic)

        selection.select(ids[0], in: .clips, origin: .user)
        selection.reset(to: rows)
        #expect(selection.isAutomatic)

        selection.select(ids[0], in: .clips, origin: .user)
        selection.markAutomatic()
        #expect(selection.isAutomatic)

        selection.select(ids[0], in: .clips, origin: .automatic)
        #expect(selection.isAutomatic)
    }

    @Test func droppingTheUsersClaimLeavesTheHighlightWhereItIs() {
        var selection = PanelSelection()
        selection.select(ids[1], in: .clips, origin: .user)

        selection.markAutomatic()

        // The pointer leaving a row: hover also selects, so the dwell target
        // would fall back to it and the card would never be dismissed. The row
        // itself must stay lit — it is still the one under the pointer's last
        // position, and blanking it would blink the list.
        #expect(selection.selected == ids[1])
        #expect(selection.isAutomatic)
    }

    @Test func aQueryChangeIsAutomaticNoMatterWhichBranchItTakes() {
        // The hazard this replaces: the view ended this sequence with a bare
        // `selectionIsAutomatic = true` that had to come AFTER the focus step,
        // because focus() marked the selection user-driven. Both branches are
        // checked here so no ordering can bring the trap back.
        var selection = PanelSelection()

        // Branch one: the focused pane still has matches, no focus move.
        selection.select(ids[0], in: .clips, origin: .user)
        selection.queryChanged(to: rows, hasQuery: true, visiblePanes: allPanes)
        #expect(selection.pane == .clips)
        #expect(selection.isAutomatic)

        // Branch two: the focused pane emptied, so the focus moves.
        selection.select(ids[5], in: .notes, origin: .user)
        let clipsOnly = PaneRows(clips: Array(ids[0...2]))
        selection.queryChanged(to: clipsOnly, hasQuery: true, visiblePanes: allPanes)
        #expect(selection.pane == .clips)
        #expect(selection.isAutomatic)
    }

    // MARK: Following the matches

    @Test func focusFollowsTheMatchesWhenTheQueryEmptiesTheFocusedPane() {
        var selection = PanelSelection()
        selection.focus(.clips, in: rows, origin: .user)

        let notesOnly = PaneRows(notes: [ids[5]])
        selection.queryChanged(to: notesOnly, hasQuery: true, visiblePanes: allPanes)

        // Enter would otherwise go dead in front of visible results.
        #expect(selection.pane == .notes)
        #expect(selection.selected == ids[5])
    }

    @Test func focusNeverFollowsMatchesIntoAPaneThatIsNotOnScreen() {
        var selection = PanelSelection()
        selection.focus(.clips, in: rows, origin: .user)

        let notesOnly = PaneRows(notes: [ids[5]])
        selection.queryChanged(to: notesOnly, hasQuery: true, visiblePanes: [.clips])

        // With the notes column off, following the only match there would
        // focus an invisible pane and offer Enter to edit a row nobody can see.
        #expect(selection.pane == .clips)
        #expect(selection.selected == nil)
    }

    @Test func anEmptyQueryLeavesTheFocusWhereTheUserPutIt() {
        var selection = PanelSelection()
        selection.focus(.notes, in: rows, origin: .user)

        // Clearing the field shows everything again; the focus jumping to
        // clips because notes happened to be empty mid-edit would be a lurch.
        selection.queryChanged(to: PaneRows(), hasQuery: false, visiblePanes: allPanes)
        #expect(selection.pane == .notes)
    }

    // MARK: Entering a pane

    @Test func focusingAPaneWhoseRememberedRowIsGoneFallsBackToItsTop() {
        var selection = PanelSelection()
        selection.select(ids[4], in: .links, origin: .user)

        // Judged on the row being on screen, not on the id being non-nil: a
        // remembered id can name a row that conversion or deletion moved out
        // of this pane meanwhile.
        let movedOut = PaneRows(clips: Array(ids[0...2]), links: [ids[3]])
        selection.focus(.links, in: movedOut, origin: .user)

        #expect(selection.selected == ids[3])
    }

    @Test func focusingAnEmptyPaneLightsNothingAndScrollsNowhere() {
        var selection = PanelSelection()
        selection.focus(.notes, in: PaneRows(clips: [ids[0]]), origin: .user)

        #expect(selection.selected == nil)
        #expect(selection.scrollTarget == nil)
    }

    @Test func enteringAPaneRevealsTheRowItRemembers() {
        var selection = PanelSelection()
        selection.select(ids[2], in: .clips, origin: .user)
        selection.focus(.notes, in: rows, origin: .user)

        selection.focus(.clips, in: rows, origin: .user)

        // Tabbing back to a selection scrolled off screen must bring it into
        // view; without this the pane looks like it lost the selection.
        #expect(selection.scrollTarget == ids[2])
    }

    // MARK: Arrow keys

    @Test func theFirstArrowPressLandsOnTheTopRowRatherThanSkippingIt() {
        var selection = PanelSelection()
        selection.focus(.clips, in: PaneRows(), origin: .user)
        #expect(selection.selected == nil)

        selection.move(1, in: rows)

        // Treating "no selection" as "row 0" would step straight to row 1.
        #expect(selection.selected == ids[0])
    }

    @Test func arrowsStopAtTheEndsInsteadOfWrapping() {
        var selection = PanelSelection()
        selection.select(ids[0], in: .clips, origin: .user)

        selection.move(-1, in: rows)
        #expect(selection.selected == ids[0])

        for _ in 0..<5 { selection.move(1, in: rows) }
        #expect(selection.selected == ids[2])
    }

    @Test func arrowingReportsWhetherThereWasAnywhereToGo() {
        var selection = PanelSelection()
        selection.focus(.notes, in: PaneRows(), origin: .user)

        // The caller suppresses the pointer's highlight on a real move only.
        // Suppressing it in an empty pane would blank the row the pointer is
        // resting on in the column next door, for a keypress that did nothing.
        #expect(selection.move(1, in: PaneRows()) == false)
        #expect(selection.move(1, in: rows) == true)
    }

    @Test func arrowingInAnEmptyPaneStillCountsAsTheUserAiming() {
        var selection = PanelSelection()
        selection.selectTopRows(in: rows)
        selection.focus(.notes, in: PaneRows(), origin: .user)
        selection.markAutomatic()

        selection.move(1, in: PaneRows())

        // The keypress is intent even when the list has nothing to offer;
        // the next row to appear is one the user asked to be on.
        #expect(!selection.isAutomatic)
    }

    @Test func arrowingRevealsTheRowItLandsOn() {
        var selection = PanelSelection()
        selection.select(ids[0], in: .clips, origin: .user)

        selection.move(1, in: rows)

        #expect(selection.scrollTarget == ids[1])
    }

    @Test func hoveringDoesNotScrollTheListUnderThePointer() {
        var selection = PanelSelection()
        selection.select(ids[0], in: .clips, origin: .user)
        selection.move(1, in: rows)

        selection.select(ids[2], in: .clips, origin: .user)

        // Only keyboard navigation asks the list to scroll. A hover that
        // scrolled would yank the row out from under the pointer and hand the
        // highlight to whatever slid into its place.
        #expect(selection.scrollTarget == ids[1])
    }

    // MARK: Deleting

    @Test func deletingHandsTheHighlightToTheRowBelow() {
        var selection = PanelSelection()
        selection.select(ids[1], in: .clips, origin: .user)

        selection.deleteAdjusting(ids[1], in: .clips, rows: rows)

        // Held ⌘⌫ walks down the list; falling back to the top instead would
        // delete the first row over and over.
        #expect(selection.selected == ids[2])
    }

    @Test func deletingTheLastRowFallsBackToTheTopOfThePane() {
        var selection = PanelSelection()
        selection.select(ids[2], in: .clips, origin: .user)

        selection.deleteAdjusting(ids[2], in: .clips, rows: rows)

        #expect(selection.selected == ids[0])
    }

    @Test func deletingAHoveredRowInAnotherPaneLeavesTheFocusAlone() {
        var selection = PanelSelection()
        selection.select(ids[0], in: .clips, origin: .user)

        // ⌘⌫ hits the row under the pointer wherever it is, but the focused
        // pane must not follow it: the keyboard would silently move house.
        selection.deleteAdjusting(ids[3], in: .links, rows: rows)

        #expect(selection.pane == .clips)
        #expect(selection.selected == ids[0])
        #expect(selection[.links] == ids[4])
    }

    @Test func deletingFromAPaneThatIsNowEmptyLeavesNothingToLand() {
        var selection = PanelSelection()
        selection.select(ids[5], in: .notes, origin: .user)

        // The pane held exactly one row, so both the neighbour and the
        // fallback are gone. The next focus() resolves it against the rows on
        // screen and clears it; leaving it pointing at the deleted row here is
        // what keeps deleteAdjusting from having to know about the store.
        selection.deleteAdjusting(ids[5], in: .notes, rows: rows)
        selection.focus(.notes, in: PaneRows(clips: Array(ids[0...2])), origin: .user)

        #expect(selection.selected == nil)
    }

    // MARK: Opening the panel

    @Test func aFreshShowFocusesClipsAndRewindsEveryPane() {
        var selection = PanelSelection()
        selection.select(ids[5], in: .notes, origin: .user)
        selection.move(1, in: rows)

        selection.reset(to: rows)

        // Reopening on the previous session's pane, with a preview card
        // already growing on the previous session's row, is not a fresh panel.
        #expect(selection.pane == .clips)
        #expect(selection.selected == ids[0])
        #expect(selection[.links] == ids[3])
        #expect(selection[.notes] == ids[5])
        #expect(selection.scrollTarget == ids[0])
        #expect(selection.isAutomatic)
    }
}
