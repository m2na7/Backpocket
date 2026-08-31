import Carbon.HIToolbox
import Testing

@testable import BackpocketKit

/// The global shortcut recorder's rollback ladder: five outcomes, decided from
/// two facts the pane knows and one or two answers only Carbon can give.
///
/// Until this was a value it lived inside a SwiftUI view, where the branch that
/// matters most could not be reached at all — the rollback registration failing
/// on top of a failed switch, which leaves the user with no working hotkey and
/// a stored binding claiming otherwise. Every test below names the thing a user
/// would be told, since telling them the wrong one is the whole failure mode.
@Suite struct GlobalShortcutChangeTests {
    private static let requested = HotKeyBinding(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey)
    private static let previous = HotKeyBinding.standard

    private static func change(
        isReserved: Bool = false,
        claimedByPanelShortcut: Bool = false
    ) -> GlobalShortcutChange {
        GlobalShortcutChange(
            binding: requested,
            previous: previous,
            isReserved: isReserved,
            claimedByPanelShortcut: claimedByPanelShortcut
        )
    }

    // MARK: Accepting a combination

    @Test func anAcceptedCombinationIsTheOneWrittenToPreferences() {
        #expect(Self.change().bindingToPersist == Self.requested)
    }

    @Test func anAcceptedCombinationThatRegistersIsActive() {
        #expect(Self.change().registered(true) == .settled(.active))
    }

    // MARK: Refusals

    /// Bare ⌘Q bound globally takes Quit away from every app, and the only way
    /// back into Settings would be the menu-bar item. Persisting it anyway
    /// would leave that trap in place across the next launch.
    @Test func aReservedCombinationIsRefusedWithoutBeingPersisted() {
        let change = Self.change(isReserved: true)

        #expect(change.bindingToPersist == nil)
        #expect(change.registered(true) == .settled(.reserved))
    }

    /// The panel recorder refuses the global hotkey; without the same check
    /// here, taking ⌘E globally makes the panel's edit shortcut unreachable.
    @Test func aCombinationAPanelShortcutOwnsIsRefusedWithoutBeingPersisted() {
        let change = Self.change(claimedByPanelShortcut: true)

        #expect(change.bindingToPersist == nil)
        #expect(change.registered(true) == .settled(.taken))
    }

    /// Reserved is checked first, so the user is told the real reason: a
    /// combination that is both reserved and claimed is refused as reserved,
    /// and "already a panel shortcut" would send them to rebind the wrong one.
    @Test func reservedOutranksClaimedWhenBothApply() {
        let change = Self.change(isReserved: true, claimedByPanelShortcut: true)

        #expect(change.registered(true) == .settled(.reserved))
    }

    /// A refusal still registers, because arming the recorder tore the running
    /// shortcut down. Nothing was persisted, so there is nothing to roll back
    /// to — the binding that failed to register is the stored one, and the
    /// honest answer is that no shortcut is running.
    @Test(arguments: [true, false])
    func aRefusalWhoseRestoreFailsLeavesNothingRunning(claimed: Bool) {
        let change = Self.change(isReserved: !claimed, claimedByPanelShortcut: claimed)

        #expect(change.registered(false) == .settled(.inactive))
    }

    // MARK: Rollback

    /// Another app may already own the combination. Registering unregisters
    /// first, so by the time Carbon refuses, the shortcut that worked a moment
    /// ago is gone: the ladder must name the binding to put back, or the app
    /// is left with no hotkey at all.
    @Test func aRefusedRegistrationRollsBackToThePreviousCombination() {
        #expect(Self.change().registered(false) == .rollBack(to: Self.previous))
    }

    /// The rollback took: the previous shortcut is running again, and what the
    /// user needs to hear is that the combination they recorded was refused —
    /// not that their shortcut is dead, which it is not.
    @Test func aSuccessfulRollbackReportsTheRecordedCombinationAsRejected() {
        #expect(GlobalShortcutChange.rolledBack(true) == .rejected)
    }

    /// The case nothing tested before, and the only one that leaves a user
    /// silently without a hotkey: the switch failed, and putting the old
    /// combination back failed too. Preferences now hold a binding that is not
    /// registered with anything, so reporting `.rejected` here — the previous
    /// shortcut still works — would be a lie the pane has no way to correct.
    @Test func aRollbackThatFailsTooReportsNoShortcutAtAll() {
        #expect(GlobalShortcutChange.rolledBack(false) == .inactive)
    }

    /// The rollback target is the combination in force before the switch, not
    /// the one just recorded: persisting the requested binding again would
    /// restore exactly the state the failure proved unusable.
    @Test func theRollbackTargetIsNotTheCombinationThatWasJustRefused() {
        guard case .rollBack(let target) = Self.change().registered(false) else {
            Issue.record("a failed switch must roll back")
            return
        }

        #expect(target != Self.requested)
    }
}
