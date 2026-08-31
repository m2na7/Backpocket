import OSLog
import Sparkle
import SwiftUI

/// The auto-updater, and the app's only unconditional network call.
///
/// Sparkle asks the appcast whether a newer build exists. That request is
/// also the project's only measure of how many people actually run this —
/// downloads count copies fetched, not copies kept — which is why automatic
/// checks are enabled rather than offered on first launch, and why the feed
/// is served from a host whose logs the maintainer can read. Both facts are
/// stated in the READMEs; changing either without changing those is how a
/// privacy claim quietly becomes false.
///
/// What leaves the machine is what any HTTP request carries: an IP address,
/// a timestamp, and Sparkle's user agent naming the app and OS version.
/// Nothing about the user's clipboard, and no identifier the app invents.
///
/// Updates are verified by EdDSA signature against `SUPublicEDKey` in the
/// bundle before anything is installed. That check is what makes this an
/// update channel rather than a remote code execution channel, and it is not
/// optional: an unsigned appcast entry is refused even if the download
/// succeeds.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Whether the menu item should be tappable — Sparkle refuses to start a
    /// second check while one is in flight.
    @Published private(set) var canCheck = true

    init() {
        // Started by hand rather than by the initializer, because starting
        // with an unusable feed hangs the app before its first window: the
        // placeholder URL that ships in the repository until the appcast host
        // exists is exactly such a feed, and it took a launch that never drew
        // anything to find that out. Sparkle reports the failure by throwing
        // here; letting it throw during init leaves nothing to catch.
        //
        // No delegate: the standard behaviour — check on launch, then on
        // Sparkle's own interval — is what is wanted, and a delegate is one
        // more place a check can be silently suppressed.
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)

        guard Self.hasUsableFeed else {
            Self.logger.notice("no usable SUFeedURL; update checks are off for this build")
            return
        }
        do {
            try controller.updater.start()
        } catch {
            // A build that cannot check for updates is worth a log line and
            // nothing more. Refusing to launch over it would trade a missing
            // convenience for an unusable app.
            Self.logger.error("updater did not start: \(error, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "dev.m2na.backpocket", category: "updater")

    /// Whether `SUFeedURL` names somewhere Sparkle could actually ask.
    ///
    /// The repository carries a placeholder until the appcast host exists —
    /// `build.sh` refuses to make a release build while it is still there,
    /// but development builds run with it every day and must not hang.
    private static var hasUsableFeed: Bool {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !raw.hasPrefix("REPLACE_ME"),
            let url = URL(string: raw),
            url.scheme == "https" || url.scheme == "http"
        else { return false }
        return true
    }

    /// The menu item. Shows Sparkle's own UI, including "you're up to date",
    /// which a scheduled check deliberately stays silent about.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether Backpocket makes any unprompted request at all.
    ///
    /// Static, and reached without an `Updater` instance, because Settings
    /// needs it and the updater is owned by the menu-bar scene. It is stored
    /// in Sparkle's own defaults key — the one Sparkle reads when deciding
    /// whether to run a scheduled check — so the switch governs the request
    /// rather than merely describing it. A preference of our own would have
    /// been a switch that changed nothing.
    static var checksAutomatically: Bool {
        get { SPUUpdater.persistedAutomaticallyChecksForUpdates }
        set { SPUUpdater.persistedAutomaticallyChecksForUpdates = newValue }
    }
}

extension SPUUpdater {
    /// Sparkle stores this under its own key in standard defaults. Named here
    /// so the two accessors above cannot drift apart on a typo.
    fileprivate static var persistedAutomaticallyChecksForUpdates: Bool {
        get {
            // Absent means "never answered", and the bundle's
            // SUEnableAutomaticChecks says that answer is yes.
            UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks") }
    }
}
