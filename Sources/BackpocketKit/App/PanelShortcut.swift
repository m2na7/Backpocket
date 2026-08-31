import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One stored key combination: a layout-independent ANSI key name plus the
/// real modifier flags.
struct KeyBinding: Equatable {
    /// "e", "8", "[" — or the special "delete". Never a layout glyph.
    var key: String
    /// Raw NSEvent.ModifierFlags, masked to the four real modifiers.
    var modifiers: UInt

    static let realModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(key: String, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers
    }

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.init(key: key, modifiers: modifiers.rawValue)
    }

    /// Built from a recorder-captured keyDown; nil when no real modifier is
    /// held or the key is not one a panel shortcut may use.
    init?(capturing event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.realModifiers)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        let code = Int(event.keyCode)
        if code == kVK_Delete {
            key = "delete"
        } else if let name = HotKeyBinding.ansiName(for: code) {
            key = name.lowercased()
        } else {
            return nil
        }
        modifiers = flags.rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    /// "⌃⌥⇧⌘" plus the key, modifiers in the order macOS renders them.
    var label: String {
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + (key == "delete" ? "⌫" : key.uppercased())
    }
}

/// The rebindable in-panel shortcuts. Structural keys — ↩, ⌘↩, ⇥, esc,
/// ⌘1–9, ⌘, — are deliberately absent: rebinding them would break the
/// panel's grammar rather than customize it.
enum PanelShortcut: String, CaseIterable, Identifiable {
    case edit
    case pin
    case delete
    case stack
    case openLink

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .edit: "ctx.edit"
        case .pin: "ctx.star"
        case .delete: "ctx.delete"
        case .stack: "hint.stack"
        case .openLink: "ctx.openLink"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .edit: KeyBinding(key: "e", modifiers: .command)
        case .pin: KeyBinding(key: "p", modifiers: .command)
        case .delete: KeyBinding(key: "delete", modifiers: .command)
        case .stack: KeyBinding(key: "d", modifiers: .command)
        case .openLink: KeyBinding(key: "o", modifiers: .command)
        }
    }

    var keyDefaultsKey: String { "shortcut.\(rawValue).key" }
    var modifiersDefaultsKey: String { "shortcut.\(rawValue).modifiers" }

    /// Everything the shortcuts store under UserDefaults — so the reset
    /// paths cannot forget a key.
    static var defaultsKeys: [String] {
        allCases.flatMap { [$0.keyDefaultsKey, $0.modifiersDefaultsKey] }
    }

    var current: KeyBinding {
        let defaults = PreferenceStore.defaults
        guard let key = defaults.string(forKey: keyDefaultsKey) else { return defaultBinding }
        return KeyBinding(
            key: key,
            modifiers: UInt(bitPattern: defaults.integer(forKey: modifiersDefaultsKey))
        )
    }

    func persist(_ binding: KeyBinding) {
        let defaults = PreferenceStore.defaults
        defaults.set(binding.key, forKey: keyDefaultsKey)
        defaults.set(Int(bitPattern: binding.modifiers), forKey: modifiersDefaultsKey)
    }

    static func resetAll() {
        let defaults = PreferenceStore.defaults
        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Combinations the panel already owns structurally; the recorder must
    /// refuse them.
    static func isReserved(_ binding: KeyBinding) -> Bool {
        guard binding.eventModifiers == .command, binding.key.count == 1 else { return false }
        return binding.key.first!.isNumber || binding.key == ","
    }

    /// Whether a recorded combination may not be assigned to `shortcut`.
    ///
    /// Three ways it may not. The panel owns it structurally. Another action
    /// already uses it — and `$0 != shortcut` is load-bearing there, since
    /// re-recording an action onto the combination it already has is not a
    /// conflict with itself, only with somebody else. Or it is the global
    /// hotkey, which Carbon consumes before the panel is ever asked.
    ///
    /// Here rather than in the Settings view because it is the rule the
    /// recorder enforces, and the view could get any of the three backwards
    /// without a test noticing: a user handed a shortcut that silently never
    /// fires, or refused one that was free all along.
    @MainActor
    static func conflicts(
        _ binding: KeyBinding, assignedTo shortcut: PanelShortcut, globalHotKeyLabel: String
    ) -> Bool {
        if isReserved(binding) { return true }
        if allCases.contains(where: { $0 != shortcut && $0.current == binding }) { return true }
        return binding.label == globalHotKeyLabel
    }

    /// Whether some panel action already holds this combination — asked of a
    /// global hotkey, which would otherwise swallow the action's key forever.
    @MainActor
    static func anyClaims(label: String) -> Bool {
        allCases.contains { $0.current.label == label }
    }

    /// The shortcut a key press activates, if any.
    @MainActor
    static func match(_ press: KeyPress) -> PanelShortcut? {
        // KeyPress's character follows the active input source — under a
        // Korean layout the O key arrives as "ㅐ" and every letter shortcut
        // dies. The underlying NSEvent's keyCode names the physical key, so
        // it is consulted first.
        let physical: String? = {
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return nil }
            if Int(event.keyCode) == kVK_Delete { return "delete" }
            return HotKeyBinding.ansiName(for: Int(event.keyCode))?.lowercased()
        }()

        return match(
            physical: physical,
            character: String(press.key.character),
            isDelete: press.key == .delete,
            modifiers: press.modifiers
        )
    }

    /// KeyPress has no public initializer, so the matching itself lives here
    /// where a test can reach it.
    static func match(
        physical: String?,
        character: String,
        isDelete: Bool,
        modifiers: SwiftUI.EventModifiers
    ) -> PanelShortcut? {
        let pressed = modifiers.intersection([.command, .shift, .option, .control])

        for shortcut in allCases {
            let binding = shortcut.current
            guard pressed == binding.eventModifiers else { continue }

            if let physical {
                if physical == binding.key { return shortcut }
            } else if binding.key == "delete" {
                if isDelete { return shortcut }
            } else if character.lowercased() == binding.key {
                return shortcut
            }
        }
        return nil
    }
}
