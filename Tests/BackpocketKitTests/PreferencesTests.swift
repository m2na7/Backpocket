import Foundation
import Testing

@testable import BackpocketKit

// No longer serialized: every test that needs a stored value binds a defaults
// database of its own through withScratchPreferences, so two of them running at
// once cannot see each other's writes.
@Suite("Preferences")
struct PreferencesTests {
    @Test func rowCountsClampToTheirRanges() throws {
        try withScratchPreferences { defaults in
            #expect(LinkRows.current == LinkRows.default)
            defaults.set(-3, forKey: PreferenceKey.linkRows)
            #expect(LinkRows.current == LinkRows.range.lowerBound)
            defaults.set(99, forKey: PreferenceKey.linkRows)
            #expect(LinkRows.current == LinkRows.range.upperBound)
        }
    }

    /// An untouched install must behave exactly as the shipped defaults say,
    /// and the Settings controls start from these same constants — so a
    /// fallback drifting away from its declared default shows up here before
    /// it can show up as a control that disagrees with the running app.
    @Test func everyPreferenceFallsBackToItsDeclaredDefault() throws {
        try withScratchPreferences { _ in
            #expect(PasteBehavior.isAutomatic == PasteBehavior.default)
            #expect(PreviewBehavior.isEnabled == PreviewBehavior.default)
            #expect(NotesVisibility.isEnabled == NotesVisibility.default)
            #expect(FaviconFetching.isEnabled == FaviconFetching.default)
            #expect(PopupPosition.current == PopupPosition.default)
            #expect(LinkCollection.current == LinkCollection.default)
            #expect(LinkClickAction.current == LinkClickAction.default)
            #expect(AppLanguage.current == AppLanguage.default)
            #expect(LinkRows.current == LinkRows.default)
            #expect(HistoryLimit.current == HistoryLimit.default.rawValue)
            #expect(ExpiryOption.current == ExpiryOption.default.rawValue)
            #expect(NotesFraction.current == NotesFraction.default)
            #expect(PanelSize.stored == nil)
            #expect(IgnoredApps.bundleIDs.isEmpty)
        }
    }

    /// The values themselves, pinned: what a fresh install does is a product
    /// decision, and the test above would happily agree with a changed one.
    @Test func theShippedDefaultsAreWhatTheyHaveAlwaysBeen() {
        // The one default that differs by distribution: the App Store build
        // cannot ask for the Accessibility permission, so it ships with
        // automatic pasting off rather than on and silently inert.
        #if BACKPOCKET_MAS
        #expect(PasteBehavior.default == false)
        #else
        #expect(PasteBehavior.default == true)
        #endif
        #expect(PreviewBehavior.default == true)
        #expect(NotesVisibility.default == true)
        #expect(FaviconFetching.default == true)
        #expect(PopupPosition.default == .mouse)
        #expect(LinkCollection.default == .both)
        #expect(LinkClickAction.default == .paste)
        #expect(AppLanguage.default == .system)
        #expect(LinkRows.default == 5)
        #expect(HistoryLimit.default == .fiveHundred)
        #expect(ExpiryOption.default == .week)
    }

    /// "Reset everything" iterates PreferenceKey.all, so a key missing from it
    /// would quietly survive the reset — a custom shortcut still bound, a
    /// language override still in force. Writing every declared key and
    /// demanding an empty store afterwards is the only check that cannot be
    /// fooled by a list that has fallen behind.
    @Test func resettingEverythingLeavesNoPreferenceBehind() throws {
        try withScratchPreferences { defaults in
            for name in PreferenceName.allCases {
                defaults.set("set", forKey: name.rawValue)
            }
            for key in PanelShortcut.defaultsKeys {
                defaults.set("set", forKey: key)
            }
            // Not a real language tag: AppleLanguages also lives in the global
            // domain, which every store reads through, so the reset cannot make
            // the key absent here — only its own write can be shown to be gone.
            // A tag no machine can be configured with keeps that distinction
            // true whatever the box running the suite has set.
            defaults.set(["zz-Reset"], forKey: "AppleLanguages")

            PreferenceKey.resetAll()

            let leftover = PreferenceName.allCases.map(\.rawValue)
                .filter { defaults.object(forKey: $0) != nil }
            #expect(leftover.isEmpty, "these keys outlived the reset: \(leftover)")
            #expect(PanelShortcut.defaultsKeys.allSatisfy { defaults.object(forKey: $0) == nil })
            #expect(defaults.array(forKey: "AppleLanguages") as? [String] != ["zz-Reset"])
        }
    }

    /// The guard on the injection itself. Every suite that dropped
    /// `.serialized` did so on the strength of reading a store of its own; if
    /// the accessors ever went back to the process-wide one those suites would
    /// still pass — writing and reading a single shared store agrees with
    /// itself — and would quietly be racing again. This is the one test that
    /// notices, because it checks both stores at once.
    @Test func preferencesReadTheInjectedStoreAndLeaveTheProcessOneAlone() throws {
        let key = PreferenceKey.linkRows
        let before = UserDefaults.standard.object(forKey: key) as? Int
        // Whatever this machine has stored, the injected value differs from it.
        let injected = before == 9 ? 8 : 9

        try withScratchPreferences { defaults in
            defaults.set(injected, forKey: key)
            #expect(LinkRows.current == injected)
            #expect(UserDefaults.standard.object(forKey: key) as? Int == before)
        }

        #expect(UserDefaults.standard.object(forKey: key) as? Int == before)
    }

    @Test func englishLanguageLabelIsSelfNamed() {
        #expect(AppLanguage.english.label == "English")
    }

    @Test func ignoredAppsDoesNotContainNilBundleID() {
        #expect(IgnoredApps.contains(nil) == false)
    }
}
