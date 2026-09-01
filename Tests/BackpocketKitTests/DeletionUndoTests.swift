import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// Taking a delete back. A note is permanent user data and a clip may be the
/// only copy of something, so the contract is that undo returns the row the
/// user had — its age, its pin, its source app — and not a fresh capture of
/// the same text. The window and the depth are half the design: they are what
/// keeps this from becoming a shadow copy of everything deleted.
@MainActor
@Suite("Deletion undo")
struct DeletionUndoTests {
    private let store: Store
    private let container: ModelContainer
    private let source = CopySource(name: "TestApp", bundleID: "dev.test.app")

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        store = Store(context: ModelContext(container))
    }

    private func item(_ content: String) throws -> Item {
        try #require(store.items.first { $0.content == content })
    }

    /// A fresh context sees only what actually reached the container, so an
    /// undo that only fixed the published array cannot pass.
    private func persistedContents() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Item>()).map(\.content)
    }

    @Test func undoRestoresADeletedRow() throws {
        store.add("doomed", source: source)

        store.delete(try item("doomed"))
        #expect(store.items.isEmpty)

        #expect(store.canUndoDelete)
        #expect(store.undoDelete())

        #expect(store.items.map(\.content) == ["doomed"])
        #expect(try persistedContents() == ["doomed"])
    }

    @Test func undoRestoresTheRowAsItWasNotAsAFreshCopy() throws {
        store.add("old clip", source: source)
        let original = try item("old clip")
        let createdAt = Date(timeIntervalSinceNow: -86_400)
        original.createdAt = createdAt
        original.usedAt = Date(timeIntervalSinceNow: -3_600)
        original.contentHTML = "<b>old clip</b>"
        original.isFileCopy = true
        store.togglePin(original)
        let usedAt = original.usedAt
        store.add("newer clip", source: CopySource(name: "Other", bundleID: "dev.test.other"))

        store.delete(try item("old clip"))
        #expect(store.undoDelete())

        let restored = try item("old clip")
        // Re-adding it as a new capture would stamp both dates with now, drop
        // the pin, and lose the app it came from — which is the whole of what
        // the row was.
        #expect(restored.createdAt == createdAt)
        #expect(restored.usedAt == usedAt)
        #expect(restored.isPinned)
        #expect(restored.sourceApp == "TestApp")
        #expect(restored.sourceBundleID == "dev.test.app")
        #expect(restored.contentHTML == "<b>old clip</b>")
        #expect(restored.isFileCopy)
        // Pinned rows head the list, so a restore has to re-sort rather than
        // insert where a fresh copy would go.
        #expect(store.items.map(\.content) == ["old clip", "newer clip"])
    }

    @Test func undoRestoresANoteAsANote() throws {
        store.addNote("kept thought")

        store.delete(try item("kept thought"))
        #expect(store.undoDelete())

        // One table, one flag: a note that came back as a clip would start
        // expiring under the history limit that never applied to it.
        let restored = try item("kept thought")
        #expect(restored.isNote)
        #expect(!restored.isDisposable)
    }

    @Test func aBulkDeleteUndoesInOneStep() throws {
        for index in 0..<4 {
            store.add("clip \(index)", source: source)
            // Back-to-back Date() calls can collide; backdating pins the order
            // the restore then has to reproduce.
            let clip = try item("clip \(index)")
            clip.usedAt = Date(timeIntervalSinceNow: Double(index) - 10)
        }

        let doomed = try [item("clip 0"), item("clip 1"), item("clip 2")]
        store.delete(doomed)
        #expect(store.items.map(\.content) == ["clip 3"])

        #expect(store.undoDelete())

        // One action for the user is one step back, and each row lands at its
        // own age rather than in a block at the top.
        #expect(store.items.map(\.content) == ["clip 3", "clip 2", "clip 1", "clip 0"])
        #expect(try persistedContents().count == 4)
        // The handful is spent: a second undo has nothing behind it.
        #expect(!store.canUndoDelete)
        #expect(!store.undoDelete())
    }

    @Test func undoReachesOnlyAsFarBackAsTheStackIsDeep() throws {
        for index in 0..<4 {
            store.add("clip \(index)", source: source)
            store.delete(try item("clip \(index)"))
        }

        for _ in 0..<DeletionUndo.depth {
            #expect(store.undoDelete())
        }

        #expect(!store.undoDelete())
        // The oldest delete fell off the bottom, so its row is gone for good.
        #expect(!store.items.contains { $0.content == "clip 0" })
        #expect(store.items.count == DeletionUndo.depth)
    }

    @Test func undoingNothingChangesNothing() throws {
        store.add("clip", source: source)

        #expect(!store.canUndoDelete)
        #expect(!store.undoDelete())
        #expect(store.items.map(\.content) == ["clip"])
    }

    @Test func undoDoesNotReviveTheDeletedReference() throws {
        store.add("shared", source: source)
        let stale = try item("shared")

        store.delete(stale)
        #expect(store.undoDelete())

        // The restored row is a new model; the old reference is still the
        // ghost that would hijack dedup if a write brought it back.
        #expect(store.update(stale, content: "edited") == false)
        #expect(store.items.map(\.content) == ["shared"])
        #expect(try persistedContents() == ["shared"])
    }

    @Test func aDeleteStopsBeingRestorableOnceTheWindowHasClosed() {
        var undo = DeletionUndo()
        let deletedAt = Date()
        undo.record([Item(content: "gone")], at: deletedAt)

        #expect(undo.canUndo(asOf: deletedAt.addingTimeInterval(DeletionUndo.window - 1)))
        #expect(!undo.canUndo(asOf: deletedAt.addingTimeInterval(DeletionUndo.window + 1)))
        // Expired batches are dropped, not merely hidden: content the user
        // deleted must not sit in memory waiting for a caller to ask.
        #expect(undo.takeLatest(asOf: deletedAt.addingTimeInterval(DeletionUndo.window + 1)) == nil)
        #expect(!undo.canUndo(asOf: deletedAt))
    }

    @Test func anExpiredDeleteDoesNotHandOutTheOneBehindIt() {
        var undo = DeletionUndo()
        let start = Date()
        undo.record([Item(content: "first")], at: start)
        undo.record([Item(content: "second")], at: start.addingTimeInterval(DeletionUndo.window))

        // The second delete is still fresh, but reaching past it would restore
        // something the user deleted a window ago and has stopped expecting.
        let restorable = undo.takeLatest(asOf: start.addingTimeInterval(DeletionUndo.window + 1))
        #expect(restorable?.map(\.content) == ["second"])
        #expect(undo.takeLatest(asOf: start.addingTimeInterval(DeletionUndo.window + 1)) == nil)
    }
}
