import Testing

@testable import BackpocketKit

@Suite struct EnterActionTests {

    // The resolve cases below are a regression-critical decision table:
    // each one was proven against real UI behavior, so keep them exhaustive
    // rather than collapsing into fewer "representative" checks.
    @Suite struct ClipsPane {
        @Test func plainEnterWithSelectionPastes() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .clips,
                    hasText: true, hasMatches: true, hasSelection: true
                ) == .paste
            )
        }

        @Test func plainEnterWithoutTextWithSelectionPastes() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .clips,
                    hasText: false, hasMatches: false, hasSelection: true
                ) == .paste
            )
        }

        @Test func commandEnterWithTextSavesNote() {
            // hasMatches stays true so the pane branch is exercised,
            // not the cross-pane no-match short-circuit.
            #expect(
                EnterAction.resolve(
                    command: true, pane: .clips,
                    hasText: true, hasMatches: true, hasSelection: true
                ) == .saveNote
            )
        }

        @Test func commandEnterWithoutTextDoesNothingEvenWithASelection() {
            // Converting the selected clip lived here and was dropped; the
            // notes column takes a drag instead. Nothing must fill the gap by
            // saving the empty field.
            #expect(
                EnterAction.resolve(
                    command: true, pane: .clips,
                    hasText: false, hasMatches: true, hasSelection: true
                ) == .none
            )
        }

        @Test func commandEnterWithNothingDoesNothing() {
            #expect(
                EnterAction.resolve(
                    command: true, pane: .clips,
                    hasText: false, hasMatches: false, hasSelection: false
                ) == .none
            )
        }

        @Test func plainEnterWithoutSelectionDoesNothing() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .clips,
                    hasText: true, hasMatches: true, hasSelection: false
                ) == .none
            )
            #expect(
                EnterAction.resolve(
                    command: false, pane: .clips,
                    hasText: false, hasMatches: false, hasSelection: false
                ) == .none
            )
        }
    }

    @Suite struct NotesPane {
        @Test func plainEnterWithSelectionEdits() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .notes,
                    hasText: false, hasMatches: false, hasSelection: true
                ) == .edit
            )
        }

        @Test func commandEnterWithSelectionPastes() {
            #expect(
                EnterAction.resolve(
                    command: true, pane: .notes,
                    hasText: false, hasMatches: false, hasSelection: true
                ) == .paste
            )
        }

        @Test func textWithMatchesAndSelectionEdits() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .notes,
                    hasText: true, hasMatches: true, hasSelection: true
                ) == .edit
            )
        }

        @Test func noSelectionDoesNothing() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .notes,
                    hasText: false, hasMatches: false, hasSelection: false
                ) == .none
            )
            #expect(
                EnterAction.resolve(
                    command: true, pane: .notes,
                    hasText: false, hasMatches: false, hasSelection: false
                ) == .none
            )
        }
    }

    @Suite struct CrossPane {
        @Test(arguments: [Pane.clips, Pane.notes])
        func textWithNoMatchesSavesNoteInEitherPane(pane: Pane) {
            // The no-match short-circuit wins before any pane logic,
            // even with a (stale) selection still present.
            #expect(
                EnterAction.resolve(
                    command: false, pane: pane,
                    hasText: true, hasMatches: false, hasSelection: true
                ) == .saveNote
            )
            #expect(
                EnterAction.resolve(
                    command: false, pane: pane,
                    hasText: true, hasMatches: false, hasSelection: false
                ) == .saveNote
            )
        }

        // Symmetry invariant: plain Enter in clips must equal cmd+Enter in
        // notes for every input combination, so the two panes stay mirrored.
        @Test(arguments: [
            (hasText: false, hasMatches: false, hasSelection: true),
            (hasText: false, hasMatches: false, hasSelection: false),
            (hasText: true, hasMatches: true, hasSelection: true),
            (hasText: true, hasMatches: true, hasSelection: false),
            (hasText: true, hasMatches: false, hasSelection: true),
        ])
        func clipsPlainEnterMirrorsNotesCommandEnter(
            input: (hasText: Bool, hasMatches: Bool, hasSelection: Bool)
        ) {
            let clips = EnterAction.resolve(
                command: false, pane: .clips,
                hasText: input.hasText, hasMatches: input.hasMatches,
                hasSelection: input.hasSelection
            )
            let notes = EnterAction.resolve(
                command: true, pane: .notes,
                hasText: input.hasText, hasMatches: input.hasMatches,
                hasSelection: input.hasSelection
            )
            #expect(clips == notes)

            // Anchored: comparing two results to each other alone would pass
            // just as happily if resolve() returned .none for everything.
            let expected: EnterAction =
                input.hasText && !input.hasMatches
                ? .saveNote : (input.hasSelection ? .paste : EnterAction.none)
            #expect(clips == expected)
        }

        @Test func mirroredSelectionCaseIsPaste() {
            #expect(
                EnterAction.resolve(
                    command: false, pane: .clips,
                    hasText: false, hasMatches: false, hasSelection: true
                ) == .paste
            )
            #expect(
                EnterAction.resolve(
                    command: true, pane: .notes,
                    hasText: false, hasMatches: false, hasSelection: true
                ) == .paste
            )
        }
    }

    @Suite struct ItemBehavior {
        @Test func previewCollapsesWhitespaceRunsAndTrims() {
            let item = Item(content: "  func foo() {\n\n\t   return 1\n}  ")
            #expect(item.preview == "func foo() { return 1 }")
        }

        @Test func previewIsBoundedForHugeContent() {
            // preview is built from a 400-char prefix; a pathological paste
            // must not produce a preview anywhere near content length.
            let item = Item(content: String(repeating: "a", count: 100_000))
            #expect(item.preview.count <= 400)
        }

        @Test func isDisposableOnlyWhenNeitherNoteNorPinned() {
            let plain = Item(content: "clip")
            #expect(plain.isDisposable)

            let note = Item(content: "note", isNote: true)
            #expect(!note.isDisposable)

            let pinned = Item(content: "clip")
            pinned.isPinned = true
            #expect(!pinned.isDisposable)

            let pinnedNote = Item(content: "note", isNote: true)
            pinnedNote.isPinned = true
            #expect(!pinnedNote.isDisposable)
        }

        @Test func initStoresSourceFields() {
            let item = Item(
                content: "copied",
                source: CopySource(name: "Safari", bundleID: "com.apple.Safari")
            )
            #expect(item.content == "copied")
            #expect(item.isNote == false)
            #expect(item.sourceApp == "Safari")
            #expect(item.sourceBundleID == "com.apple.Safari")
        }

        @Test func initWithoutSourceLeavesSourceEmpty() {
            let item = Item(content: "typed", isNote: true)
            #expect(item.sourceApp == nil)
            #expect(item.sourceBundleID == nil)
        }
    }

    // The links section holds ordinary clips, so its decision table must
    // stay identical to the clips pane — a divergence here means the two
    // sections silently drifted apart.
    @Suite struct LinksPane {
        @Test func linkRowsUseClipSemantics() {
            // Anchors the mirror below: without a concrete expectation on at
            // least one cell, an all-.none resolve would satisfy it.
            #expect(
                EnterAction.resolve(
                    command: false, pane: .links,
                    hasText: false, hasMatches: true, hasSelection: true
                ) == .paste
            )
            #expect(
                EnterAction.resolve(
                    command: true, pane: .links,
                    hasText: true, hasMatches: true, hasSelection: true
                ) == .saveNote
            )
            #expect(
                EnterAction.resolve(
                    command: false, pane: .links,
                    hasText: true, hasMatches: false, hasSelection: true
                ) == .saveNote
            )
            #expect(
                EnterAction.resolve(
                    command: false, pane: .links,
                    hasText: false, hasMatches: true, hasSelection: false
                ) == .none
            )
        }

        @Test func mirrorsClipsPaneExactly() {
            for command in [false, true] {
                for hasText in [false, true] {
                    for hasMatches in [false, true] {
                        for hasSelection in [false, true] {
                            #expect(
                                EnterAction.resolve(
                                    command: command, pane: .links,
                                    hasText: hasText, hasMatches: hasMatches,
                                    hasSelection: hasSelection
                                )
                                    == EnterAction.resolve(
                                        command: command, pane: .clips,
                                        hasText: hasText, hasMatches: hasMatches,
                                        hasSelection: hasSelection
                                    )
                            )
                        }
                    }
                }
            }
        }
    }
}
