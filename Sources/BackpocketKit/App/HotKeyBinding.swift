import AppKit
import Carbon.HIToolbox

/// The user's global shortcut: a Carbon keycode plus Carbon modifier mask,
/// persisted as two plain integers. The recorder in Settings writes any
/// combination; earlier versions offered three fixed presets, and their
/// stored names are migrated on read.
struct HotKeyBinding: Equatable {
    var keyCode: Int
    var modifiers: Int

    static let standard = HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static var current: HotKeyBinding {
        let defaults = PreferenceStore.defaults
        if defaults.object(forKey: PreferenceKey.hotKeyCode) != nil {
            return HotKeyBinding(
                keyCode: defaults.integer(forKey: PreferenceKey.hotKeyCode),
                modifiers: defaults.integer(forKey: PreferenceKey.hotKeyModifiers)
            )
        }

        // Pre-recorder installs stored one of three preset names.
        switch defaults.string(forKey: PreferenceKey.hotKey) {
        case "controlCommand":
            return HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey)
        case "optionCommand":
            return HotKeyBinding(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey)
        default: return .standard
        }
    }

    func persist() {
        let defaults = PreferenceStore.defaults
        defaults.set(keyCode, forKey: PreferenceKey.hotKeyCode)
        defaults.set(modifiers, forKey: PreferenceKey.hotKeyModifiers)
    }

    /// Built from a keyDown the recorder captured; nil when the combination
    /// cannot serve as a global shortcut — without ⌘, ⌃, or ⌥ it would
    /// shadow ordinary typing in every app.
    init?(capturing event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }

        self.keyCode = Int(event.keyCode)
        self.modifiers = carbon
    }

    /// Bare ⌘ combinations every app relies on. Bound globally they are taken
    /// away everywhere — including from this app's own Settings — and the
    /// only way back is the menu-bar item, so the recorder refuses them.
    /// PanelShortcut.isReserved is the in-panel counterpart.
    private static let reservedKeyCodes: Set<Int> = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_V, kVK_ANSI_C, kVK_ANSI_X,
        kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_H, kVK_ANSI_M,
        kVK_Tab, kVK_Space,
    ]

    /// Only bare ⌘: ⇧⌘V and ⌥⌘Q are the user's to take.
    var isReserved: Bool {
        modifiers == cmdKey && Self.reservedKeyCodes.contains(keyCode)
    }

    /// "⌃⌥⇧⌘" plus the key, modifiers in the order macOS renders them.
    var label: String {
        var parts = ""
        if modifiers & controlKey != 0 { parts += "⌃" }
        if modifiers & optionKey != 0 { parts += "⌥" }
        if modifiers & shiftKey != 0 { parts += "⇧" }
        if modifiers & cmdKey != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The US-ANSI face of each key, so a shortcut recorded under a Korean
    /// (or any other) input source never reads back as "⌘ㅔ" — the label
    /// stays the letter printed on the physical key.
    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]

    /// The fixed ANSI face of a key, nil for anything outside the table.
    /// PanelShortcut's recorder builds its layout-independent names from this.
    static func ansiName(for keyCode: Int) -> String? {
        ansiKeys[keyCode]
    }

    /// ANSI keys read from the fixed table; anything else (JIS extras and
    /// the like) still translates through the live keyboard layout.
    static func keyName(for keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let ansi = ansiKeys[keyCode] { return ansi }

        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }

        // The bytes belong to the input source, which must outlive the
        // translation reading them.
        return withExtendedLifetime(source) { () -> String in
            let data = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
                return UCKeyTranslate(
                    base.assumingMemoryBound(to: UCKeyboardLayout.self),
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys,
                    chars.count,
                    &length,
                    &chars
                )
            }

            guard status == noErr, length > 0 else { return "#\(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
