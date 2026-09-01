import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// What the panel holds between recomputes: the rows it draws and the
/// identifiers the selection walks. `PanelLists` is where the partition is
/// checked; this is where the two halves are checked against each other, since
/// the failure they used to be one edit away from — identifiers that no longer
/// describe the lists — shows up as arrows moving the highlight onto nothing.
@MainActor
@Suite("PanelContents")
struct PanelContentsTests {
    private let container: ModelContainer
    private let context: ModelContext

    /// Real identifiers: the rows are what the selection is compared against,
    /// and a PersistentIdentifier only exists for a model a context knows.
    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        context = ModelContext(container)
    }

    @discardableResult
    private func insert(_ content: String, isNote: Bool = false) -> Item {
        let item = Item(content: content, isNote: isNote)
        context.insert(item)
        return item
    }

    /// One of each kind, since the modes below differ only in where the link
    /// ends up.
    private func mixedHistory() -> [Item] {
        [
            insert("https://example.com/needle"),
            insert("plain text"),
            insert("a needle in a note", isNote: true),
        ]
    }

    @Test func theIdentifiersDescribeTheListsInEveryMode() {
        let items = mixedHistory()

        for mode in LinkCollection.allCases {
            let contents = PanelContents.make(items: items, query: "", links: mode)

            #expect(contents.rows.clips == contents.clips.map(\.id))
            #expect(contents.rows.links == contents.links.map(\.id))
            #expect(contents.rows.notes == contents.notes.map(\.id))
        }
    }

    @Test func thePaneLookupAnswersForThePaneItWasAsked() {
        let contents = PanelContents.make(items: mixedHistory(), query: "", links: .both)

        for pane in [Pane.clips, .links, .notes] {
            #expect(contents[pane].map(\.id) == contents.rows[pane])
        }
        // Under `both` one item is a row in two panes, which is the whole
        // reason nothing may work the pane out from the row it is holding.
        #expect(contents[.clips].contains { $0 === contents[.links][0] })
    }

    @Test func anUntouchedPanelShowsNothingAnywhere() {
        let contents = PanelContents()

        for pane in [Pane.clips, .links, .notes] {
            #expect(contents[pane].isEmpty)
            #expect(contents.rows[pane].isEmpty)
            #expect(!contents.hasMatches(in: pane))
        }
        #expect(contents.noteSections.isEmpty)
    }

    @Test func theTwoHistoryPanesCountAsOneSetOfMatches() {
        // A query that only the link answers, with the link moved into its own
        // section: the clips list is empty and there are still results on
        // screen.
        let contents = PanelContents.make(items: mixedHistory(), query: "example", links: .separate)

        #expect(contents.clips.isEmpty)
        #expect(!contents.links.isEmpty)
        // Enter must not offer to save a note over visible results — which is
        // exactly what splitting the history in two broke once.
        #expect(contents.hasMatches(in: .clips))
        #expect(contents.hasMatches(in: .links))
    }

    @Test func theNotesPaneAnswersForItsOwnListAlone() {
        let items = mixedHistory()

        let noteOnly = PanelContents.make(items: items, query: "in a note", links: .separate)
        #expect(noteOnly.hasMatches(in: .notes))
        // The history is empty under that query, and the notes column's
        // results are none of its business.
        #expect(!noteOnly.hasMatches(in: .clips))

        let historyOnly = PanelContents.make(items: items, query: "plain", links: .separate)
        #expect(!historyOnly.hasMatches(in: .notes))
        #expect(historyOnly.hasMatches(in: .clips))
    }

    @Test func theNoteSectionsArriveWithTheNotesTheyBucket() {
        let now = Date(timeIntervalSince1970: 1_766_000_000)
        let recent = insert("today", isNote: true)
        recent.usedAt = now
        let older = insert("last month", isNote: true)
        older.usedAt = now.addingTimeInterval(-20 * 86_400)

        let contents = PanelContents.make(
            items: [recent, older], query: "", links: .keep, now: now)

        // Sectioning is `PanelLists`' rule; what matters here is that the
        // buckets are rebuilt with the notes rather than left behind by a
        // recompute that only refreshed the flat list.
        #expect(contents.noteSections.flatMap { $0.rows }.map(\.item.id) == contents.rows.notes)
        #expect(contents.noteSections.count == 2)
    }
}
