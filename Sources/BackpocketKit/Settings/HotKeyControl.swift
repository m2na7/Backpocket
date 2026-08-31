import Foundation

/// The three things Settings needs done to the global hotkey, as a value.
///
/// The shortcut recorder has to tear the running shortcut down for the
/// duration of a recording and put it back afterwards, and "Reset everything"
/// may have just restored the default combination — all of which is Carbon
/// registration state owned by the app delegate. Reaching for
/// `AppDelegate.shared` to do it put a SwiftUI view in charge of process-wide
/// state through a global, while the delegate already reads Settings for
/// expiry and paste behaviour: neither side could be reasoned about without
/// the other. Stating the operations here and letting the composition root
/// supply them leaves the dependency running one way.
@MainActor
struct HotKeyControl {
    /// False when Carbon refused the persisted combination, so the pane can
    /// say the shortcut is not running rather than showing it as bound.
    var isActive: () -> Bool
    /// Unregisters the shortcut until the next `apply`.
    var suspend: () -> Void
    /// Registers whatever is persisted right now; false when Carbon refused.
    var apply: () -> Bool
}
