import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// No longer serialized: the reset-attempt defaults and the throwaway-store
/// flag are bound for the duration of one call rather than assigned, and
/// driving the open sequence reports its own outcome instead of writing the
/// flag the running app owns. Nothing here is left where a sibling can see it.
@MainActor
@Suite
struct MigrationTests {
    /// A directory of its own per test. The real store lives in Application
    /// Support and a test that reached it would set the user's notes aside.
    private final class TempDirectory {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "backpocket-migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            // Best effort: a test that chmods its directory read-only has to
            // hand permissions back before the tree can be removed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: url)
        }

        var storeURL: URL { url.appending(path: "Backpocket.store") }

        /// Every name under the directory, hidden ones included — the
        /// externalStorage blobs live in a dotted `_SUPPORT` sibling, and the
        /// backups the last-resort path makes are ordinary files next to it.
        func contents() -> [String] {
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? [])
                .map { $0.lastPathComponent }
                .sorted()
        }

        func backupNames() -> [String] {
            contents().filter { $0.hasSuffix(".bak") }
        }
    }

    /// Large enough that SwiftData really externalizes it: a handful of bytes
    /// stays inline in the row and the `_SUPPORT` directory this suite checks
    /// would never be created at all.
    private static let imageBlob = Data(repeating: 0xAB, count: 300_000)

    private let past = Date(timeIntervalSince1970: 1_600_000_000)
    private let older = Date(timeIntervalSince1970: 1_500_000_000)

    /// Writes the four kinds of row a real store holds, in the shape the
    /// previous release wrote them, and closes the store again. Scoped so the
    /// container is released before the caller reopens the same file.
    private func seedV3Store(at url: URL) throws {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: BackpocketSchemaV3.self), url: url)
        let container = try ModelContainer(
            for: BackpocketSchemaV3.Item.self, configurations: configuration)
        let context = ModelContext(container)

        let note = BackpocketSchemaV3.Item(content: "bank details", isNote: true)
        note.createdAt = older
        note.usedAt = older

        let pinned = BackpocketSchemaV3.Item(
            content: "pinned clip",
            isPinned: true,
            source: CopySource(name: "Alpha", bundleID: "dev.test.alpha")
        )
        pinned.createdAt = past
        pinned.usedAt = past

        let image = BackpocketSchemaV3.Item(
            content: "Image 4×3",
            source: CopySource(name: "Alpha", bundleID: "dev.test.alpha"),
            imageData: Self.imageBlob,
            thumbnailData: Data([0x89, 0x50]),
            imageHash: "deadbeef"
        )

        let clip = BackpocketSchemaV3.Item(
            content: "/Users/you/.ssh/id_rsa",
            source: CopySource(name: "Beta", bundleID: "dev.test.beta"),
            html: "<b>hi</b>",
            rtf: Data([0x7B])
        )

        for item in [note, pinned, image, clip] { context.insert(item) }
        try context.save()
    }

    private func fetchAll(_ container: ModelContainer) throws -> [Item] {
        try ModelContext(container).fetch(FetchDescriptor<Item>())
    }

    // MARK: Migrating

    @Test func aV3StoreMigratesWithEveryRowIntact() throws {
        let directory = try TempDirectory()
        try seedV3Store(at: directory.storeURL)

        let (container, _) = Persistence.makeContainerForTesting(at: directory.storeURL)
        let items = try fetchAll(container)

        // The regression this whole file exists for: until now, adding one
        // field moved the user's store aside and started empty, so a note
        // documented as permanent data did not survive an update.
        #expect(items.count == 4)

        let note = try #require(items.first { $0.isNote })
        #expect(note.content == "bank details")
        #expect(note.createdAt == older)
        #expect(note.usedAt == older)

        let pinned = try #require(items.first { $0.isPinned })
        #expect(pinned.content == "pinned clip")
        #expect(pinned.sourceApp == "Alpha")
        #expect(pinned.sourceBundleID == "dev.test.alpha")
        #expect(pinned.usedAt == past)

        let image = try #require(items.first { $0.isImage })
        #expect(image.imageHash == "deadbeef")
        #expect(image.imageData == Self.imageBlob)
        #expect(image.thumbnailData == Data([0x89, 0x50]))

        let clip = try #require(items.first { $0.content == "/Users/you/.ssh/id_rsa" })
        #expect(clip.contentHTML == "<b>hi</b>")
        #expect(clip.contentRTF == Data([0x7B]))
    }

    @Test func migratedRowsAreNeverFileCopies() throws {
        let directory = try TempDirectory()
        try seedV3Store(at: directory.storeURL)

        let (container, _) = Persistence.makeContainerForTesting(at: directory.storeURL)
        let items = try fetchAll(container)

        // V3 never recorded whether the pasteboard carried files, and the
        // seeded clip is the exact case that makes guessing dangerous: the
        // TEXT of a private key's path. Inferring file-ness from content
        // would make it paste the key instead of the path.
        #expect(items.allSatisfy { !$0.isFileCopy })
        let clip = try #require(items.first { $0.content == "/Users/you/.ssh/id_rsa" })
        #expect(clip.fileURLs.isEmpty)
    }

    @Test func migratingSetsNothingAside() throws {
        let directory = try TempDirectory()
        try seedV3Store(at: directory.storeURL)
        let support = directory.contents().filter { $0.contains("_SUPPORT") }
        #expect(!support.isEmpty, "the seeded image must really be externalized")

        _ = Persistence.makeContainerForTesting(at: directory.storeURL)

        // A successful migration must leave the filesystem alone. A `.bak`
        // appearing here would mean the destructive path ran anyway, which is
        // the same data loss wearing a different name.
        #expect(directory.backupNames().isEmpty)
        #expect(directory.contents().filter { $0.contains("_SUPPORT") } == support)
    }

    @Test func anAlreadyCurrentStoreOpensUntouched() throws {
        let directory = try TempDirectory()
        do {
            let container = try ModelContainer(
                for: Item.self, configurations: ModelConfiguration(url: directory.storeURL))
            let context = ModelContext(container)
            context.insert(Item(content: "already current", isFileCopy: true))
            try context.save()
        }

        let (container, _) = Persistence.makeContainerForTesting(at: directory.storeURL)
        let items = try fetchAll(container)

        #expect(items.map(\.content) == ["already current"])
        // The common launch: the store is at the current version, so there is
        // no migration to run and nothing to move.
        #expect(items.allSatisfy { $0.isFileCopy })
        #expect(directory.backupNames().isEmpty)
    }

    @Test func aFreshInstallOpensAnEmptyStore() throws {
        let directory = try TempDirectory()

        let (container, usedFallback) = Persistence.makeContainerForTesting(
            at: directory.storeURL)

        #expect(try fetchAll(container).isEmpty)
        #expect(!usedFallback)
        // Nothing existed to set aside, and the reset path must not have run
        // just because the file was missing.
        #expect(directory.backupNames().isEmpty)
    }

    @Test func everyAdjacentSchemaVersionHasAStage() throws {
        let versions = BackpocketMigrationPlan.schemas.map { $0.versionIdentifier }

        // A version added to `schemas` without a stage to reach it leaves a
        // store on that version unopenable, which drops it straight into the
        // last-resort path — the data loss this file exists to end, only
        // harder to notice because most launches still work.
        #expect(versions == versions.sorted())
        #expect(BackpocketMigrationPlan.stages.count == versions.count - 1)
        #expect(versions.last == BackpocketSchemaV4.versionIdentifier)
        // The last-resort path names its backups after this, so it has to
        // keep tracking the newest declared shape.
        #expect(Persistence.schemaVersion == BackpocketSchemaV4.versionIdentifier.major)
    }

    // MARK: The last resort

    /// Bytes SwiftData cannot make sense of. The migration plan has no answer
    /// for this — the file is not a store of any version — so it is the one
    /// case where setting the user's data aside is the only way to launch.
    private func writeUnreadableStore(at url: URL) throws {
        try Data("not a database".utf8).write(to: url)
    }

    @Test func anUnreadableStoreIsBackedUpNotDeleted() throws {
        let directory = try TempDirectory()
        try writeUnreadableStore(at: directory.storeURL)

        let (container, _) = Persistence.makeContainerForTesting(at: directory.storeURL)

        #expect(try fetchAll(container).isEmpty)
        // Notes are permanent data: even data that cannot be read today is
        // kept, because a later build or a hand repair may still recover it.
        let backups = directory.backupNames()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(
            try Data(contentsOf: directory.url.appending(path: backup))
                == Data("not a database".utf8))
    }

    /// Throwaway defaults, so the one-attempt guard can be driven without
    /// touching the bookkeeping the running app relies on.
    ///
    /// Named after the call site rather than a fresh UUID, and emptied on the
    /// way in: cfprefsd rewrites a suite's plist as the process exits whatever
    /// the cleanup asked for, so a per-run name would leave one more file in
    /// the developer's Preferences folder after every `swift test`.
    private func withResetDefaults(
        fileID: String = #fileID,
        line: Int = #line,
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let file = fileID.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        let name = "dev.m2na.backpocket.tests.\(file).\(line)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        try Persistence.withResetDefaultsForTesting(defaults) { try body(defaults) }
    }

    /// The short circuit that keeps a throwaway store out of the real
    /// bookkeeping. Nothing else covers it, and everything else in this file
    /// depends on it: without it, driving the reset path writes the attempt
    /// into the defaults of whoever ran `swift test` — and once that key is
    /// set, the *next* run finds the attempt already spent and the tests that
    /// expect a store to be set aside start failing on that machine alone.
    @Test func aThrowawayStoreNeverConsumesTheRealResetAttempt() throws {
        let key = "schemaResetAttempt"
        let before = UserDefaults.standard.object(forKey: key) as? Int

        let directory = try TempDirectory()
        try writeUnreadableStore(at: directory.storeURL)
        // A writable directory, so this really does reach the reset and would
        // record the attempt if the throwaway flag were not in force.
        _ = Persistence.makeContainerForTesting(at: directory.storeURL)

        #expect(UserDefaults.standard.object(forKey: key) as? Int == before)
    }

    @Test func theResetIsAttemptedOnlyOncePerVersion() throws {
        try withResetDefaults { defaults in
            let directory = try TempDirectory()
            try writeUnreadableStore(at: directory.storeURL)
            let path = directory.url.path(percentEncoded: false)

            // First launch, into a directory nothing can be moved within, so
            // the reset starts and cannot finish.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
            _ = Persistence.makeContainerForTesting(at: directory.storeURL)
            #expect(defaults.integer(forKey: "schemaResetAttempt") == Persistence.schemaVersion)
            #expect(directory.backupNames().isEmpty)

            // Second launch, and now the move WOULD succeed. Without the
            // guard this is the failure it was written for: a store that can
            // never be opened gets shuffled into a new differently-named .bak
            // at every launch, forever, until the user's data is spread across
            // a dozen files. One attempt per version is the whole contract.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            _ = Persistence.makeContainerForTesting(at: directory.storeURL)

            #expect(directory.backupNames().isEmpty)
            #expect(try Data(contentsOf: directory.storeURL) == Data("not a database".utf8))
        }
    }

    @Test func aStoreThatCannotBeSetAsideLeavesTheFilesAloneAndFallsBackToMemory() throws {
        let directory = try TempDirectory()
        try writeUnreadableStore(at: directory.storeURL)
        // A read-only directory is the move failing outright: the reset can
        // never finish, and the app has to survive that rather than refuse to
        // launch. The one-attempt guard itself is covered above; this test
        // reaches the reset every time by design.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.url.path(percentEncoded: false))

        let (container, usedFallback) = Persistence.makeContainerForTesting(
            at: directory.storeURL)

        // The app still launches — a clipboard manager that loses history
        // beats one that never opens — but the sequence reports the fallback,
        // which is what Store turns into the warning the user sees.
        #expect(try fetchAll(container).isEmpty)
        #expect(usedFallback)
        #expect(directory.backupNames().isEmpty)
        #expect(
            try Data(contentsOf: directory.storeURL) == Data("not a database".utf8))
    }
}
