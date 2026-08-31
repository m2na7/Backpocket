import AppKit
import Carbon.HIToolbox
import Testing

@testable import BackpocketKit

/// The armed recorder swallows every keystroke it sees, so the only way out of
/// one is the key it agrees to treat as a cancel. Getting that wrong strands a
/// user in a recorder, or eats a combination they were entitled to bind.
@Suite struct ShortcutRecorderTests {
    @Test func bareEscapeEndsTheRecording() {
        #expect(ShortcutRecorder.cancels(keyCode: kVK_Escape, modifiers: []))
    }

    /// The regression that would make ⌘⎋ unbindable: a recorder that cancels
    /// on any ⎋ can never record one, and nothing else in the pane offers it.
    @Test(arguments: [
        NSEvent.ModifierFlags.command, .control, .option, [.command, .shift],
    ])
    func escapeWithARealModifierIsARecordableCombination(modifiers: NSEvent.ModifierFlags) {
        #expect(!ShortcutRecorder.cancels(keyCode: kVK_Escape, modifiers: modifiers))
    }

    /// ⇧⎋ cancels with the bare one: shift alone cannot start a shortcut, so
    /// treating it as a combination would leave the key doing nothing at all.
    @Test func shiftEscapeStillCancels() {
        #expect(ShortcutRecorder.cancels(keyCode: kVK_Escape, modifiers: .shift))
    }

    @Test func anyOtherKeyIsLeftToTheRecorder() {
        #expect(!ShortcutRecorder.cancels(keyCode: kVK_ANSI_E, modifiers: []))
        #expect(!ShortcutRecorder.cancels(keyCode: kVK_Return, modifiers: []))
    }
}
