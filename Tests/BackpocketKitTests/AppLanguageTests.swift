import Foundation
import Testing

@testable import BackpocketKit

/// Switching the UI language writes two things — the app's own preference and
/// the `AppleLanguages` override the bundle loads from — and then claims a
/// relaunch is pending. Every part of that failed silently: a wrong override
/// shows English to someone who picked Korean, and a wrong "pending" either
/// nags forever or never offers the restart that would apply the change.
///
/// Nothing here reads `AppLanguage.atLaunch`. It is a lazy `static let` fixed
/// by whoever touches it first, so a test that read it would decide its value
/// for every later test in the process — and could capture a scratch store's
/// language while doing it. `restartPending` takes the running language as an
/// argument for exactly this reason, which is what makes it testable at all.
@Suite struct AppLanguageTests {
    // MARK: The AppleLanguages override

    /// "System" is an absence, not a value. Writing "system" into
    /// `AppleLanguages` asks the bundle for an `.lproj` that does not exist,
    /// and everyone who picked System gets English.
    @Test func systemRemovesTheOverrideRatherThanStoringItsOwnName() throws {
        try withScratchPreferences { defaults in
            // `AppleLanguages` lives in the global domain, which every suite
            // reads through, so a removal cannot show up here as nil — it
            // shows up as the inherited value coming back. Sampling it first
            // is what makes the difference observable.
            let inherited = defaults.stringArray(forKey: "AppleLanguages")
            defaults.set(["ko"], forKey: "AppleLanguages")
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ko"])

            AppLanguage.system.apply()

            #expect(AppLanguage.system.appleLanguagesOverride == nil)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == inherited)
            #expect(defaults.string(forKey: PreferenceKey.language) == "system")
        }
    }

    @Test func pickingALanguageWritesBothThePreferenceAndTheOverride() throws {
        try withScratchPreferences { defaults in
            AppLanguage.korean.apply()

            #expect(defaults.string(forKey: PreferenceKey.language) == "ko")
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ko"])
        }
    }

    /// The override has to name the same code the `.lproj` directory does, for
    /// every language the picker offers — `zh-Hans` being the one that is not
    /// simply a two-letter code.
    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func everyOfferedLanguageOverridesWithItsOwnBundleCode(_ language: AppLanguage) {
        #expect(language.appleLanguagesOverride == [language.rawValue])
    }

    /// Switching away from one language must not leave the previous override
    /// behind alongside the new one.
    @Test func switchingLanguagesReplacesTheOverride() throws {
        try withScratchPreferences { defaults in
            AppLanguage.japanese.apply()
            AppLanguage.chinese.apply()

            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
            #expect(AppLanguage.current == .chinese)
        }
    }

    // MARK: Whether a relaunch is pending

    @Test func pickingTheRunningLanguageLeavesNothingPending() {
        #expect(!AppLanguage.restartPending(selection: "ko", running: .korean))
        #expect(!AppLanguage.restartPending(selection: "system", running: .system))
    }

    @Test func pickingAnotherLanguageLeavesARelaunchPending() {
        #expect(AppLanguage.restartPending(selection: "ja", running: .korean))
        #expect(AppLanguage.restartPending(selection: "system", running: .english))
    }

    /// The comparison is against what is running, not against what is stored.
    /// Picking a language and then picking the original one back has to clear
    /// the restart offer — a latched flag would keep offering a relaunch that
    /// would change nothing.
    @Test func pickingBackToTheRunningLanguageClearsTheOffer() {
        let running = AppLanguage.english
        #expect(AppLanguage.restartPending(selection: "ko", running: running))
        #expect(!AppLanguage.restartPending(selection: "en", running: running))
    }

    /// "Reset everything" removes the stored language without going through
    /// the picker, so the pane re-reads and compares the default against the
    /// running language. On an install that had switched away, that is a real
    /// pending relaunch and the offer has to appear.
    @Test func aResetBackToSystemStillOffersTheRelaunch() throws {
        try withScratchPreferences { _ in
            AppLanguage.korean.apply()
            PreferenceKey.resetAll()

            #expect(AppLanguage.current == .system)
            #expect(AppLanguage.restartPending(selection: "system", running: .korean))
        }
    }
}
