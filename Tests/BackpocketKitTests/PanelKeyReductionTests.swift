import AppKit
import SwiftUI
import Testing

@testable import BackpocketKit

/// Which keys the panel claims, and which press pays for a shortcut lookup.
/// `PanelKeyboard` decides what a reduced press does; this is the step before
/// it, and while it lived inside the view the table could only be checked by
/// pressing keys at a running panel.
@MainActor
@Suite("PanelKeyReduction")
struct PanelKeyReductionTests {
    private func reduce(
        _ key: KeyEquivalent,
        isRepeat: Bool = false,
        modifiers: EventModifiers = [],
        shortcut: @autoclosure () -> PanelShortcut? = nil
    ) -> PanelKeyPress {
        PanelKeyPress(
            key: key, isRepeat: isRepeat, modifiers: modifiers, matchingShortcut: shortcut)
    }

    @Test func theNamedKeysAreTheOnesThePanelGivesItsOwnMeaning() {
        #expect(reduce(.upArrow).key == .upArrow)
        #expect(reduce(.downArrow).key == .downArrow)
        #expect(reduce(.tab).key == .tab)
        #expect(reduce(.escape).key == .escape)
        #expect(reduce(.return).key == .return)
        // Everything else is a letter on its way into the search field.
        #expect(reduce("e").key == .character("e"))
        #expect(reduce(.delete).key == .character(KeyEquivalent.delete.character))
    }

    @Test func onlyTheTwoModifiersTheDispatcherAsksAboutSurvive() {
        let plain = reduce("e")
        #expect(!plain.command)
        #expect(!plain.shift)

        // Option and control reach the field as the characters they compose;
        // the dispatcher has no branch that reads them.
        let decorated = reduce("e", modifiers: [.command, .shift, .option, .control])
        #expect(decorated.command)
        #expect(decorated.shift)
    }

    @Test func aHeldKeyIsMarkedAsOneAndNeverCarriesAShortcut() {
        var lookups = 0
        let held = PanelKeyPress(
            key: "e", isRepeat: true, modifiers: [.command],
            matchingShortcut: {
                lookups += 1
                return .edit
            })

        #expect(held.isRepeat)
        #expect(held.shortcut == nil)
        // The dispatcher discards a repeat's shortcut, and matching one reads
        // the live NSEvent and then every binding out of preferences — on the
        // path a character key repeating in the search field takes.
        #expect(lookups == 0)
    }

    @Test func onlyACharacterKeyPaysForTheShortcutLookup() {
        var lookups = 0
        let count: (KeyEquivalent) -> PanelKeyPress = { key in
            PanelKeyPress(
                key: key, isRepeat: false, modifiers: [],
                matchingShortcut: {
                    lookups += 1
                    return nil
                })
        }

        // No binding can name ⇥, esc or ↩, and none is a bare arrow — a
        // binding needs ⌘, ⌥ or ⌃ — so none of these is worth the lookup.
        for key in [KeyEquivalent.upArrow, .downArrow, .tab, .escape, .return] {
            _ = count(key)
        }
        #expect(lookups == 0)

        _ = count("e")
        #expect(lookups == 1)
    }

    @Test func anUpOrDownArrowWithAModifierAsksForAShortcut() {
        var lookups = 0
        let press = PanelKeyPress(
            key: .downArrow, isRepeat: false, modifiers: [.option, .command],
            matchingShortcut: {
                lookups += 1
                return .toNote
            })
        #expect(press.key == .downArrow)
        #expect(press.shortcut == .toNote)
        #expect(lookups == 1)

        // Held, it is a walk down the list, and pays for nothing.
        let held = PanelKeyPress(
            key: .downArrow, isRepeat: true, modifiers: [.option, .command],
            matchingShortcut: {
                lookups += 1
                return .toNote
            })
        #expect(held.shortcut == nil)
        #expect(lookups == 1)
    }

    @Test func aMatchedShortcutIsCarriedThrough() {
        #expect(reduce("e", modifiers: [.command], shortcut: .edit).shortcut == .edit)
        #expect(reduce("e", modifiers: [.command]).shortcut == nil)
    }

    /// Reduces `key` with a physical-key lookup that answers "z" and counts
    /// how often it was asked.
    private func physicalLookups(
        _ key: KeyEquivalent, isRepeat: Bool = false, modifiers: EventModifiers,
        composing: Bool = false
    ) -> (press: PanelKeyPress, lookups: Int) {
        var lookups = 0
        let press = PanelKeyPress(
            key: key, isRepeat: isRepeat, modifiers: modifiers, matchingShortcut: { nil },
            physicalKey: {
                lookups += 1
                return "z"
            },
            isComposing: { composing })
        return (press, lookups)
    }

    /// ⌘ and a letter from a non-Latin script: the one press whose
    /// character says nothing about the key, so the key is looked up.
    @Test func commandAloneOnANonLatinLetterCarriesThePhysicalKey() {
        for letter in ["ㅋ", "つ", "я", "ω"] {
            let reduced = physicalLookups(KeyEquivalent(Character(letter)), modifiers: [.command])
            #expect(reduced.press.physical == "z")
            #expect(reduced.lookups == 1)
        }
    }

    /// Everywhere else the lookup is not made at all: typing, repeats,
    /// Latin letters, and ⌘ with any other modifier. ⌘⌥Z types "Ω" on a US
    /// layout, and borrowing its key would turn that into an undo.
    @Test func everyOtherPressSkipsThePhysicalLookup() {
        let skipped: [(KeyEquivalent, Bool, EventModifiers)] = [
            ("ㅋ", false, []),
            ("ㅋ", true, [.command]),
            ("z", false, [.command]),
            ("é", false, [.command]),
            ("ㅋ", false, [.command, .shift]),
            ("Ω", false, [.command, .option]),
            ("ㅋ", false, [.command, .control]),
            (.return, false, [.command]),
            (.escape, false, [.command]),
        ]
        for (key, isRepeat, modifiers) in skipped {
            let reduced = physicalLookups(key, isRepeat: isRepeat, modifiers: modifiers)
            #expect(reduced.press.physical == nil)
            #expect(reduced.lookups == 0)
        }

        // And so the dispatcher sees ⌘⌥Z's "Ω" as nothing it owns.
        var restorable = PanelKeyContext()
        restorable.canUndoDelete = true
        let composed = physicalLookups("Ω", modifiers: [.command, .option]).press
        #expect(PanelKeyboard.command(for: composed, in: restorable) == .unhandled)
    }

    /// ⌘ on the Z key over a syllable the input method has not committed
    /// yet is the field's undo, whatever `hasQuery` says. So the press
    /// borrows no key, and the key is not even looked up.
    @Test func aPressWhileTheFieldIsComposingNeverFallsBack() {
        let reduced = physicalLookups("ㅋ", modifiers: [.command], composing: true)
        #expect(reduced.press.physical == nil)
        #expect(reduced.lookups == 0)

        var restorable = PanelKeyContext()
        restorable.canUndoDelete = true
        #expect(PanelKeyboard.command(for: reduced.press, in: restorable) == .unhandled)
    }

    /// What the panel asks of its field: whether its text view holds marked
    /// text, which is how an input method shows a syllable in progress.
    @Test func markedTextInTheFieldIsComposing() {
        let field = NSTextView()
        #expect(!PanelKeyPress.isComposing(field))

        field.setMarkedText(
            "ㅎ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(PanelKeyPress.isComposing(field))

        field.unmarkText()
        #expect(!PanelKeyPress.isComposing(field))
        // A panel with no text view focused has nothing in progress.
        #expect(!PanelKeyPress.isComposing(nil))
        #expect(!PanelKeyPress.isComposing(NSView()))
    }
}
