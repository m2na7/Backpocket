import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import BackpocketKit

/// No longer serialized: the tests that store a binding do it in a defaults
/// database of their own, so none of them can see another's shortcut.
@MainActor
@Suite("HotKeyBinding")
struct HotKeyBindingTests {

    private func keyEvent(
        keyCode: Int,
        flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: UInt16(keyCode)
            ))
    }

    @Test func defaultsToShiftCommandV() throws {
        try withScratchPreferences { _ in
            #expect(HotKeyBinding.current == .standard)
            #expect(HotKeyBinding.standard.keyCode == kVK_ANSI_V)
            #expect(HotKeyBinding.standard.modifiers == cmdKey | shiftKey)
        }
    }

    @Test func legacyPresetNamesMigrate() throws {
        try withScratchPreferences { defaults in
            defaults.set("controlCommand", forKey: PreferenceKey.hotKey)
            let control = HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey)
            #expect(HotKeyBinding.current == control)

            defaults.set("optionCommand", forKey: PreferenceKey.hotKey)
            let option = HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey)
            #expect(HotKeyBinding.current == option)
        }
    }

    @Test func recordedBindingOutranksLegacyPreset() throws {
        try withScratchPreferences { defaults in
            defaults.set("controlCommand", forKey: PreferenceKey.hotKey)
            let custom = HotKeyBinding(keyCode: kVK_Space, modifiers: cmdKey | optionKey)
            custom.persist()

            #expect(HotKeyBinding.current == custom)
        }
    }

    @Test func captureRequiresARealModifier() throws {
        // Bare keys and shift-only combinations would shadow ordinary typing.
        #expect(HotKeyBinding(capturing: try keyEvent(keyCode: kVK_ANSI_V, flags: [])) == nil)
        #expect(HotKeyBinding(capturing: try keyEvent(keyCode: kVK_ANSI_V, flags: [.shift])) == nil)
        #expect(
            HotKeyBinding(capturing: try keyEvent(keyCode: kVK_ANSI_V, flags: [.command])) != nil)
        #expect(
            HotKeyBinding(capturing: try keyEvent(keyCode: kVK_ANSI_V, flags: [.control])) != nil)
        #expect(
            HotKeyBinding(capturing: try keyEvent(keyCode: kVK_ANSI_V, flags: [.option])) != nil)
    }

    @Test func captureMapsEveryModifierToItsCarbonBit() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_V, flags: [.command, .control, .option, .shift])
        let binding = try #require(HotKeyBinding(capturing: event))

        #expect(binding.keyCode == kVK_ANSI_V)
        #expect(binding.modifiers == cmdKey | controlKey | optionKey | shiftKey)
    }

    @Test func labelOrdersModifiersTheWayMacOSDoes() {
        let binding = HotKeyBinding(
            keyCode: kVK_Space,
            modifiers: cmdKey | controlKey | optionKey | shiftKey
        )
        #expect(binding.label == "⌃⌥⇧⌘Space")
    }

    @Test func specialKeysUseSymbolsNotCodes() {
        #expect(HotKeyBinding.keyName(for: kVK_Return) == "↩")
        #expect(HotKeyBinding.keyName(for: kVK_F5) == "F5")
    }

    /// Bare ⌘ plus one of these is a combination every Mac app owns. Taking
    /// ⌘Q or ⌘V globally means the user can no longer quit or paste anywhere.
    @Test(
        arguments: [
            kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_V, kVK_ANSI_C, kVK_ANSI_X,
            kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space,
        ])
    func bareCommandCombinationsTheSystemOwnsAreReserved(keyCode: Int) {
        #expect(HotKeyBinding(keyCode: keyCode, modifiers: cmdKey).isReserved)
    }

    @Test func addingAnyOtherModifierMakesTheCombinationTheUsersToTake() {
        // Only BARE ⌘ is refused. ⇧⌘V is the shipped default, so a check that
        // looked at the key alone would reject the app's own shortcut.
        #expect(!HotKeyBinding.standard.isReserved)
        #expect(!HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey).isReserved)
        #expect(!HotKeyBinding(keyCode: kVK_ANSI_Q, modifiers: cmdKey | optionKey).isReserved)
        #expect(!HotKeyBinding(keyCode: kVK_Space, modifiers: cmdKey | controlKey).isReserved)
    }

    @Test func combinationsOutsideTheListAreNotReserved() {
        // A reserved check that returned true too widely would leave the
        // recorder refusing everything with no way to tell the user why.
        #expect(!HotKeyBinding(keyCode: kVK_ANSI_B, modifiers: cmdKey).isReserved)
        #expect(!HotKeyBinding(keyCode: kVK_ANSI_K, modifiers: cmdKey).isReserved)
        #expect(!HotKeyBinding(keyCode: kVK_F5, modifiers: cmdKey).isReserved)
    }

    @Test func theShippedDefaultSurvivesTheReservedCheck() {
        // Belt and braces on the one binding every fresh install starts with:
        // reserving it would leave a new user with no working hotkey at all.
        #expect(HotKeyBinding.standard.label == "⇧⌘V")
        #expect(!HotKeyBinding.standard.isReserved)
    }

    @Test func keyNamesAreANSIRegardlessOfInputSource() {
        // These must never depend on the active keyboard layout — a shortcut
        // recorded under a Korean input source still reads "⌘P", not "⌘ㅔ".
        #expect(HotKeyBinding.keyName(for: kVK_ANSI_P) == "P")
        #expect(HotKeyBinding.keyName(for: kVK_ANSI_V) == "V")
        #expect(HotKeyBinding.keyName(for: kVK_ANSI_1) == "1")
        #expect(HotKeyBinding.keyName(for: kVK_ANSI_Slash) == "/")
    }
}
