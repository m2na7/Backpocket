import Foundation
import Testing

@testable import BackpocketKit

/// Runs `body` with every preference read and write pointed at a defaults
/// database belonging to this call site alone, emptied before the body runs.
///
/// Suites run in parallel, so a test that wrote the process-wide defaults could
/// have its value replaced mid-test by any other test touching the same key —
/// and a test that only read one still saw whatever a writer left. Neither is
/// possible here: no other call site shares this store, and the binding is
/// task-local, so it is not visible outside this call even while in effect.
///
/// The name is derived from the call site rather than a fresh UUID because
/// `UserDefaults(suiteName:)` always leaves a plist behind in the user's
/// Preferences folder — `removePersistentDomain`, `removeSuite`, and deleting
/// the file all lose to cfprefsd, which rewrites it as the process exits. A
/// per-run name would therefore add a file to every developer's machine on
/// every test run, forever; a per-call-site name reuses the same handful of
/// files instead. That makes leftovers from the last run the thing to defend
/// against, which is why the store is cleared on the way in and not trusted to
/// be clean on the way out.
///
/// One call site must not run concurrently with itself: pass a distinct
/// `discriminator` from a parameterized test, whose cases can run in parallel.
func withScratchPreferences<R>(
    discriminator: String = "",
    fileID: String = #fileID,
    line: Int = #line,
    _ body: (UserDefaults) throws -> R
) throws -> R {
    let name = scratchSuiteName(fileID, line, discriminator)
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    return try PreferenceStore.withDefaults(defaults) { try body(defaults) }
}

/// The same, for a body that suspends. A task-local stays bound across an
/// await inside the operation, so the store outlives the suspension.
func withScratchPreferences<R>(
    discriminator: String = "",
    fileID: String = #fileID,
    line: Int = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (UserDefaults) async throws -> R
) async throws -> R {
    let name = scratchSuiteName(fileID, line, discriminator)
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    return try await PreferenceStore.withDefaults(defaults, isolation: isolation) {
        try await body(defaults)
    }
}

/// A filename-safe name that is the same on every run from the same call site.
private func scratchSuiteName(_ fileID: String, _ line: Int, _ discriminator: String) -> String {
    let file = fileID.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    let suffix = discriminator.isEmpty ? "" : ".\(discriminator)"
    return "dev.m2na.backpocket.tests.\(file).\(line)\(suffix)"
}
