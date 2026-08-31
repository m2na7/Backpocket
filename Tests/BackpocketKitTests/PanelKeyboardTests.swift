import Testing

@testable import BackpocketKit

/// The panel's whole keyboard, one combination at a time.
///
/// This dispatcher used to be seventy lines inside a SwiftUI view, so none of
/// it was reachable from a test: the keys that go wrong are the ones where a
/// modifier or a piece of state changes what a key means, and every case
/// below names the mistake it catches rather than restating the table.
@Suite("PanelKeyboard")
struct PanelKeyboardTests {

    private func command(
        _ key: PanelKeyPress.Key,
        command: Bool = false,
        shift: Bool = false,
        isRepeat: Bool = false,
        shortcut: PanelShortcut? = nil,
        _ context: PanelKeyContext = PanelKeyContext()
    ) -> PanelCommand {
        PanelKeyboard.command(
            for: PanelKeyPress(
                key: key, isRepeat: isRepeat, command: command, shift: shift, shortcut: shortcut),
            in: context
        )
    }

    // MARK: Auto-repeat

    @Suite("Auto-repeat")
    struct Repeats {
        private let tests = PanelKeyboardTests()

        @Test func arrowsWalkTheListWhileHeld() {
            #expect(tests.command(.upArrow, isRepeat: true) == .move(-1))
            #expect(tests.command(.downArrow, isRepeat: true) == .move(1))
        }

        @Test(arguments: [
            PanelKeyPress.Key.tab, .escape, .return, .character("1"),
        ])
        func everyOtherKeyIsDroppedWhileHeld(key: PanelKeyPress.Key) {
            // A held ↩ or ⌘E would otherwise fire its action once per repeat
            // event: pasting the same clip a dozen times, or stacking a dozen
            // editor windows, off a single press the user thought was one key.
            #expect(
                tests.command(
                    key, command: true, isRepeat: true, shortcut: .edit,
                    PanelKeyContext(hasSelection: true)
                ) == .unhandled
            )
        }

        @Test func theArrowsOutrankEverythingElseIncludingModifiers() {
            // The arrows are checked before the repeat guard and before any
            // modifier is consulted, so ⌘↓ still moves rather than falling
            // through to a slot or a shortcut.
            #expect(tests.command(.downArrow, command: true, shift: true) == .move(1))
        }
    }

    // MARK: Escape

    @Suite("Escape")
    struct Escape {
        private let tests = PanelKeyboardTests()

        @Test func aCollectedHandfulIsDroppedBeforeAnythingElse() {
            // Escape with a handful must not close the panel: the user's picks
            // would go with it and there is no way to get them back.
            for pane in [Pane.clips, .links, .notes] {
                #expect(
                    tests.command(.escape, PanelKeyContext(pane: pane, stackIsEmpty: false))
                        == .clearStack
                )
            }
        }

        @Test func escapeBacksOutToClipsBeforeItCloses() {
            // Tabbing into notes and hitting escape once must not lose the
            // panel — one press returns to clips, the next closes.
            #expect(tests.command(.escape, PanelKeyContext(pane: .notes)) == .focusClips)
            #expect(tests.command(.escape, PanelKeyContext(pane: .links)) == .focusClips)
            #expect(tests.command(.escape, PanelKeyContext(pane: .clips)) == .close)
        }
    }

    // MARK: Return

    @Suite("Return")
    struct Return {
        private let tests = PanelKeyboardTests()

        @Test func shiftReturnIsLeftToTheFieldSoAMultiLineNoteCanBeTyped() {
            #expect(
                tests.command(
                    .return, shift: true, PanelKeyContext(hasQuery: true, hasSelection: true)
                ) == .unhandled
            )
        }

        @Test func aCollectedHandfulOwnsPlainReturn() {
            // The footer advertises "paste N", so ↩ must not paste the single
            // selected row instead of the handful the user assembled.
            #expect(
                tests.command(
                    .return, PanelKeyContext(hasSelection: true, stackIsEmpty: false)
                ) == .pasteStack
            )
        }

        @Test func commandReturnIgnoresTheHandfulAndKeepsItsOwnMeaning() {
            // Only plain ↩ is taken over; ⌘↩ still saves what was typed rather
            // than pasting the handful out from under it.
            #expect(
                tests.command(
                    .return, command: true,
                    PanelKeyContext(hasQuery: true, hasSelection: true, stackIsEmpty: false)
                ) == .saveNote
            )
        }

        @Test func typedTextThatMatchesNothingBecomesANote() {
            #expect(
                tests.command(.return, PanelKeyContext(hasQuery: true, hasMatches: false))
                    == .saveNote
            )
        }

        @Test func commandReturnOnAClipWithAnEmptyFieldDoesNothing() {
            // This used to convert the selected clip into a note. Dropping it
            // must not leave the resolver reaching .saveNote with no text —
            // that would save a blank note on every ⌘↩.
            #expect(
                tests.command(
                    .return, command: true, PanelKeyContext(hasMatches: true, hasSelection: true)
                ) == .consumed
            )
        }

        @Test func returnWithNothingToDoIsSwallowedRatherThanPassedOn() {
            // .consumed, not .unhandled: letting the field see ⌘↩ inserts a
            // newline into what the user thinks is a search box.
            #expect(tests.command(.return, command: true, PanelKeyContext()) == .consumed)
            #expect(tests.command(.return, PanelKeyContext()) == .consumed)
        }

        @Test func plainReturnInNotesEditsAndCommandReturnPastes() {
            let context = PanelKeyContext(pane: .notes, hasMatches: true, hasSelection: true)
            #expect(tests.command(.return, context) == .edit)
            #expect(tests.command(.return, command: true, context) == .pasteSelection)
        }

        @Test func plainReturnInClipsPastesAndInLinksBehavesIdentically() {
            for pane in [Pane.clips, .links] {
                #expect(
                    tests.command(
                        .return, PanelKeyContext(pane: pane, hasMatches: true, hasSelection: true)
                    ) == .pasteSelection
                )
            }
        }
    }

    // MARK: Note saving with the notes column hidden

    @Suite("Hidden notes column")
    struct HiddenNotes {
        private let tests = PanelKeyboardTests()

        @Test func savingANoteIsOffWhenThereIsNowhereForItToLand() {
            // Silently writing a note into a column the user cannot see is
            // worse than doing nothing: the text vanishes from the field with
            // no visible result.
            let hidden = PanelKeyContext(hasQuery: true, showsNotes: false)
            #expect(PanelKeyboard.resolvedAction(command: false, in: hidden) == .none)
            #expect(tests.command(.return, hidden) == .consumed)

            var shown = hidden
            shown.showsNotes = true
            #expect(PanelKeyboard.resolvedAction(command: false, in: shown) == .saveNote)
            #expect(tests.command(.return, shown) == .saveNote)
        }

        @Test func hidingTheColumnDoesNotSuppressPasting() {
            // The gate is on note saving alone — a hidden notes column must
            // not make ↩ dead over the clips list.
            let context = PanelKeyContext(hasMatches: true, hasSelection: true, showsNotes: false)
            #expect(tests.command(.return, context) == .pasteSelection)
        }
    }

    // MARK: Paste slots

    @Suite("Command 1-9")
    struct Slots {
        private let tests = PanelKeyboardTests()

        @Test func slotsCountFromOneButIndexFromZero() {
            // The off-by-one that pastes the row below the one the badge
            // names: ⌘1 is the first visible row of the focused pane.
            #expect(tests.command(.character("1"), command: true) == .pasteSlot(0))
            #expect(tests.command(.character("9"), command: true) == .pasteSlot(8))
        }

        @Test func zeroIsNotASlot() {
            // wholeNumberValue happily returns 0, and .pasteSlot(-1) would
            // index off the front of the list.
            #expect(tests.command(.character("0"), command: true) == .unhandled)
        }

        @Test func digitsWithoutCommandAreTypedIntoTheField() {
            // Searching for "2024" must not paste rows two, zero, two, four.
            for digit in "0123456789" {
                #expect(tests.command(.character(digit)) == .unhandled)
            }
        }
    }

    // MARK: Rebindable shortcuts

    @Suite("Shortcuts")
    struct Shortcuts {
        private let tests = PanelKeyboardTests()

        @Test func deleteTargetsTheHandfulOnlyWhileOneIsCollected() {
            // With picks collected ⌫ must clear all of them in one write; with
            // none it falls back to the single highlighted row.
            #expect(
                tests.command(.character("\u{7F}"), command: true, shortcut: .delete)
                    == .deleteSelection
            )
            #expect(
                tests.command(
                    .character("\u{7F}"), command: true, shortcut: .delete,
                    PanelKeyContext(stackIsEmpty: false)
                ) == .deleteStack
            )
        }

        @Test func eachShortcutMapsToItsOwnCommand() {
            #expect(tests.command(.character("e"), command: true, shortcut: .edit) == .edit)
            #expect(tests.command(.character("p"), command: true, shortcut: .pin) == .togglePin)
            #expect(tests.command(.character("d"), command: true, shortcut: .stack) == .toggleStack)
            #expect(
                tests.command(.character("o"), command: true, shortcut: .openLink) == .openLink)
        }

        @Test func aMatchedShortcutOutranksASlotOrSettings() {
            // Reserved combinations make this unreachable today, but a
            // shortcut rebound to ⌘⇧1 still has to win over the slot check
            // below it rather than pasting row one.
            #expect(
                tests.command(.character("1"), command: true, shift: true, shortcut: .stack)
                    == .toggleStack
            )
            #expect(
                tests.command(.character(","), command: true, shortcut: .pin) == .togglePin
            )
        }

        @Test func aStructuralKeyIsNeverHandedToAShortcut() {
            // ⇥, esc and ↩ are the panel's grammar. Even if a shortcut were
            // somehow matched against one, the structural branch runs first.
            #expect(tests.command(.tab, command: true, shortcut: .edit) == .switchPane)
            #expect(tests.command(.escape, command: true, shortcut: .edit) == .close)
            #expect(
                tests.command(
                    .return, command: true, shortcut: .edit,
                    PanelKeyContext(pane: .notes, hasMatches: true, hasSelection: true)
                ) == .pasteSelection
            )
        }
    }

    // MARK: The rest

    @Suite("Structural keys")
    struct Structural {
        private let tests = PanelKeyboardTests()

        @Test func tabSwitchesPaneFromAnyPane() {
            // Which pane it lands on is PaneOrder's decision, not this one's:
            // the dispatcher must not second-guess it with a visibility check
            // of its own.
            for pane in [Pane.clips, .links, .notes] {
                #expect(tests.command(.tab, PanelKeyContext(pane: pane)) == .switchPane)
            }
        }

        @Test func commandCommaOpensSettingsAndAPlainCommaIsTyped() {
            #expect(tests.command(.character(","), command: true) == .openSettings)
            #expect(tests.command(.character(",")) == .unhandled)
        }

        @Test func ordinaryTypingFallsThroughToTheField() {
            // The field is the search box and the note box both; anything the
            // panel has no meaning for has to reach it untouched.
            for character in "abcXYZ .!/" {
                #expect(tests.command(.character(character)) == .unhandled)
            }
        }

        @Test func anUnboundCommandLetterIsNotSwallowed() {
            // Returning .handled here would eat ⌘A, ⌘C and ⌘V inside the
            // field: select-all, copy and paste would all stop working.
            for character in "acvxz" {
                #expect(tests.command(.character(character), command: true) == .unhandled)
            }
        }
    }
}

/// Which row an action aims at, and which row may grow a preview card.
@Suite("PanelTargeting")
struct PanelTargetingTests {
    @Test func theHoveredRowWinsOverTheKeyboardSelection() {
        // Two rows can look lit at once — the pointer's and the focused pane's
        // remembered one. ⌘⌫ hitting the row behind the pointer deletes
        // something the user was not looking at.
        #expect(PanelTargeting.actionTarget(hovered: "hovered", selected: "selected") == "hovered")
        #expect(PanelTargeting.actionTarget(hovered: nil, selected: "selected") == "selected")
        #expect(PanelTargeting.actionTarget(hovered: String?.none, selected: nil) == nil)
    }

    @Test func anAutomaticSelectionNeverGrowsAPreviewCard() {
        // Typing re-selects the top row on every keystroke. Dwelling on that
        // would pop a card over the list while the user is still searching.
        #expect(
            PanelTargeting.dwellTarget(
                hovered: nil, selected: "selected", selectionIsAutomatic: true) == nil
        )
        #expect(
            PanelTargeting.dwellTarget(
                hovered: nil, selected: "selected", selectionIsAutomatic: false) == "selected"
        )
    }

    @Test func hoveringDwellsEvenWhileTheSelectionIsAutomatic() {
        // The pointer resting on a row is always deliberate, whatever put the
        // keyboard selection where it is.
        #expect(
            PanelTargeting.dwellTarget(
                hovered: "hovered", selected: "selected", selectionIsAutomatic: true) == "hovered"
        )
    }
}
