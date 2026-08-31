import ServiceManagement
import Testing

@testable import BackpocketKit

/// Launch at login is the one preference whose breakage the user discovers at
/// their next reboot, hours after the click that caused it — and until now it
/// was a `@State` bool and a `try` inside a SwiftUI view, with no test at all.
/// `SMAppService` cannot be driven from a test process, so what is tested here
/// is everything around it: which statuses the app treats as "registered",
/// what the switch shows between the click and the answer, and where a refusal
/// leaves the row.
@Suite struct LaunchAtLoginTests {
    // MARK: Reading the service

    @Test func onlyEnabledCountsAsRegistered() {
        #expect(LaunchAtLogin.isEnabled(.enabled))
        #expect(!LaunchAtLogin.isEnabled(.notRegistered))
        #expect(!LaunchAtLogin.isEnabled(.notFound))
    }

    /// The status that matters most and reads most like success.
    /// `.requiresApproval` is a login item macOS is holding switched off in
    /// System Settings; showing it as on tells the user the app will start at
    /// login when it will not, and nothing else in the window contradicts it.
    @Test func approvalPendingIsNotRegistered() {
        #expect(!LaunchAtLogin.isEnabled(.requiresApproval))

        let row = LaunchAtLogin(status: .requiresApproval)
        #expect(!row.isOn)
    }

    @Test func aFreshRowStartsFromTheService() {
        #expect(LaunchAtLogin(status: .enabled).isOn)
        #expect(!LaunchAtLogin(status: .notRegistered).isOn)
        #expect(LaunchAtLogin(status: .enabled).failure == nil)
    }

    // MARK: Toggling

    @Test func turningOnAsksForRegistrationAndMovesTheSwitchImmediately() {
        var row = LaunchAtLogin(status: .notRegistered)

        #expect(row.requested(true) == .register)
        // The switch has to follow the click, not the round trip: the service
        // call is synchronous but can take long enough to look stuck.
        #expect(row.isOn)
    }

    @Test func turningOffAsksForUnregistration() {
        var row = LaunchAtLogin(status: .enabled)

        #expect(row.requested(false) == .unregister)
        #expect(!row.isOn)
    }

    // MARK: Failure

    /// The regression that makes the switch lie: a refused registration that
    /// leaves the optimistic `isOn` standing shows the user a setting the
    /// system does not have.
    @Test func aRefusedRegistrationPutsTheSwitchBack() {
        var row = LaunchAtLogin(status: .notRegistered)
        _ = row.requested(true)

        row.failed("no", status: .notRegistered)

        #expect(!row.isOn)
        #expect(row.failure == "no")
    }

    /// Registration can fail after having taken effect, so the switch follows
    /// what the service reports rather than reverting to what it showed
    /// before — otherwise the app claims to be unregistered while it is not.
    @Test func aFailureTrustsTheServiceOverThePreviousBelief() {
        var row = LaunchAtLogin(status: .notRegistered)
        _ = row.requested(true)

        row.failed("partly", status: .enabled)

        #expect(row.isOn)
        #expect(row.failure == "partly")
    }

    @Test func aNewRequestClearsTheLastFailure() {
        var row = LaunchAtLogin(status: .notRegistered)
        row.failed("no", status: .notRegistered)

        _ = row.requested(true)

        #expect(row.failure == nil)
    }

    // MARK: Refreshing

    /// Login Items can be flipped in System Settings without this app hearing,
    /// and the pane re-reads on appear. A stale failure left on screen there
    /// would describe a click the user made on a previous visit.
    @Test func refreshingAdoptsTheServiceAndDropsTheFailure() {
        var row = LaunchAtLogin(status: .notRegistered)
        row.failed("no", status: .notRegistered)

        row.refresh(status: .enabled)

        #expect(row.isOn)
        #expect(row.failure == nil)
    }

    @Test func refreshingCanTurnTheSwitchOffAgain() {
        var row = LaunchAtLogin(status: .enabled)

        row.refresh(status: .notRegistered)

        #expect(!row.isOn)
    }
}
