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

        // A binding is built from an ANSI key name or "delete", so it can
        // never be one of these — and the dispatcher's own branches win over
        // shortcuts anyway.
        for key in [KeyEquivalent.upArrow, .downArrow, .tab, .escape, .return] {
            _ = count(key)
        }
        #expect(lookups == 0)

        _ = count("e")
        #expect(lookups == 1)
    }

    @Test func aMatchedShortcutIsCarriedThrough() {
        #expect(reduce("e", modifiers: [.command], shortcut: .edit).shortcut == .edit)
        #expect(reduce("e", modifiers: [.command]).shortcut == nil)
    }
}
