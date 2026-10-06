import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

@MainActor
@Suite struct NoteImportTests: InMemoryStoreSuite {
    let container: ModelContainer
    let store: Store

    init() throws {
        container = try Self.makeContainer()
        store = Store(context: ModelContext(container))
    }

    @Test func migrationPreservesNotesAndMetadataAcrossSeparateStores() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(
                path: "backpocket-transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let free = try ModelContainer(
            for: Item.self,
            configurations: ModelConfiguration(url: directory.appending(path: "free.store")))
        let source = ModelContext(free)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Item(content: "한글 메모\n😀 \"quoted\"", isNote: true)
        note.createdAt = date
        note.usedAt = date.addingTimeInterval(60)
        note.isPinned = true
        source.insert(note)
        let long = Item(content: String(repeating: "한", count: 70_000), isNote: true)
        source.insert(long)
        let clip = Item(content: "clipboard-only")
        source.insert(clip)
        try source.save()
        let archiveURL = directory.appending(path: "notes.json")
        try NoteExport(items: [note, long, clip]).encoded().write(to: archiveURL, options: .atomic)

        let paidURL = directory.appending(path: "paid.store")
        let paid = try ModelContainer(
            for: Item.self, configurations: ModelConfiguration(url: paidURL))
        let destination = Store(context: ModelContext(paid))
        let result = try destination.importNotes(NoteExport.read(from: archiveURL))
        #expect(result == NoteImportResult(imported: 2, skipped: 0))

        let reopened = try ModelContainer(
            for: Item.self, configurations: ModelConfiguration(url: paidURL))
        let restored = try ModelContext(reopened).fetch(FetchDescriptor<Item>())
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.isNote })
        let pinned = try #require(restored.first { $0.isPinned })
        #expect(pinned.content == note.content)
        #expect(pinned.createdAt == date)
        #expect(pinned.usedAt == date.addingTimeInterval(60))
        #expect(restored.contains { $0.content == long.content })
        // The source and backup remain intact after migration.
        #expect(try source.fetch(FetchDescriptor<Item>()).count == 3)
        #expect(try NoteExport.read(from: archiveURL).notes.count == 2)
    }

    @Test func reimportSkipsMatchesWithoutOverwritingExistingNotesOrCollapsingTwins() throws {
        store.addNote("already in the paid version")
        let existing = try #require(store.items.first)
        let before = existing.usedAt
        let first = Item(content: "same content", isNote: true)
        let second = Item(content: "same content", isNote: true)
        first.createdAt = Date(timeIntervalSince1970: 1_700_000_000.1)
        second.createdAt = Date(timeIntervalSince1970: 1_700_000_000.9)
        let archive = try NoteExport.decoded(NoteExport(items: [first, second]).encoded())
        #expect(try store.importNotes(archive) == NoteImportResult(imported: 2, skipped: 0))
        let imported = try #require(store.items.first { $0.content == "same content" })
        store.togglePin(imported)

        let revision = store.revision
        #expect(try store.importNotes(archive) == NoteImportResult(imported: 0, skipped: 2))
        #expect(store.revision == revision)
        #expect(store.items.count == 3)
        #expect(imported.isPinned)
        #expect(existing.content == "already in the paid version")
        #expect(existing.usedAt == before)
    }

    @Test func importingIntoTheSourceStoreSkipsItsFractionalDateMatches() throws {
        store.addNote("original note")
        let archive = try NoteExport.decoded(NoteExport(items: store.items).encoded())
        #expect(try store.importNotes(archive) == NoteImportResult(imported: 0, skipped: 1))
        #expect(store.items.count == 1)
    }

    @Test func unknownVersionsAndMalformedFilesLeaveTheStoreAlone() throws {
        store.addNote("keep me")
        let unsupported = Data(
            #"{"formatVersion":2,"exportedAt":"2026-01-01T00:00:00Z","notes":[]}"#.utf8)
        #expect(throws: NoteTransferError.unsupportedVersion) {
            _ = try NoteExport.decoded(unsupported)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let unchecked = try decoder.decode(NoteExport.self, from: unsupported)
        #expect(throws: NoteTransferError.unsupportedVersion) {
            _ = try store.importNotes(unchecked)
        }
        let malformed = Data(
            #"{"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","notes":[{"content":"first","createdAt":"2026-01-01T00:00:00Z","usedAt":"2026-01-01T00:00:00Z","isPinned":false},{"content":"broken"}]}"#
                .utf8)
        #expect(throws: NoteTransferError.invalidFile) {
            _ = try NoteExport.decoded(malformed)
        }
        #expect(store.items.map(\.content) == ["keep me"])
    }

    @Test func anEmptyBackupIsANonDestructiveNoOp() throws {
        store.addNote("keep me")
        let revision = store.revision
        #expect(
            try store.importNotes(NoteExport(items: []))
                == NoteImportResult(imported: 0, skipped: 0))
        #expect(store.items.map(\.content) == ["keep me"])
        #expect(store.revision == revision)
    }

    @Test func notesFromAClockAheadStayOrderedAfterLaterWrites() throws {
        let future = Item(content: "from another Mac", isNote: true)
        future.usedAt = Date().addingTimeInterval(86_400)
        future.isPinned = true
        _ = try store.importNotes(NoteExport(items: [future]))
        let imported = try #require(store.items.first)
        store.addNote("local note")
        let local = try #require(store.items.first { $0.content == "local note" })
        store.togglePin(local)
        store.markUsed(local)
        #expect(store.items.first === imported)

        store.togglePin(imported)
        store.togglePin(local)
        store.addNote("another local note")
        store.markUsed(local)
        #expect(store.items.first === imported)
    }
}
