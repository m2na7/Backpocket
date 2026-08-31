import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Every user-facing preference, as cases rather than loose constants: the
/// reset list is derived from `allCases` below, so declaring a preference is
/// all it takes to have "Reset everything" wipe it. The hand-kept list this
/// replaces could silently skip whatever nobody remembered to add.
enum PreferenceName: String, CaseIterable {
    case hotKey = "hotKeyPreset"
    case expiryDays
    case language = "appLanguage"
    case pasteAutomatically
    case popupPosition
    case ignoredApps
    case historyLimit
    case showPreview
    case collectLinks
    case linkClick
    case fetchFavicons
    case hotKeyCode
    case hotKeyModifiers
    case linkRows
    case showNotes
    case panelWidth
    case panelHeight
    case notesFraction
}

/// The stored spellings, so call sites — `@AppStorage` in particular, which
/// needs a plain String — read exactly as they always have.
enum PreferenceKey {
    static let hotKey = PreferenceName.hotKey.rawValue
    static let expiryDays = PreferenceName.expiryDays.rawValue
    static let language = PreferenceName.language.rawValue
    static let pasteAutomatically = PreferenceName.pasteAutomatically.rawValue
    static let popupPosition = PreferenceName.popupPosition.rawValue
    static let ignoredApps = PreferenceName.ignoredApps.rawValue
    static let historyLimit = PreferenceName.historyLimit.rawValue
    static let showPreview = PreferenceName.showPreview.rawValue
    static let collectLinks = PreferenceName.collectLinks.rawValue
    static let linkClick = PreferenceName.linkClick.rawValue
    static let fetchFavicons = PreferenceName.fetchFavicons.rawValue
    static let hotKeyCode = PreferenceName.hotKeyCode.rawValue
    static let hotKeyModifiers = PreferenceName.hotKeyModifiers.rawValue
    static let linkRows = PreferenceName.linkRows.rawValue
    static let showNotes = PreferenceName.showNotes.rawValue
    static let panelWidth = PreferenceName.panelWidth.rawValue
    static let panelHeight = PreferenceName.panelHeight.rawValue
    static let notesFraction = PreferenceName.notesFraction.rawValue

    /// Everything "Reset everything" wipes. Derived, like
    /// `PanelShortcut.defaultsKeys`, so it cannot fall behind the preferences
    /// it is meant to cover.
    static var all: [String] {
        PreferenceName.allCases.map(\.rawValue) + PanelShortcut.defaultsKeys
    }

    /// Puts the app back to a fresh install's preferences. `AppleLanguages` is
    /// not ours but `AppLanguage.apply` writes it, so leaving it behind would
    /// keep the UI in a language the reset just forgot choosing.
    static func resetAll(in defaults: UserDefaults = PreferenceStore.defaults) {
        for key in all {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "AppleLanguages")
    }
}

/// The defaults database every preference in this file reads and writes.
///
/// Injection is a task-local rather than a settable global because the reason
/// to inject at all is testing, and swift-testing runs suites in parallel: one
/// suite assigning a global would leak its throwaway store into another suite's
/// reads, which is the race an override is supposed to remove. A task-local is
/// visible only inside the body that bound it, so two suites can hold two
/// different stores at the same moment without meeting.
///
/// Reads are safe from any isolation — `UserDefaults` is thread-safe, and
/// reading a task-local is too — which matters because preferences are read
/// from the main actor and from the watcher's nonisolated polling alike.
enum PreferenceStore {
    #if DEBUG
    /// `UserDefaults` is thread-safe but not `Sendable`; the box carries it
    /// past that check rather than around any real guarantee.
    private struct Box: @unchecked Sendable {
        let defaults: UserDefaults
    }

    @TaskLocal private static var injected: Box?

    static var defaults: UserDefaults { injected?.defaults ?? .standard }

    /// Runs `body` with every preference read and write pointed at `defaults`.
    static func withDefaults<R>(_ defaults: UserDefaults, _ body: () throws -> R) rethrows -> R {
        try $injected.withValue(Box(defaults: defaults), operation: body)
    }

    /// The same for a body that suspends. The binding follows the task across
    /// an await, and `isolation` keeps the body on the caller's actor rather
    /// than making it something that has to be handed off.
    static func withDefaults<R>(
        _ defaults: UserDefaults,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await $injected.withValue(
            Box(defaults: defaults),
            operation: body,
            isolation: isolation
        )
    }
    #else
    static var defaults: UserDefaults { .standard }
    #endif
}

enum HistoryLimit: Int, CaseIterable, Identifiable {
    case hundred = 100
    case fiveHundred = 500
    case thousand = 1000
    /// Zero disables trimming.
    case unlimited = 0

    /// Declared once and read by both this accessor and the Settings control,
    /// so the two cannot disagree about what an untouched install means.
    static let `default` = HistoryLimit.fiveHundred

    static var current: Int {
        PreferenceStore.defaults.object(forKey: PreferenceKey.historyLimit) as? Int
            ?? `default`.rawValue
    }

    var id: Int { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .hundred: "limit.100"
        case .fiveHundred: "limit.500"
        case .thousand: "limit.1000"
        case .unlimited: "limit.unlimited"
        }
    }
}

enum PreviewBehavior {
    static let `default` = true

    static var isEnabled: Bool {
        PreferenceStore.defaults.object(forKey: PreferenceKey.showPreview) as? Bool ?? `default`
    }
}

/// Whether the notes column is part of the panel at all. On by default —
/// the search field doubling as note entry is the app's premise — but a
/// clipboard-only panel is a legitimate way to want it.
enum NotesVisibility {
    static let `default` = true

    static var isEnabled: Bool {
        PreferenceStore.defaults.object(forKey: PreferenceKey.showNotes) as? Bool ?? `default`
    }
}

/// The panel's own frame, once the user has dragged an edge. Absent until
/// then, so a fresh install still opens at the row-count default.
enum PanelSize {
    static let minWidth: CGFloat = 480
    static let minHeight: CGFloat = 220

    static var stored: CGSize? {
        let defaults = PreferenceStore.defaults
        guard
            let width = defaults.object(forKey: PreferenceKey.panelWidth) as? Double,
            let height = defaults.object(forKey: PreferenceKey.panelHeight) as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    static func store(_ size: CGSize) {
        let defaults = PreferenceStore.defaults
        defaults.set(Double(size.width), forKey: PreferenceKey.panelWidth)
        defaults.set(Double(size.height), forKey: PreferenceKey.panelHeight)
    }

    static func forget() {
        let defaults = PreferenceStore.defaults
        defaults.removeObject(forKey: PreferenceKey.panelWidth)
        defaults.removeObject(forKey: PreferenceKey.panelHeight)
    }
}

/// How much of the panel's width the notes column takes. Clamped so neither
/// side can be dragged away entirely.
enum NotesFraction {
    static let range: ClosedRange<CGFloat> = 0.2...0.65
    static let `default`: CGFloat = 0.35

    static var current: CGFloat {
        let defaults = PreferenceStore.defaults
        guard let stored = defaults.object(forKey: PreferenceKey.notesFraction) as? Double
        else { return `default` }
        return min(max(CGFloat(stored), range.lowerBound), range.upperBound)
    }

    static func store(_ fraction: CGFloat) {
        PreferenceStore.defaults.set(
            Double(min(max(fraction, range.lowerBound), range.upperBound)),
            forKey: PreferenceKey.notesFraction
        )
    }
}

/// How many rows the links section shows when links are collected separately.
enum LinkRows {
    static let range = 3...10
    static let `default` = 5

    static var current: Int {
        let stored =
            PreferenceStore.defaults.object(forKey: PreferenceKey.linkRows) as? Int ?? `default`
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// Whether URL-only clips are filed under their own section in the panel.
/// On by default: the links section is the feature's face — hiding it behind
/// a setting made fresh installs look like it does not exist.
enum LinkCollection: String, CaseIterable, Identifiable {
    /// No links section at all — a link is an ordinary clip.
    case keep
    /// The links section holds them, and the clipboard list does not.
    case separate
    /// Both lists carry them. The default: a link taken out of the clipboard
    /// list vanishes from the place the user just watched it land, and the
    /// section is meant to be a second way to reach it, not the only way.
    case both

    static let `default` = LinkCollection.both

    static var current: LinkCollection {
        let raw = PreferenceStore.defaults.string(forKey: PreferenceKey.collectLinks)
        return raw.flatMap(LinkCollection.init) ?? `default`
    }

    /// Whether the panel has a links section — which is what decides the pane
    /// order, the clips header and the first-run height. Distinct from
    /// `movesLinksOut` on purpose: `both` shows the section without emptying
    /// the clipboard list, and one bool cannot say that.
    var showsLinks: Bool { self != .keep }

    /// Whether a link is taken OUT of the clipboard list to get there.
    var movesLinksOut: Bool { self == .separate }

    static var showsLinks: Bool { current.showsLinks }

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .keep: "linkcollect.keep"
        case .separate: "linkcollect.separate"
        case .both: "linkcollect.both"
        }
    }
}

/// What a plain click on a link row does. Enter always pastes and ⌘-click
/// always collects — only the mouse's primary action is a matter of taste.
enum LinkClickAction: String, CaseIterable, Identifiable {
    case paste
    case open

    static let `default` = LinkClickAction.paste

    static var current: LinkClickAction {
        let raw = PreferenceStore.defaults.string(forKey: PreferenceKey.linkClick)
        return raw.flatMap(LinkClickAction.init) ?? `default`
    }

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .paste: "ctx.paste"
        case .open: "ctx.openLink"
        }
    }
}

/// Whether picking an item pastes into the frontmost app or only copies.
enum PasteBehavior {
    static let `default` = true

    /// When off, content only lands on the clipboard. This is the escape hatch
    /// that keeps the app usable without the Accessibility permission.
    static var isAutomatic: Bool {
        PreferenceStore.defaults.object(forKey: PreferenceKey.pasteAutomatically) as? Bool
            ?? `default`
    }
}

/// Where the panel appears when summoned.
enum PopupPosition: String, CaseIterable, Identifiable {
    case mouse
    case center

    static let `default` = PopupPosition.mouse

    static var current: PopupPosition {
        let raw = PreferenceStore.defaults.string(forKey: PreferenceKey.popupPosition)
        return raw.flatMap(PopupPosition.init) ?? `default`
    }

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .mouse: "popup.mouse"
        case .center: "popup.center"
        }
    }
}

/// Copies made inside these apps are never recorded.
/// Password managers flag their own pasteboard entries, but far more apps
/// never flag anything.
enum IgnoredApps {
    static var bundleIDs: [String] {
        get { PreferenceStore.defaults.stringArray(forKey: PreferenceKey.ignoredApps) ?? [] }
        set { PreferenceStore.defaults.set(newValue, forKey: PreferenceKey.ignoredApps) }
    }

    /// Removes the key rather than storing an empty array, so a reset leaves
    /// the preference absent exactly as a fresh install has it.
    static func reset() {
        PreferenceStore.defaults.removeObject(forKey: PreferenceKey.ignoredApps)
    }

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    static func name(for bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
        else { return bundleID }
        return name
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// How many days a disposable clip survives before cleanup.
enum ExpiryOption: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30
    case never = 0

    static let `default` = ExpiryOption.week

    static var current: Int {
        PreferenceStore.defaults.object(forKey: PreferenceKey.expiryDays) as? Int
            ?? `default`.rawValue
    }

    var id: Int { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .week: "retention.7"
        case .twoWeeks: "retention.14"
        case .month: "retention.30"
        case .never: "retention.never"
        }
    }
}

/// The UI language override, independent of the system locale.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case chinese = "zh-Hans"

    static let `default` = AppLanguage.system

    static var current: AppLanguage {
        let raw = PreferenceStore.defaults.string(forKey: PreferenceKey.language)
        return raw.flatMap(AppLanguage.init) ?? `default`
    }

    /// The language the bundle actually loaded. Touched at launch, before
    /// Settings — or a reset — can change the stored value, so "a relaunch is
    /// pending" is a comparison against what is running rather than against
    /// the last thing written.
    static let atLaunch = AppLanguage.current

    /// Whether the picked language differs from the one the app is running in,
    /// i.e. whether a relaunch would actually change anything.
    ///
    /// Takes the running language as an argument rather than reading
    /// `atLaunch`: that is a lazy `static let` whose value is fixed by whoever
    /// touches it first, so a caller that read it here would decide for the
    /// whole process. A raw string that names no language cannot come from the
    /// picker, and counting it as changed is the harmless answer — a relaunch
    /// re-reads the store either way.
    static func restartPending(selection raw: String, running: AppLanguage) -> Bool {
        AppLanguage(rawValue: raw) != running
    }

    var id: String { rawValue }

    /// Each language is written in its own script — never make someone pick
    /// from names they cannot read.
    var label: String {
        switch self {
        case .system: String(localized: "settings.language.system")
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .chinese: "简体中文"
        }
    }

    /// What this choice means for the `AppleLanguages` override that decides
    /// which localization the bundle loads. `.system` is an absence rather
    /// than a value: writing "system" there would ask for a localization no
    /// `.lproj` provides, and the app would fall back to English for everyone
    /// who picked "System".
    var appleLanguagesOverride: [String]? {
        self == .system ? nil : [rawValue]
    }

    /// Bundle localization is fixed at launch, so a change here only takes
    /// effect after a restart.
    func apply() {
        let defaults = PreferenceStore.defaults
        defaults.set(rawValue, forKey: PreferenceKey.language)

        if let override = appleLanguagesOverride {
            defaults.set(override, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// Relaunches the app, e.g. after a language change.
enum AppRestart {
    static func now() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            // Quitting only makes sense once the replacement exists — on a
            // failed relaunch the running instance is all the user has.
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
