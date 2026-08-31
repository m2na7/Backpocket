import Foundation
import OSLog
import SwiftData

/// Builds the SwiftData container Backpocket stores everything in.
enum Persistence {
    private static let logger = Logger(subsystem: "dev.m2na.backpocket", category: "persistence")

    /// The shape this build opens stores with. SwiftData tracks which version
    /// a store on disk actually is, so this is no longer a change detector —
    /// it only scopes the one last-resort reset attempt and names what that
    /// reset sets aside.
    static var schemaVersion: Int { BackpocketSchemaV4.versionIdentifier.major }

    /// True when `makeContainer` had to fall back to memory. Read by Store so
    /// the failure reaches the user instead of only the log: the app looks
    /// normal, records all day, and loses everything at quit.
    @MainActor private(set) static var isUsingFallbackStore = false

    #if DEBUG
    /// The fallback path only happens when the on-disk store cannot be
    /// opened, which a test cannot arrange without breaking the real store.
    /// Debug-only so the flag stays read-only in a shipping build.
    @MainActor static func setUsingFallbackStoreForTesting(_ value: Bool) {
        isUsingFallbackStore = value
    }

    /// Lets a test drive the real open / migrate / last-resort sequence
    /// against a throwaway path. Marked as throwaway for the same reason
    /// `--store=` is: it must not consume the real store's one reset attempt.
    ///
    /// Returns whether the sequence ended in memory instead of setting
    /// `isUsingFallbackStore`: that flag is the running app's, and a test
    /// writing it would be visible to every Store built in parallel.
    @MainActor static func makeContainerForTesting(
        at url: URL
    ) -> (container: ModelContainer, usedFallback: Bool) {
        $isThrowawayStore.withValue(true) { openOrRecover(at: url) }
    }

    /// Bound for the duration of one call rather than assigned, so a suite
    /// running in parallel with another cannot see — or clear — the flag a
    /// different test is relying on. Same reasoning as `PreferenceStore`.
    @TaskLocal private static var isThrowawayStore = false

    /// Throwaway defaults for the one-attempt guard, so a test can drive the
    /// guard itself instead of the app's real bookkeeping.
    ///
    /// Supplying this also disarms the throwaway-store short circuit below:
    /// a test that hands over its own defaults is testing the guard, not
    /// standing in for a `--store=` launch that must reset every time.
    static func withResetDefaultsForTesting<R>(
        _ defaults: UserDefaults,
        _ body: () throws -> R
    ) rethrows -> R {
        try $resetDefaultsOverride.withValue(DefaultsBox(defaults: defaults), operation: body)
    }

    /// `UserDefaults` is thread-safe but not `Sendable`; the box carries it
    /// past that check rather than around any real guarantee.
    private struct DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
    }

    @TaskLocal private static var resetDefaultsOverride: DefaultsBox?
    #endif

    /// Where the one-attempt guard records that it has already tried.
    @MainActor
    private static var resetDefaults: UserDefaults {
        #if DEBUG
        if let resetDefaultsOverride { return resetDefaultsOverride.defaults }
        #endif
        return .standard
    }

    /// Falls back to an in-memory container rather than failing to launch —
    /// a clipboard manager that loses history is better than one that never opens.
    @MainActor
    static func makeContainer() -> ModelContainer {
        let (container, usedFallback) = openOrRecover(at: storeURL())
        // The one place the app's flag is set from the real sequence. Kept out
        // of `openOrRecover` so that driving that sequence — which only a test
        // does, against a throwaway path — cannot rewrite what the running
        // app is telling the user about its own store.
        isUsingFallbackStore = usedFallback
        return container
    }

    /// Opens `url`, or recovers as far as it can, and reports whether it ended
    /// up in memory with the user's history left behind.
    @MainActor
    private static func openOrRecover(at url: URL) -> (ModelContainer, Bool) {
        // The path every ordinary launch takes, and the only one that touches
        // the filesystem at all: a fresh install, a store already at the
        // current version, and an older store the plan can carry forward all
        // open here, and nothing is moved aside.
        if let container = openStore(at: url) {
            return (container, false)
        }

        // Only now — the migration plan could not make this store openable —
        // may the destructive path run. It cannot help with a store that traps
        // instead of throwing (a version from a future build, say); nothing
        // can, because a trap is not catchable and this line is never reached.
        logger.error("store could not be opened or migrated; attempting one-time reset")

        guard setAsideUnopenableStore(at: url) else {
            logger.error("unopenable store could not be set aside; falling back to in-memory")
            return (memoryContainer(), true)
        }

        if let container = openStore(at: url) {
            return (container, false)
        }

        logger.error("persistent store failed to open after reset; falling back to in-memory")
        return (memoryContainer(), true)
    }

    private static func openStore(at url: URL) -> ModelContainer? {
        do {
            return try ModelContainer(
                for: Item.self,
                migrationPlan: BackpocketMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
        } catch {
            logger.error("store open failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// If even an in-memory container fails there is nothing left to try.
    private static func memoryContainer() -> ModelContainer {
        try! ModelContainer(
            for: Item.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// A dedicated path. The SwiftData default (`default.store`) is shared by
    /// every non-sandboxed SwiftData app, and colliding schemas trap on open.
    private static func storeURL() -> URL {
        #if DEBUG
        if let override = DebugLaunch.storePath {
            return URL(fileURLWithPath: override)
        }
        #endif

        let directory = URL.applicationSupportDirectory.appending(path: "Backpocket")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "Backpocket.store")
    }

    /// Last resort, reached only when the store would not open even with the
    /// migration plan: set the files aside so the app can start over on an
    /// empty one. Notes are permanent data, so nothing is ever deleted —
    /// what cannot be read today may still be recoverable by hand.
    ///
    /// Returns false when an unopenable store is still sitting at `url`, so
    /// the caller can leave it alone instead of opening it.
    @MainActor
    @discardableResult
    private static func setAsideUnopenableStore(at url: URL) -> Bool {
        // Recorded before the move, not after a successful open: recording
        // only success let a store that can never be opened (read-only
        // directory, full disk) re-run this at every launch, shuffling the
        // user's real data into a new differently-named .bak forever. One
        // attempt per target version is enough; a later version tries again.
        if !markResetAttempted() {
            return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        // Stamped, not just versioned: two resets can share a target version,
        // and a name that collides would overwrite the only copy of the
        // earlier notes.
        let stamp = Int(Date().timeIntervalSince1970)
        // percentEncoded: false, or "Application Support" comes back as
        // "Application%20Support" and every move silently misses.
        let path = url.path(percentEncoded: false)

        for suffix in ["", "-shm", "-wal"] {
            let sidecar = URL(fileURLWithPath: path + suffix)
            let backup = URL(fileURLWithPath: path + suffix + ".v\(schemaVersion)-\(stamp).bak")
            try? FileManager.default.moveItem(at: sidecar, to: backup)
        }

        // The externalStorage attributes (RTF, images, thumbnails) live in a
        // sibling directory; leaving it behind makes the backup unopenable
        // and orphans the blobs forever.
        let support = url.deletingLastPathComponent()
            .appending(path: "." + url.deletingPathExtension().lastPathComponent + "_SUPPORT")
        try? FileManager.default.moveItem(
            at: support,
            to: URL(
                fileURLWithPath: support.path(percentEncoded: false)
                    + ".v\(schemaVersion)-\(stamp).bak")
        )

        return !FileManager.default.fileExists(atPath: path)
    }

    /// Whether this launch owns the one reset attempt for `schemaVersion`.
    @MainActor
    private static func markResetAttempted() -> Bool {
        #if DEBUG
        // A throwaway store must keep resetting on every launch, and must not
        // consume the real store's attempt: same reasoning as the stamp.
        // Skipped when a test supplies its own defaults — that test is here
        // for the guard, and short-circuiting would make it prove nothing.
        if resetDefaultsOverride == nil, DebugLaunch.storePath != nil || isThrowawayStore {
            return true
        }
        #endif

        let defaults = resetDefaults
        guard defaults.integer(forKey: schemaResetKey) != schemaVersion else { return false }
        defaults.set(schemaVersion, forKey: schemaResetKey)
        return true
    }

    private static let schemaResetKey = "schemaResetAttempt"
}
