import AppKit
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
