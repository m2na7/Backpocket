import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// The snapshot the panel filters on every keystroke. Two things can go
/// wrong with it, and each has its half here: the lists it produces could
/// differ from the ones the store used to produce directly, and it could be
/// reused after the store has moved on.
@MainActor
@Suite struct PanelIndexTests {
    private let container: ModelContainer
    private let context: ModelContext

    /// Real identifiers: `PaneRows` is compared too, and a
    /// PersistentIdentifier only exists for a model a context knows.
    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        context = ModelContext(container)
    }

    @discardableResult
    private func insert(
        _ content: String, isNote: Bool = false, pinned: Bool = false, daysAgo: Double = 0,
        imageHash: String? = nil
    ) -> Item {
        let item = Item(content: content, isNote: isNote, imageHash: imageHash)
        item.isPinned = pinned
        item.usedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        context.insert(item)
        return item
    }

    // MARK: Same lists

    /// Every search goes through the head of the text only, and the index
    /// cuts that head once instead of on every keystroke — skipping the cut
    /// altogether when the text is too short to need one. The shortcut is
    /// counted in UTF-16 units and the cut in characters, so the texts here
    /// sit at, just under and just over the cap in both, built from what
    /// makes the two counts disagree: emoji, an accent that is its own
    /// scalar, and Hangul spelled out as jamo. The needle at the end of each
    /// is either the last thing inside the cap or the first thing outside.
    @Test func theSearchFindsExactlyWhatItDidBeforeTheIndex() throws {
        let cap = PanelIndex.searchCap
        let needle = "needle"
        let fillers = [
            "a",  // one unit, one character: the shortcut's own boundary
            "😀",  // two units, one character
            "e\u{301}",  // two scalars, one character
            "\u{1112}\u{1161}\u{11AB}",  // three jamo, one character: 한
        ]
        for filler in fillers {
            for length in [cap - 1, cap, cap + 1] {
                let pad = String(repeating: filler, count: length - needle.count)
                insert(pad + needle)
                insert(needle + pad)
                insert(pad + needle, isNote: true, daysAgo: 2)
            }
        }
        let items = try storeOrdered()

        for item in items {
            #expect(PanelIndex.haystack(item.content) == String(item.content.prefix(cap)))
        }
        expectSameLists(
            items: items, links: [.keep],
            queries: ["", "needle", "NEEDLE", "le", "😀", "é", "e\u{301}", "한", "zzz"])
    }

    /// Which pane a row lands in, under each of the three ways of collecting
    /// links — the one fact the index now answers from a flag it read once.
    @Test func thePartitionIsExactlyWhatItWasBeforeTheIndex() throws {
        insert("https://example.com/needle")
        insert("  https://example.com/a\n")
        insert("example.com")
        insert("https://example.com/two words")
        insert("https://example.com/note", isNote: true)
        insert("https://example.com/image", imageHash: "hash")
        insert("plain needle")
        insert("pinned note", isNote: true, pinned: true, daysAgo: 40)
        insert("older note", isNote: true, daysAgo: 400)
        insert("today's needle", isNote: true)

        expectSameLists(
            items: try storeOrdered(), links: LinkCollection.allCases,
            queries: ["", "example", "needle", "zzz"])
    }

    /// Everything the panel draws or walks, compared with what the store
    /// produced directly — through the index the panel keeps between
    /// keystrokes, and through the `items:` overload that builds one.
    private func expectSameLists(
        items: [Item], links modes: [LinkCollection], queries: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let index = PanelIndex(items: items)
        let now = Date()
        for mode in modes {
            for query in queries {
                let old = LegacyPanelLists.make(items: items, query: query, links: mode, now: now)
                for new in [
                    PanelContents.make(index: index, query: query, links: mode, now: now),
                    PanelContents.make(items: items, query: query, links: mode, now: now),
                ] {
                    let comment: Comment = "\(mode), query \(query)"
                    #expect(
                        identities(new.clips) == identities(old.clips), comment,
                        sourceLocation: sourceLocation)
                    #expect(
                        identities(new.links) == identities(old.links), comment,
                        sourceLocation: sourceLocation)
                    #expect(
                        identities(new.notes) == identities(old.notes), comment,
                        sourceLocation: sourceLocation)
                    #expect(
                        new.noteSections == old.noteSections, comment,
                        sourceLocation: sourceLocation)
                    #expect(
                        new.rows == PaneRows(legacy: old), comment, sourceLocation: sourceLocation)
                }
            }
        }
    }

    private func storeOrdered() throws -> [Item] {
        try context.fetch(FetchDescriptor<Item>()).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.usedAt > $1.usedAt
        }
    }

    /// The same objects in the same order: a copy of a row would be a
    /// different item to everything downstream.
    private func identities(_ items: [Item]) -> [ObjectIdentifier] {
        items.map(ObjectIdentifier.init)
    }

    // MARK: Never stale

    /// The drop onto the notes column is the sharp case: it changes the store
    /// and recomputes in the same turn, so whatever the recompute is handed
    /// has to already know. Each mutation here is followed straight away by
    /// the refresh the panel runs, with no revision handler in between.
    @Test func theIndexIsRetakenAfterEveryStoreMutation() throws {
        let store = Store(context: context, disposableLimit: { 0 })
        let source = CopySource(name: "Notes", bundleID: "com.apple.Notes")
        store.add("https://example.com/a", source: source)
        store.add("dropped text", source: source)
        let dropped = try #require(store.items.first { $0.content == "dropped text" })

        var index = PanelIndex(store)
        func lists() -> PanelContents {
            index = index.refreshed(from: store)
            return PanelContents.make(index: index, query: "", links: .separate)
        }

        let before = index
        store.adoptAsNote("dropped text")
        let converted = lists()
        #expect(converted.notes.contains { $0 === dropped })
        #expect(!converted.clips.contains { $0 === dropped })
        // And the snapshot really is one: left alone, it still describes the
        // store from before the drop. That is the bug a refresh taken only in
        // the revision handler would bring back.
        let stale = PanelContents.make(index: before, query: "", links: .separate)
        #expect(stale.clips.contains { $0 === dropped })

        store.togglePin(dropped)
        #expect(lists().noteSections.first?.group == .pinned)

        store.delete(dropped)
        #expect(!lists().notes.contains { $0 === dropped })

        #expect(store.undoDelete())
        #expect(lists().notes.map(\.content) == ["dropped text"])
    }

    /// Keystrokes are what the index is for: nothing may be reread from the
    /// store while its revision stands still. Changing a model behind the
    /// store's back is not something the app may do — it is how this test
    /// can tell a reused index from a retaken one.
    @Test func anUnchangedStoreKeepsItsIndex() throws {
        let store = Store(context: context, disposableLimit: { 0 })
        store.add("a clip", source: CopySource(name: "Notes", bundleID: "com.apple.Notes"))
        let clip = try #require(store.items.first)
        let index = PanelIndex(store)

        clip.isNote = true
        let reused = index.refreshed(from: store)

        #expect(reused.revision == index.revision)
        #expect(reused.entries.map(\.isNote) == [false])
    }

    /// The empty index a panel starts with, and one built from a bare list,
    /// carry no revision, so neither can pass for current. A store fresh from
    /// disk is at revision 0 with its rows already loaded.
    @Test func anIndexWithoutARevisionIsNeverCurrent() throws {
        insert("already on disk")
        try context.save()
        let store = Store(context: context, disposableLimit: { 0 })
        #expect(store.revision == 0)

        for index in [PanelIndex(), PanelIndex(items: [])] {
            #expect(index.refreshed(from: store).entries.map(\.item.content) == ["already on disk"])
        }
    }
}

extension PaneRows {
    /// The identifiers as they were read before the index: off each item.
    @MainActor
    fileprivate init(legacy lists: PanelLists) {
        self.init(
            clips: lists.clips.map(\.id),
            links: lists.links.map(\.id),
            notes: lists.notes.map(\.id)
        )
    }
}

/// `PanelLists.make(items:)` as it stood before `PanelIndex`, verbatim. It is
/// the reference the index is held to — not a second implementation to keep
/// in step, and not to be edited.
@MainActor
private enum LegacyPanelLists {
    /// ponytail: only the head of each item is searched — a full-content scan
    /// is O(items × 200k chars) per keystroke; build an index if matches past
    /// the cap ever matter.
    private static let searchCap = 10_000

    static func make(
        items: [Item],
        query: String,
        links collection: LinkCollection,
        now: Date = Date()
    ) -> PanelLists {
        func matching(_ items: [Item]) -> [Item] {
            guard !query.isEmpty else { return items }
            return items.filter {
                $0.content.prefix(searchCap).localizedCaseInsensitiveContains(query)
            }
        }

        var lists = PanelLists()

        // Partition after the query narrowing, in one pass — isLink is cheap
        // but not free, and this runs on every keystroke.
        let history = matching(items.filter { !$0.isNote })
        switch collection {
        case .keep:
            lists.clips = history
        case .separate:
            var rest: [Item] = []
            var linked: [Item] = []
            for item in history {
                if item.isLink {
                    linked.append(item)
                } else {
                    rest.append(item)
                }
            }
            lists.clips = rest
            lists.links = linked
        case .both:
            // The same rows in both lists, deliberately: everything
            // downstream — the highlight, the paste stack, ⌘1..9 — is scoped
            // to a pane, so one item appearing twice is two rows, not two
            // items.
            lists.clips = history
            lists.links = history.filter(\.isLink)
        }

        lists.notes = matching(items.filter(\.isNote))

        // The store hands notes over already ordered, so equal groups arrive
        // adjacent and a run-merger is enough — no bucketing pass. One clock
        // for the whole list, so the date math is done once and each day is
        // formatted once rather than once per note.
        var clock = NoteClock(now: now)
        for item in lists.notes {
            let group = item.isPinned ? NoteGroup.pinned : clock.group(for: item.usedAt)
            let row = NoteRowData(item: item, timeLabel: clock.rowLabel(for: item.usedAt))
            if lists.noteSections.last?.group == group {
                lists.noteSections[lists.noteSections.count - 1].rows.append(row)
            } else {
                lists.noteSections.append(NoteSection(group: group, rows: [row]))
            }
        }

        return lists
    }
}
