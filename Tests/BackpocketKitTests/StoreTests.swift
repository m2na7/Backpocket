import AppKit
import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// No longer serialized: the store is told its overflow cap at init, so the
/// tests that need a particular limit no longer write it where every other
/// test can see it.
@MainActor
@Suite
struct StoreTests {
    private let store: Store
    private let container: ModelContainer
    private let source = CopySource(name: "TestApp", bundleID: "dev.test.app")
    private let limit = HistoryLimitBox()

    /// The cap the store reads, held in a box because the store exists before
    /// a test has said what it wants — and because a store built once must
    /// still follow a limit that changes, exactly as it does when the user
    /// changes it in Settings mid-session.
    @MainActor
    private final class HistoryLimitBox {
        var value = HistoryLimit.default.rawValue
    }

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        let limit = limit
        store = Store(context: ModelContext(container), disposableLimit: { limit.value })
    }

    private func item(_ content: String) throws -> Item {
        try #require(store.items.first { $0.content == content })
    }

    /// A fresh context sees only what actually reached the container, so a
    /// desync between the published array and the database cannot hide.
    private func persistedContents() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Item>()).map(\.content)
    }

    /// Real encoded bytes: addImage reads dimensions from the data, so a
    /// stub blob would be rejected as undecodable.
    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// `addImage` returns before the row exists — the digest runs off the main
    /// actor — so every image assertion below waits for the capture chain
    /// first. Suspending here is safe for the three tests that flip
    /// `setUsingFallbackStoreForTesting`: their bodies are synchronous and
    /// restore the flag through `defer` without ever yielding the main actor,
    /// so a test parked on this await can only ever resume to see it back off.
    private func addImage(_ png: Data, from source: CopySource? = nil) async {
        store.addImage(png, source: source ?? self.source)
        await store.imageCapturesDidFinish()
    }

    @Test func addInsertsNewestFirst() throws {
        store.add("older", source: source)
        // Back-to-back Date() calls can collide, making sort order flaky;
        // backdating pins the expected order.
        let older = try item("older")
        older.usedAt = Date(timeIntervalSinceNow: -60)
        store.add("newer", source: source)

        #expect(store.items.map(\.content) == ["newer", "older"])
    }

    @Test func addingIdenticalContentMovesExistingToTopWithoutDuplicating() throws {
        store.add("dup", source: CopySource(name: "Alpha", bundleID: "dev.test.alpha"))
        let original = try item("dup")
        original.usedAt = Date(timeIntervalSinceNow: -100)
        store.add("other", source: source)
        let other = try item("other")
        other.usedAt = Date(timeIntervalSinceNow: -50)

        store.add("dup", source: CopySource(name: "Beta", bundleID: "dev.test.beta"))

        #expect(store.items.count == 2)
        let top = try #require(store.items.first)
        #expect(top === original)
        #expect(top.sourceApp == "Beta")
        #expect(top.sourceBundleID == "dev.test.beta")
    }

    @Test func addTruncatesOversizedContent() throws {
        store.add(String(repeating: "a", count: 200_001), source: source)

        let stored = try #require(store.items.first)
        #expect(stored.content.count == 200_000)
    }

    @Test func addImageStoresDimensionsHashAndThumbnail() async throws {
        await addImage(try pngData(width: 4, height: 3))

        let image = try #require(store.items.first)
        #expect(image.isImage)
        #expect(image.content == "Image 4×3")
        #expect(image.imageHash != nil)
        #expect(image.thumbnailData != nil)
    }

    @Test func addingIdenticalImageMovesExistingToTopWithoutDuplicating() async throws {
        let png = try pngData(width: 4, height: 3)
        await addImage(png, from: CopySource(name: "Alpha", bundleID: "dev.test.alpha"))
        let original = try #require(store.items.first)
        original.usedAt = Date(timeIntervalSinceNow: -100)
        store.add("other", source: source)
        let other = try item("other")
        other.usedAt = Date(timeIntervalSinceNow: -50)

        await addImage(png, from: CopySource(name: "Beta", bundleID: "dev.test.beta"))

        #expect(store.items.count == 2)
        let top = try #require(store.items.first)
        #expect(top === original)
        #expect(top.sourceApp == "Beta")
        #expect(top.sourceBundleID == "dev.test.beta")
    }

    @Test func addImageWithDifferentDataCreatesSecondItem() async throws {
        await addImage(try pngData(width: 4, height: 3))
        await addImage(try pngData(width: 5, height: 5))

        #expect(store.items.count == 2)
        #expect(store.items.allSatisfy { $0.isImage })
    }

    // The capture chain. Digesting an image suspends, so two copies that arrive
    // before the first has landed are the case where an unserialized path would
    // quietly get both the order and the dedup wrong — and `items` is never
    // re-sorted, so a bad insert is permanent.

    @Test func imagesCopiedBackToBackAreRecordedInCopyOrder() async throws {
        // Sizes chosen so the two digests take visibly different times: run
        // concurrently, the small one finishes first and the big one lands on
        // top of it, which is the reverse of what the user copied.
        let big = try pngData(width: 900, height: 900)
        let small = try pngData(width: 4, height: 3)

        store.addImage(big, source: source)
        store.addImage(small, source: source)
        await store.imageCapturesDidFinish()

        #expect(store.items.map(\.content) == ["Image 4×3", "Image 900×900"])
    }

    @Test func recopyingAnImageStillBeingDigestedDoesNotDuplicateIt() async throws {
        let png = try pngData(width: 4, height: 3)

        store.addImage(png, source: CopySource(name: "Alpha", bundleID: "dev.test.alpha"))
        store.addImage(png, source: CopySource(name: "Beta", bundleID: "dev.test.beta"))
        await store.imageCapturesDidFinish()

        // Both captures would otherwise be hashing while the other ran its
        // dedup lookup, so neither would find the row the other was about to
        // insert and the same image would land twice.
        #expect(store.items.count == 1)
        let stored = try #require(store.items.first)
        #expect(stored.sourceApp == "Beta")
    }

    @Test func addNoteSetsIsNote() throws {
        store.addNote("remember this")

        let note = try #require(store.items.first)
        #expect(note.isNote)
    }

    @Test func convertToNoteFlipsClipInPlace() throws {
        store.add("clip", source: source)
        let clip = try item("clip")

        store.convertToNote(clip)

        let converted = try item("clip")
        #expect(converted === clip)
        #expect(converted.isNote)
    }

    @Test func convertToNoteIsNoOpOnNotes() throws {
        store.addNote("note")
        let note = try item("note")
        let aged = Date(timeIntervalSinceNow: -86_400)
        note.usedAt = aged

        store.convertToNote(note)

        #expect(note.isNote)
        // The guard must bail before touching usedAt, or converting an existing
        // note would silently reorder the list.
        #expect(note.usedAt == aged)
    }

    @Test func convertToNoteIsNoOpOnImages() async throws {
        await addImage(try pngData(width: 4, height: 3))
        let image = try #require(store.items.first)
        let aged = Date(timeIntervalSinceNow: -86_400)
        image.usedAt = aged

        store.convertToNote(image)

        // Notes are text; an image clip must never convert, and the guard
        // must bail before promote() reorders the list.
        #expect(!image.isNote)
        #expect(image.usedAt == aged)
    }

    @Test func adoptAsNoteConvertsClipAddsUnknownAndSkipsExistingNote() throws {
        store.add("clip", source: source)
        store.addNote("note")

        store.adoptAsNote("clip")
        store.adoptAsNote("dropped from outside")
        // Dragging a note onto its own column must not duplicate it.
        store.adoptAsNote("note")

        #expect(store.items.count == 3)
        #expect(try item("clip").isNote)
        #expect(try item("dropped from outside").isNote)
        #expect(store.items.filter { $0.content == "note" }.count == 1)
    }

    @Test func updateReplacesContentAndBumpsUsedAt() throws {
        store.add("before", source: source)
        let target = try item("before")
        let aged = Date(timeIntervalSinceNow: -3_600)
        target.usedAt = aged

        // The editor closes on true and stays open on false, so the answer is
        // the whole reason update returns one.
        #expect(store.update(target, content: "after"))

        #expect(target.content == "after")
        #expect(target.usedAt > aged)
    }

    @Test func pinnedItemsFloatAboveNewerUnpinnedOnes() throws {
        store.add("old but pinned", source: source)
        let pinned = try item("old but pinned")
        pinned.usedAt = Date(timeIntervalSinceNow: -3_600)
        store.togglePin(pinned)

        store.add("brand new", source: source)

        #expect(store.items.map(\.content) == ["old but pinned", "brand new"])
    }

    @Test func pinningResortsTheWholeListAroundTheFlippedFlag() throws {
        // The other pin test adds a new item after pinning, which lands by
        // insertion index and never runs the comparator. This one flips a pin
        // on an existing list, which is the path that does — and a comparator
        // that ignores the flag leaves the pinned clip wherever its age put
        // it, which is the bug a pin exists to prevent.
        store.add("oldest", source: source)
        store.add("middle", source: source)
        store.add("newest", source: source)
        #expect(store.items.map(\.content) == ["newest", "middle", "oldest"])

        store.togglePin(try item("oldest"))

        #expect(store.items.map(\.content) == ["oldest", "newest", "middle"])
    }

    @Test func anImageRefusesAContentEdit() async throws {
        // An image's content is a derived placeholder, so the editor must be
        // told the write did not happen rather than closing as if it had.
        await addImage(try pngData(width: 4, height: 4))
        let image = try #require(store.items.first { $0.isImage })

        #expect(store.update(image, content: "typed over the placeholder") == false)
        #expect(image.content != "typed over the placeholder")
    }

    @Test func togglePinFlips() throws {
        store.add("clip", source: source)
        let clip = try item("clip")
        #expect(!clip.isPinned)

        store.togglePin(clip)
        #expect(clip.isPinned)

        store.togglePin(clip)
        #expect(!clip.isPinned)
    }

    @Test func bulkDeleteRemovesEveryKindInOneWrite() throws {
        store.add("clip", source: source)
        store.add("https://example.com/page", source: source)
        store.addNote("note")
        store.add("survivor", source: source)

        let doomed = try [item("clip"), item("https://example.com/page"), item("note")]
        store.delete(doomed)

        #expect(store.items.map(\.content) == ["survivor"])
        // The published array and the database must agree — a stale row
        // would reappear on the next launch.
        #expect(try persistedContents() == ["survivor"])
    }

    @Test func notesAndPinnedItemsSurviveOverflowTrim() throws {
        try withHistoryLimit(100) {
            store.addNote("kept note")
            store.add("kept pin", source: source)
            store.togglePin(try item("kept pin"))
            for index in 0..<101 {
                store.add("clip \(index)", source: source)
            }

            // Without the isDisposable filter the trim would eat these two
            // first: they are the oldest rows in the array.
            #expect(store.items.contains { $0.content == "kept note" })
            #expect(store.items.contains { $0.content == "kept pin" })
            #expect(store.items.filter(\.isDisposable).count == 100)
        }
    }

    @Test func deleteRemoves() throws {
        store.add("doomed", source: source)
        let doomed = try item("doomed")

        store.delete(doomed)

        #expect(store.items.isEmpty)
    }

    @Test func purgeExpiredDeletesOnlyOldDisposables() throws {
        store.add("old clip", source: source)
        store.add("fresh clip", source: source)
        store.add("old pinned", source: source)
        store.addNote("old note")

        let thirtyDaysAgo = Date(timeIntervalSinceNow: -86_400 * 30)
        try item("old clip").usedAt = thirtyDaysAgo
        try item("old pinned").usedAt = thirtyDaysAgo
        try item("old note").usedAt = thirtyDaysAgo
        store.togglePin(try item("old pinned"))

        store.purgeExpired(days: 7)

        let contents = Set(store.items.map(\.content))
        #expect(!contents.contains("old clip"))
        #expect(contents.contains("fresh clip"))
        // Notes and pinned items surviving expiry is the product's core promise.
        #expect(contents.contains("old pinned"))
        #expect(contents.contains("old note"))
    }

    @Test func purgeExpiredZeroDaysDeletesNothing() throws {
        store.add("ancient", source: source)
        let ancient = try item("ancient")
        ancient.usedAt = Date(timeIntervalSinceNow: -86_400 * 365)

        store.purgeExpired(days: 0)

        #expect(store.items.count == 1)
    }

    /// The limit is a user preference, so a test must state it rather than
    /// inherit whatever the machine running the suite happens to have stored.
    private func withHistoryLimit<R>(_ value: Int, _ body: () throws -> R) rethrows -> R {
        limit.value = value
        defer { limit.value = HistoryLimit.default.rawValue }
        return try body()
    }

    /// Distinct ascending timestamps, all in the past: colliding Date() values
    /// would make "which item is oldest" nondeterministic.
    private func fillWithClips(_ count: Int) throws {
        let base = Date(timeIntervalSinceNow: -600)
        for index in 0..<count {
            store.add("clip-\(index)", source: source)
            let added = try item("clip-\(index)")
            added.usedAt = base.addingTimeInterval(Double(index))
        }
    }

    @Test func overflowTrimsToLimitDroppingOldest() throws {
        try withHistoryLimit(10) {
            try fillWithClips(10)

            store.add("clip-10", source: source)
            store.add("clip-11", source: source)

            #expect(store.items.count == 10)
            let contents = Set(store.items.map(\.content))
            #expect(!contents.contains("clip-0"))
            #expect(!contents.contains("clip-1"))
            #expect(contents.contains("clip-2"))
            #expect(contents.contains("clip-10"))
            #expect(contents.contains("clip-11"))
        }
    }

    @Test func anUnlimitedHistoryNeverTrims() throws {
        // Zero is the "unlimited" option; treating it as a limit of zero
        // would delete the whole history on the next copy.
        try withHistoryLimit(HistoryLimit.unlimited.rawValue) {
            try fillWithClips(20)

            #expect(store.items.count == 20)
        }
    }

    @Test func loweringTheLimitAppliesToTheVeryNextCopy() throws {
        // The store is built once at launch and lives for the session, so it
        // has to ask for the limit rather than remember it: someone who turns
        // the history down to keep less around expects the next copy to make
        // it true, not the next launch.
        try withHistoryLimit(20) {
            try fillWithClips(20)
            #expect(store.items.count == 20)

            withHistoryLimit(5) {
                store.add("after the change", source: source)
                #expect(store.items.count == 5)
                #expect(store.items.contains { $0.content == "after the change" })
            }
        }
    }

    @Test func imageItemsParticipateInTrimOverflow() async throws {
        // Recorded before the cap is lowered rather than inside the block: the
        // capture has to be awaited, and one image is under every limit anyway.
        await addImage(try pngData(width: 4, height: 3))

        try withHistoryLimit(10) {
            let image = try #require(store.items.first)
            image.usedAt = Date(timeIntervalSinceNow: -1_200)

            try fillWithClips(10)

            // The image is the oldest disposable, so crossing the limit must
            // evict it like any text clip.
            #expect(store.items.count == 10)
            #expect(!store.items.contains { $0.isImage })
        }
    }

    // The edit panel keeps its Item reference while open, so trim, expiry, or
    // a delete from the still-visible panel can pull the row out from under
    // it. Saving through that stale reference must not resurrect the model:
    // the ghost has no database row and would swallow future dedup matches.

    @Test func updateOnDeletedItemIsIgnored() throws {
        store.add("shared", source: source)
        let stale = try item("shared")
        store.delete(stale)

        #expect(store.update(stale, content: "edited") == false)

        #expect(store.items.isEmpty)

        store.add("shared", source: source)
        #expect(store.items.count == 1)
        #expect(try persistedContents() == ["shared"])
    }

    @Test func markUsedOnDeletedItemDoesNotResurrect() throws {
        store.add("shared", source: source)
        let stale = try item("shared")
        store.delete(stale)

        store.markUsed(stale)

        #expect(store.items.isEmpty)

        store.add("shared", source: source)
        #expect(store.items.count == 1)
        #expect(try persistedContents() == ["shared"])
    }

    @Test func convertToNoteOnDeletedItemDoesNotResurrect() throws {
        store.add("shared", source: source)
        let stale = try item("shared")
        store.delete(stale)

        store.convertToNote(stale)

        #expect(store.items.isEmpty)

        store.add("shared", source: source)
        #expect(store.items.count == 1)
        #expect(try persistedContents() == ["shared"])
    }

    @Test func clearHistoryRemovesOnlyDisposables() throws {
        store.add("clip", source: source)
        store.add("pinned", source: source)
        store.togglePin(try item("pinned"))
        store.addNote("note")

        store.clearHistory()

        #expect(Set(store.items.map(\.content)) == ["pinned", "note"])
        #expect(Set(try persistedContents()) == ["pinned", "note"])
    }

    @Test func clearNotesRemovesOnlyNotes() throws {
        store.add("clip", source: source)
        store.add("pinned", source: source)
        store.togglePin(try item("pinned"))
        store.addNote("note")

        store.clearNotes()

        #expect(Set(store.items.map(\.content)) == ["clip", "pinned"])
        #expect(Set(try persistedContents()) == ["clip", "pinned"])
    }

    @Test func clearAllEmptiesStoreAndDatabase() throws {
        store.add("clip", source: source)
        store.addNote("note")

        store.clearAll()

        #expect(store.items.isEmpty)
        #expect(try persistedContents().isEmpty)
    }

    @Test func mutationsKeepItemsAndDatabaseInSync() throws {
        for index in 0..<5 {
            store.add("clip-\(index)", source: source)
        }
        store.markUsed(try item("clip-2"))
        store.delete(try item("clip-4"))

        let published = Set(store.items.map(\.content))
        #expect(published == ["clip-0", "clip-1", "clip-2", "clip-3"])
        #expect(published == Set(try persistedContents()))
    }

    @Test func adoptAsNoteFilesANoteWhenTextMatchesAnImagePlaceholder() async throws {
        await addImage(try pngData(width: 4, height: 3))
        let placeholder = try #require(store.items.first?.content)

        // Dropping text that happens to equal the placeholder must file a
        // note, not silently bounce off the unconvertible image item.
        store.adoptAsNote(placeholder)

        #expect(store.items.filter(\.isNote).map(\.content) == [placeholder])
        #expect(store.items.contains { $0.isImage && !$0.isNote })
    }

    @Test func updateOnImageItemIsIgnored() async throws {
        await addImage(try pngData(width: 4, height: 3))
        let image = try #require(store.items.first)
        let placeholder = image.content

        store.update(image, content: "hacked")

        #expect(image.content == placeholder)
        #expect(image.isImage)
    }

    @Test func copyMatchingANoteRecordsAClipInsteadOfHijackingIt() throws {
        store.addNote("mailing address")

        store.add("mailing address", source: source)

        // The note keeps its identity; the copy lands as a separate clip.
        #expect(store.items.count == 2)
        let note = try #require(store.items.first { $0.isNote })
        #expect(note.sourceApp == nil)
        #expect(store.items.contains { !$0.isNote && $0.content == "mailing address" })
    }

    @Test func revisionBumpsOnInPlaceMutations() throws {
        store.add("top", source: source)
        let top = try #require(store.items.first)

        // Converting the item that is already first leaves the array
        // reference-equal — the revision is what tells views to refilter.
        let before = store.revision
        store.convertToNote(top)
        #expect(store.revision > before)

        let beforePin = store.revision
        store.togglePin(top)
        #expect(store.revision > beforePin)
    }

    @Test func reAddingTheContentAlreadyOnTopStillBumpsTheRevision() throws {
        store.add("top", source: source)
        let before = store.items
        let revision = store.revision

        store.add("top", source: source)

        // Nothing about the array changed — same count, same references, the
        // item was already first — so a view refiltering on `items` sees no
        // mutation at all. The revision is the only signal that the source
        // app and the flavors on that row were just rewritten.
        #expect(store.items.count == before.count)
        #expect(zip(store.items, before).allSatisfy { $0 === $1 })
        #expect(store.revision == revision + 1)
    }

    @Test func aPurgeThatDeletesNothingDoesNotBumpTheRevision() throws {
        store.add("fresh", source: source)
        let revision = store.revision

        store.purgeExpired(days: 7)

        // Expiry runs on a timer and on every panel open; bumping the counter
        // for a no-op would refilter every view on a schedule forever.
        #expect(store.revision == revision)
    }

    @Test func anInMemoryFallbackIsReportedFromTheMomentTheStoreOpens() throws {
        Persistence.setUsingFallbackStoreForTesting(true)
        defer { Persistence.setUsingFallbackStoreForTesting(false) }

        let fallback = Store(context: ModelContext(container))

        // The app looks completely normal on a fallback container: it records
        // all day and loses everything at quit. The flag is the only thing
        // that reaches the user, and it has to be up before the first write.
        #expect(fallback.hasStorageFailure)
    }

    @Test func aSuccessfulWriteCannotClearAFallbackStoreFailure() throws {
        Persistence.setUsingFallbackStoreForTesting(true)
        defer { Persistence.setUsingFallbackStoreForTesting(false) }

        let fallback = Store(context: ModelContext(container))
        fallback.add("clip", source: source)

        // Every write to an in-memory fallback "succeeds", so clearing the
        // flag on success would hide the failure permanently after one copy.
        #expect(fallback.hasStorageFailure)

        // It clears only once the store is genuinely backed again.
        Persistence.setUsingFallbackStoreForTesting(false)
        fallback.add("another", source: source)
        #expect(!fallback.hasStorageFailure)
    }

    @Test func aFailedWriteLeavesTheListAndTheDatabaseAgreeing() throws {
        store.add("kept", source: source)

        // The rollback path's whole purpose: whatever `items` publishes after
        // a write must be what a fresh read of the database returns. A
        // "Clear history" that reports success and hands every row back at
        // the next launch is worse than the failure itself.
        store.clearHistory()

        #expect(store.items.map(\.content) == (try persistedContents()))
        #expect(!store.hasStorageFailure)
    }

    @Test func aHealthyStoreNeverReportsAStorageFailure() throws {
        // The flag drives a UI warning that what the panel shows and what
        // survives a relaunch have diverged. It must stay off for ordinary
        // work, including the paths that delete.
        #expect(!store.hasStorageFailure)

        store.add("clip", source: source)
        store.addNote("note")
        store.delete(try item("clip"))
        store.clearAll()

        #expect(!store.hasStorageFailure)
    }

    @Test func plainRecopyKeepsCapturedRichFlavors() throws {
        store.add("styled", source: source, html: "<b>styled</b>", rtf: Data([0x7B]))
        store.add("styled", source: source)

        let styled = try item("styled")
        #expect(styled.contentHTML == "<b>styled</b>")
        #expect(styled.contentRTF == Data([0x7B]))

        // A later copy that does carry flavors still replaces them.
        store.add("styled", source: source, html: "<i>styled</i>")
        #expect(styled.contentHTML == "<i>styled</i>")
    }
}
