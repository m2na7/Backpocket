import AppKit
import Carbon.HIToolbox

/// The decisions an armed shortcut recorder makes about a keystroke, kept out
/// of the event monitor that receives it.
///
/// The monitor swallows every key it sees — it returns nil on all paths, which
/// is what stops a recording from typing into the form — so a mistake here is
/// invisible until a user cannot get out of a recorder, or cannot record the
/// combination they wanted.
enum ShortcutRecorder {
    /// ⎋ ends the recording without capturing anything. Only bare ⎋: ⌘⎋, ⌃⎋
    /// and ⌥⎋ are combinations a user may legitimately want to bind, and a
    /// recorder that ate them could never offer them. ⇧⎋ cancels with the
    /// bare one, since shift alone cannot start a shortcut anyway and the key
    /// would otherwise do nothing at all.
    static func cancels(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == kVK_Escape
            && modifiers.intersection([.command, .control, .option]).isEmpty
    }
}
