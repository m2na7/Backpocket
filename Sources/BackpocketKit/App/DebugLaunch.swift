#if DEBUG
import Foundation

/// Launch arguments that drive the UI into a known state for screenshot-based
/// verification. Debug builds only — these must never ship.
///
///     Backpocket --open                 open the panel pinned to the top-left corner
///     Backpocket --open --edit          also open the note editor
///     Backpocket --open --settings      also open the settings window
///     Backpocket --settings-tab=N       with --settings, open on tab N
///     Backpocket --open --query=text    pre-fill the search field
///     Backpocket --store=/tmp/demo      use a throwaway store (demo data, tests)
///     Backpocket --demo                 seed demo content into an empty store
///     Backpocket --stack=N              pre-collect the first N clips into the paste stack
///     Backpocket --snapshot=/tmp/x.png  render the panel to a PNG and exit
///
/// Store captures — App Store screenshots and previews — add:
///
///     Backpocket --capture              run isolated: no clipboard watch, hotkey or prompt
///     Backpocket --favicons=/tmp/icons  keep favicons in a cache of the capture's own
///     Backpocket --demo-lang=ko         seed the Korean demo content instead
///     Backpocket --note=text            add a note after seeding, as if just saved
///     Backpocket --adopt=text           drop the clip with this text on the notes column
///     Backpocket --pane=notes           focus a pane: clips, links or notes
///     Backpocket --select=N             select row N of that pane, so its card appears
///     Backpocket --shortcuts            show the numbers holding ⌘ shows
///     Backpocket --appearance=dark      draw dark or light, regardless of the system setting
///     Backpocket --snapshot-scale=3     with --snapshot-dir, render at 3 pixels per point
///     Backpocket --snapshot-dir=/tmp/x  render every open window to x, with frames
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

    /// A capture runs beside the copy the user actually uses, so it touches
    /// nothing of theirs: a copy made during it would otherwise land in the
    /// pictures, the installed copy already owns the global shortcut, and an
    /// Accessibility prompt would appear on every run.
    static var isCapture: Bool { has("--capture") }
    /// Where favicons are cached instead of the real cache, which a capture
    /// must neither read from nor add to.
    static var faviconCachePath: String? { value(for: "--favicons") }
    /// "ko" seeds the Korean demo content; anything else, the English.
    static var demoLanguage: String? { value(for: "--demo-lang") }
    /// Added after the demo seed, so it tops the notes column the way a note
    /// just saved from the field does.
    static var extraNote: String? { value(for: "--note") }
    /// What a drop on the notes column does to the clip carrying this text:
    /// the state the panel is in right after a drag-to-note.
    static var adoptText: String? { value(for: "--adopt") }
    static var pane: String? { value(for: "--pane") }
    /// Selected as the keyboard would select it, which is what lets the
    /// detail card grow against the row after the usual dwell.
    static var selectRow: Int? { value(for: "--select").flatMap(Int.init) }
    static var showsShortcuts: Bool { has("--shortcuts") }
    /// "dark" or "light", regardless of the system setting. The
    /// `-AppleInterfaceStyle` argument does not reach a running app.
    static var appearance: String? { value(for: "--appearance") }
    /// Each open window as its own PNG plus frames.json, for compositing:
    /// the detail card and the editor are windows of their own.
    static var snapshotDirectory: String? { value(for: "--snapshot-dir") }
    /// Pixels per point for `--snapshot-dir`, instead of the screen's own.
    static var snapshotScale: CGFloat? {
        value(for: "--snapshot-scale").flatMap(Double.init).map { CGFloat($0) }
    }

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
