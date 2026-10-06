import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import BackpocketKit

/// No longer serialized: the tests that store a binding do it in a defaults
/// database of their own, so none of them can see another's shortcut.
@Suite("PanelShortcut")
struct PanelShortcutTests {
    @Test func defaultBindingsMatchTheShippedKeys() throws {
        try withScratchPreferences { _ in
            #expect(PanelShortcut.edit.current.label == "⌘E")
            #expect(PanelShortcut.pin.current.label == "⌘P")
            #expect(PanelShortcut.delete.current.label == "⌘⌫")
            #expect(PanelShortcut.stack.current.label == "⌘D")
            #expect(PanelShortcut.openLink.current.label == "⌘O")
            #expect(PanelShortcut.toNote.current.label == "⌘N")
        }
    }

    @Test func persistedBindingRoundTripsAndResetRestoresTheDefault() throws {
        try withScratchPreferences { _ in
            let custom = KeyBinding(key: "k", modifiers: [.command, .shift])
            PanelShortcut.edit.persist(custom)
            #expect(PanelShortcut.edit.current == custom)
            #expect(PanelShortcut.edit.current.label == "⇧⌘K")

            PanelShortcut.resetAll()
            #expect(PanelShortcut.edit.current == PanelShortcut.edit.defaultBinding)
        }
    }

    @Test func reservedCombinationsAreRefused() {
        // ⌘1–9 are the paste slots and ⌘, is Settings.
        #expect(PanelShortcut.isReserved(KeyBinding(key: "5", modifiers: .command)))
        #expect(PanelShortcut.isReserved(KeyBinding(key: ",", modifiers: .command)))
        // With another modifier the combination is fair game.
        #expect(!PanelShortcut.isReserved(KeyBinding(key: "5", modifiers: [.command, .shift])))
        #expect(!PanelShortcut.isReserved(KeyBinding(key: "e", modifiers: .command)))
    }

    @Test func anArrowNeedsTwoOfCommandOptionAndControl() {
        // One alone is already spoken for: ⌘ and ⌥ move the caret in the
        // search field, which always has focus, and ⌃ switches Spaces.
        for flags: NSEvent.ModifierFlags in [
            .command, .option, .control, [.command, .shift], [.option, .shift],
        ] {
            for arrow in ["left", "right", "up", "down"] {
                #expect(PanelShortcut.isReserved(KeyBinding(key: arrow, modifiers: flags)))
            }
        }
        #expect(
            !PanelShortcut.isReserved(KeyBinding(key: "right", modifiers: [.option, .command])))
        #expect(
            !PanelShortcut.isReserved(KeyBinding(key: "down", modifiers: [.control, .command])))
        #expect(
            !PanelShortcut.isReserved(
                KeyBinding(key: "left", modifiers: [.control, .option, .shift])))
    }

    @Test func theArrowsAreNamedAndDrawnLikeTheOtherSpecialKeys() {
        #expect(KeyBinding.keyName(for: kVK_LeftArrow) == "left")
        #expect(KeyBinding.keyName(for: kVK_RightArrow) == "right")
        #expect(KeyBinding.keyName(for: kVK_UpArrow) == "up")
        #expect(KeyBinding.keyName(for: kVK_DownArrow) == "down")
        #expect(KeyBinding.keyName(for: kVK_Delete) == "delete")
        #expect(KeyBinding.keyName(for: kVK_ANSI_N) == "n")
        #expect(KeyBinding(key: "right", modifiers: [.option, .command]).label == "⌥⌘→")
        #expect(KeyBinding(key: "up", modifiers: [.control, .command]).label == "⌃⌘↑")
    }

    @Test func aShortcutReboundOntoAnArrowMatchesThatArrow() throws {
        try withScratchPreferences { _ in
            PanelShortcut.toNote.persist(KeyBinding(key: "right", modifiers: [.option, .command]))
            // The character an arrow types is a private-use code point, so
            // only the physical key can say which arrow it was.
            #expect(
                PanelShortcut.match(
                    physical: "right", character: "\u{F703}", isDelete: false,
                    modifiers: [.option, .command])
                    == .toNote
            )
            // ⌘→ alone is still the field's.
            #expect(
                PanelShortcut.match(
                    physical: "right", character: "\u{F703}", isDelete: false, modifiers: .command)
                    == nil
            )
            // And the default it moved off no longer fires.
            #expect(
                PanelShortcut.match(
                    physical: "n", character: "n", isDelete: false, modifiers: .command)
                    == nil
            )
        }
    }

    @MainActor
    @Test func arecordedCombinationIsRefusedForEachOfTheThreeReasons() throws {
        try withScratchPreferences { _ in
            let global = "⌥⌘V"
            @MainActor
            func conflicts(_ binding: KeyBinding, _ shortcut: PanelShortcut = .edit) -> Bool {
                PanelShortcut.conflicts(binding, assignedTo: shortcut, globalHotKeyLabel: global)
            }

            // Free, so it may be taken.
            #expect(!conflicts(KeyBinding(key: "k", modifiers: [.command, .shift])))
            // The panel owns ⌘1–9 and ⌘, structurally.
            #expect(conflicts(KeyBinding(key: "5", modifiers: .command)))
            // Carbon eats the global hotkey before the panel is asked, so an
            // action bound to it would be a shortcut that never fires.
            #expect(conflicts(KeyBinding(key: "v", modifiers: [.command, .option])))

            // Another action already holds ⌘P.
            let pin = PanelShortcut.pin.current
            #expect(conflicts(pin))
            // But re-recording an action onto the combination it already has
            // is not a conflict with itself — only with somebody else. Refuse
            // that and the recorder rejects the shortcut already on screen.
            #expect(!conflicts(pin, .pin))
        }
    }

    @MainActor
    @Test func aglobalHotkeyAlreadyHeldByApanelActionIsRecognized() throws {
        try withScratchPreferences { _ in
            #expect(PanelShortcut.anyClaims(label: PanelShortcut.stack.current.label))
            #expect(!PanelShortcut.anyClaims(label: "⇧⌘K"))
        }
    }

    @Test func matchPrefersThePhysicalKeyOverTheLayoutCharacter() throws {
        // Matching is against the bindings in force, so this runs on a store
        // of its own: the shipped bindings are what it means to assert about.
        try withScratchPreferences { _ in
            // The bug this guards: under a Korean input source the O key
            // arrives as "ㅐ", and matching on the character alone killed
            // every letter shortcut.
            #expect(
                PanelShortcut.match(
                    physical: "o", character: "ㅐ", isDelete: false, modifiers: .command)
                    == .openLink
            )
            #expect(
                PanelShortcut.match(
                    physical: nil, character: "O", isDelete: false, modifiers: .command)
                    == .openLink
            )
            #expect(
                PanelShortcut.match(
                    physical: nil, character: "\u{7F}", isDelete: true, modifiers: .command)
                    == .delete
            )
            // A modifier the binding does not carry must not match.
            #expect(
                PanelShortcut.match(
                    physical: "o", character: "o", isDelete: false, modifiers: [.command, .shift])
                    == nil
            )
        }
    }

    @Test func labelOrdersModifiersTheWayMacOSDoes() {
        let binding = KeyBinding(key: "v", modifiers: [.command, .control, .option, .shift])
        #expect(binding.label == "⌃⌥⇧⌘V")
    }
}
