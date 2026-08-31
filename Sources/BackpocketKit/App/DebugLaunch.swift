#if DEBUG
import Foundation

/// Launch arguments that drive the UI into a known state for screenshot-based
/// verification. Debug builds only — these must never ship.
///
///     Backpocket --open                 open the panel pinned to the top-left corner
///     Backpocket --open --edit          also open the note editor
///     Backpocket --open --settings      also open the settings window
///     Backpocket --open --query=text    pre-fill the search field
///     Backpocket --store=/tmp/demo      use a throwaway store (demo data, tests)
///     Backpocket --demo                 seed demo content into an empty store
enum DebugLaunch {
    static var openPanel: Bool { has("--open") }
    static var openEditor: Bool { has("--edit") }
    static var openSettings: Bool { has("--settings") }
    static var settingsTab: Int? { value(for: "--settings-tab").flatMap(Int.init) }
    static var query: String? { value(for: "--query") }
    static var storePath: String? { value(for: "--store") }
    /// Seeds representative items into an empty store, so screenshots and
    /// first-run demos have something real-looking to show.
    static var seedDemo: Bool { has("--demo") }
    /// Pre-collects the first N clips into the paste stack — the stack is
    /// interaction-only state a launch argument can't otherwise reach.
    static var stackCount: Int? { value(for: "--stack").flatMap(Int.init) }
    /// Renders the panel to a PNG and exits. Works even when no display is
    /// awake, so documentation screenshots are reproducible anywhere.
    static var snapshotPath: String? { value(for: "--snapshot") }

    private static func has(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag)
    }

    private static func value(for flag: String) -> String? {
        let prefix = flag + "="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }
}
#endif
