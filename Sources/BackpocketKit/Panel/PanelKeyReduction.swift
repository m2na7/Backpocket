import AppKit
import SwiftUI

extension PanelKeyPress {
    /// Reduces a SwiftUI key press to the terms the dispatcher decides on.
    ///
    /// Taken apart into its pieces by the caller rather than handed the press
    /// itself: `KeyPress` has no public initializer — the same wall
    /// `PanelShortcut.match` ran into — so a rule stated over a press cannot
    /// be exercised at all, and which keys the panel claims is exactly the
    /// sort of table that goes wrong one branch at a time.
    ///
    /// The shortcut arrives as a closure rather than as a value because
    /// matching one reads the live NSEvent and then every binding out of
    /// preferences, while a character key repeating in the search field is
    /// the most latency-sensitive path the panel has. The named keys never
    /// reach a shortcut (a binding is built from an ANSI key name or
    /// "delete", so it can never be ⇥, esc, ↩ or an arrow) and a repeat's is
    /// discarded by the dispatcher anyway, so neither pays for the lookup.
    ///
    /// `physicalKey` is a closure for the same reason, and is asked even
    /// less often: only for a press with ⌘ alone that types a letter from a
    /// non-Latin script, the one case where ⌘Z falls back to the key.
    ///
    /// `isComposing` is asked in that same case, first, and a yes means no
    /// fallback. ⌘Z over a Hangul syllable the input method has not
    /// committed yet belongs to the field, like every ⌘Z with typing to
    /// undo, but `hasQuery` cannot be trusted to see it: it reads `text`,
    /// which may not hold the syllable before it is committed.
    init(
        key: KeyEquivalent,
        isRepeat: Bool,
        modifiers: EventModifiers,
        matchingShortcut: () -> PanelShortcut?,
        physicalKey: () -> String? = { nil },
        isComposing: () -> Bool = { false }
    ) {
        let reduced: Key
        var matched: PanelShortcut?
        var physical: String?
        if key == .upArrow {
            reduced = .upArrow
        } else if key == .downArrow {
            reduced = .downArrow
        } else if key == .tab {
            reduced = .tab
        } else if key == .escape {
            reduced = .escape
        } else if key == .return {
            reduced = .return
        } else {
            reduced = .character(key.character)
            matched = isRepeat ? nil : matchingShortcut()
            if !isRepeat,
                modifiers.intersection([.command, .shift, .option, .control]) == .command,
                Self.fallsBackToPhysicalKey(key.character),
                !isComposing()
            {
                physical = physicalKey()
            }
        }

        self.init(
            key: reduced,
            isRepeat: isRepeat,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            shortcut: matched,
            physical: physical
        )
    }

    /// Whether `responder` holds marked text: input the input method is
    /// still composing, drawn underlined in the field and not committed.
    /// The panel asks this of its first responder, the field's text view.
    @MainActor
    static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}
