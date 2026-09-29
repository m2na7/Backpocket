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
struct DeletionUndoTests: InMemoryStoreSuite {
    let container: ModelContainer
    let store: Store
    private let source = CopySource(name: "TestApp", bundleID: "dev.test.app")

    /// The shipped history limit, stated rather than read from the defaults
    /// of whoever runs the suite.
    init() throws {
        container = try Self.makeContainer()
        store = Store(
            context: ModelContext(container), disposableLimit: { HistoryLimit.default.rawValue })
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

    /// `Snapshot` promises to hold every stored attribute of `Item`: a field
    /// added to the model and forgotten there comes back blank from an undo.
    /// Read from the live schema, through the `Item` typealias rather than a
    /// named version, so the check moves with the model when a new one lands.
    @Test func theSnapshotHoldsEveryStoredAttribute() throws {
        let snapshot = DeletionUndo.Snapshot(Item(content: "x"))
        let entity = try #require(Schema([Item.self]).entities.first)

        #expect(Set(fields(of: snapshot).keys) == Set(entity.attributes.map(\.name)))
    }

    /// Every attribute, back as it was. Holding them all is half of it; the
    /// other half is `restored()` writing each one back, which the compiler
    /// cannot check for fields `Item.init` does not take.
    ///
    /// Comparing the rows before and after only catches a field that is not
    /// written back if the field held something a fresh row would not. So
    /// the rows here, an image that also carries rich text and a note, give
    /// every attribute such a value, and the first expectation holds them to
    /// it: a field added to the model fails here until it is given one.
    @Test func undoGivesBackEveryAttribute() async throws {
        store.addImage(try Fixture.png(width: 4, height: 3), source: source)
        await store.imageCapturesDidFinish()
        let image = try #require(store.items.first { $0.isImage })
        image.createdAt = Date(timeIntervalSinceNow: -86_400)
        image.usedAt = Date(timeIntervalSinceNow: -3_600)
        image.contentHTML = "<img>"
        image.contentRTF = Data([0x7B])
        image.isFileCopy = true
        store.togglePin(image)
        store.addNote("kept thought")
        let note = try item("kept thought")

        let before = [image, note].map { fields(of: DeletionUndo.Snapshot($0)) }
        let fresh = fields(of: DeletionUndo.Snapshot(Item(content: "x")))
        for name in fresh.keys {
            #expect(before.contains { $0[name] != fresh[name] }, "no row here sets \(name)")
        }

        store.delete([image, note])
        #expect(store.undoDelete())

        let restored = try [#require(store.items.first { $0.isImage }), item("kept thought")]
        #expect(restored.map { fields(of: DeletionUndo.Snapshot($0)) } == before)
        #expect(restored.first?.isImage == true)
        #expect(try persistedContents().count == 2)
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
        let deletedAt = ContinuousClock.now
        undo.record(deleted("gone"), at: deletedAt)

        #expect(undo.canUndo(asOf: deletedAt + DeletionUndo.window - .seconds(1)))
        #expect(!undo.canUndo(asOf: deletedAt + DeletionUndo.window + .seconds(1)))
        // Expired batches are dropped, not merely hidden: content the user
        // deleted must not sit in memory waiting for a caller to ask.
        #expect(undo.takeLatest(asOf: deletedAt + DeletionUndo.window + .seconds(1)) == nil)
        #expect(!undo.canUndo(asOf: deletedAt))
    }

    /// The window is a bound, not a length of time a delete may still reach
    /// past: the sweep Store's timer makes lands at exactly this instant,
    /// and nothing re-arms it, so the batch has to go at the boundary itself.
    @Test func theSweepAtTheEndOfTheWindowDropsTheDelete() {
        var undo = DeletionUndo()
        let deletedAt = ContinuousClock.now
        undo.record(deleted("gone"), at: deletedAt)

        #expect(undo.canUndo(asOf: deletedAt + DeletionUndo.window - .milliseconds(1)))
        let dropped = undo.forgetExpired(asOf: deletedAt + DeletionUndo.window)
        #expect(dropped)
        #expect(!undo.canUndo(asOf: deletedAt))
    }

    /// Store bumps `revision` for a sweep only when it dropped something,
    /// so that views refilter when an offered undo goes away and not on every
    /// timer that finds nothing to do. This answer is what decides it.
    @Test func aSweepReportsWhetherItDroppedAnything() {
        var undo = DeletionUndo()
        let deletedAt = ContinuousClock.now

        let emptySweep = undo.forgetExpired(asOf: deletedAt)
        #expect(!emptySweep)

        undo.record(deleted("gone"), at: deletedAt)
        let earlySweep = undo.forgetExpired(asOf: deletedAt + DeletionUndo.window - .seconds(1))
        #expect(!earlySweep)

        let dueSweep = undo.forgetExpired(asOf: deletedAt + DeletionUndo.window + .seconds(1))
        #expect(dueSweep)

        let repeatSweep = undo.forgetExpired(asOf: deletedAt + DeletionUndo.window + .seconds(1))
        #expect(!repeatSweep)
    }

    @Test func anExpiredDeleteDoesNotHandOutTheOneBehindIt() {
        var undo = DeletionUndo()
        let start = ContinuousClock.now
        undo.record(deleted("first"), at: start)
        undo.record(deleted("second"), at: start + DeletionUndo.window)

        // The second delete is still fresh, but reaching past it would restore
        // something the user deleted a window ago and has stopped expecting.
        let restorable = undo.takeLatest(asOf: start + DeletionUndo.window + .seconds(1))
        #expect(restorable?.map(\.content) == ["second"])
        #expect(undo.takeLatest(asOf: start + DeletionUndo.window + .seconds(1)) == nil)
    }

    /// What `Store` hands over when it records the delete of one row holding
    /// `content`.
    private func deleted(_ content: String) -> [DeletionUndo.Snapshot] {
        [DeletionUndo.Snapshot(Item(content: content))]
    }

    /// A snapshot's fields by name, as text that tells two values apart:
    /// `Data` spelled out in full rather than as its byte count, and a date
    /// to the fraction of a second rather than to the second.
    private func fields(of snapshot: DeletionUndo.Snapshot) -> [String: String] {
        var fields: [String: String] = [:]
        for case (let name?, let value) in Mirror(reflecting: snapshot).children {
            switch value {
            case let data as Data: fields[name] = data.base64EncodedString()
            case let date as Date: fields[name] = "\(date.timeIntervalSinceReferenceDate)"
            default: fields[name] = String(reflecting: value)
            }
        }
        return fields
    }
}
