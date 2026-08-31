import ServiceManagement

/// What the launch-at-login row believes, and what a click on it means.
///
/// `SMAppService` answers truthfully only inside a real login session, so it
/// cannot be driven from a test — but the decisions around it can: which
/// service statuses count as "on", what the switch shows between the click and
/// the answer, and where a refusal leaves the row. Those live here as a value
/// and the two registration calls stay in the view, the same split
/// `PasteFlavor` uses. If this logic is wrong the user finds out at their next
/// reboot, which is the worst possible place to find out.
struct LaunchAtLogin: Equatable {
    /// What the switch shows.
    private(set) var isOn: Bool
    /// The last refusal, shown in place of the section footer. Cleared by
    /// anything that re-reads the service or starts a new request.
    private(set) var failure: String?

    init(status: SMAppService.Status) {
        isOn = Self.isEnabled(status)
    }

    /// Only `.enabled` is on. `.requiresApproval` in particular is a login item
    /// that macOS is holding switched off: showing a checked box for it
    /// promises a launch that will not happen, and nothing in this window would
    /// ever contradict it.
    static func isEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    /// The call the view should make on the service.
    enum Request: Equatable {
        case register
        case unregister
    }

    /// Moves the switch first and says what to do about it: the switch has to
    /// follow the click immediately, and a refusal below puts it back.
    mutating func requested(_ on: Bool) -> Request {
        isOn = on
        failure = nil
        return on ? .register : .unregister
    }

    /// The request threw. The switch goes back to what the service reports
    /// rather than to what it showed before — a registration can fail after
    /// having taken effect, and only the service knows which happened.
    mutating func failed(_ message: String, status: SMAppService.Status) {
        failure = message
        isOn = Self.isEnabled(status)
    }

    /// Login items can be flipped in System Settings without this app hearing
    /// about it, so the pane re-reads the service whenever it appears.
    mutating func refresh(status: SMAppService.Status) {
        isOn = Self.isEnabled(status)
        failure = nil
    }
}
