import Foundation

/// What the pane has to say about the global hotkey. Registration is not a
/// boolean: a refused combination and a shortcut that is not running at all
/// are different things to tell someone.
enum HotKeyStatus: Equatable {
    case active
    /// Nothing is registered — the persisted combination was refused at
    /// launch, or a rollback failed on top of a failed switch.
    case inactive
    /// The recorded combination was refused; the previous one still works.
    case rejected
    /// The recorded combination is one the system owns everywhere.
    case reserved
    /// The recorded combination is already a panel shortcut.
    case taken
}

/// One trip down the global shortcut recorder's rollback ladder, as a value.
///
/// Registration can fail — another app may own the combination — and a failed
/// switch must roll back, or the app is left with no hotkey at all. Which of
/// the five outcomes a recorded combination reaches depends on facts the view
/// has (is it reserved, does a panel shortcut already claim it) and on facts
/// only Carbon can answer, one attempt at a time. Deciding it inside the view
/// meant the one path that matters most — the rollback registration failing on
/// top of a failed switch, which leaves the user with no working shortcut and
/// a stored binding claiming otherwise — could not be reached from a test.
///
/// So the ladder lives here and the two things it cannot do itself, persisting
/// and registering, stay with the caller: the same split `PasteFlavor` uses.
/// Every path ends in a registration attempt, refusals included, because
/// registering unregisters first — see `Outcome`.
struct GlobalShortcutChange: Equatable {
    /// The combination to write to preferences before registering, or nil when
    /// the request was refused and the stored binding stands. A refusal still
    /// registers: the recorder tore the running shortcut down when it armed.
    let bindingToPersist: HotKeyBinding?

    /// What the accepted combination replaces, kept for the rollback.
    private let previous: HotKeyBinding
    /// The status a successful registration reports.
    private let succeeded: HotKeyStatus

    /// - Parameters:
    ///   - binding: the combination just recorded.
    ///   - previous: the one in force until now.
    ///   - isReserved: bare ⌘Q bound globally takes Quit away from every app,
    ///     and the only way back into Settings would be the menu-bar item.
    ///   - claimedByPanelShortcut: the panel recorder refuses the global
    ///     hotkey; without the same check here, taking ⌘E globally makes the
    ///     panel's edit shortcut unreachable.
    init(
        binding: HotKeyBinding,
        previous: HotKeyBinding,
        isReserved: Bool,
        claimedByPanelShortcut: Bool
    ) {
        self.previous = previous
        if isReserved {
            bindingToPersist = nil
            succeeded = .reserved
        } else if claimedByPanelShortcut {
            bindingToPersist = nil
            succeeded = .taken
        } else {
            bindingToPersist = binding
            succeeded = .active
        }
    }

    /// What is left to do once the registration attempt has answered.
    enum Outcome: Equatable {
        /// Settled: nothing more to persist, show this.
        case settled(HotKeyStatus)
        /// Registering unregisters first, so the failed attempt has already
        /// torn the working shortcut down. Put this binding back, register
        /// again, and report the second answer through `rolledBack(_:)`.
        case rollBack(to: HotKeyBinding)
    }

    /// The registration that followed `bindingToPersist` succeeded, or did not.
    func registered(_ succeeded: Bool) -> Outcome {
        if succeeded { return .settled(self.succeeded) }
        // A refused combination was never persisted, so there is nothing to
        // roll back to: what failed to register is the binding still stored.
        guard bindingToPersist != nil else { return .settled(.inactive) }
        return .rollBack(to: previous)
    }

    /// The rollback registration answered. When it failed too there is no
    /// hotkey at all, whatever the stored binding says.
    static func rolledBack(_ succeeded: Bool) -> HotKeyStatus {
        succeeded ? .rejected : .inactive
    }
}
