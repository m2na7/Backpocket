import Foundation
import Testing

@testable import BackpocketKit

/// The panel's list derivation: the link partition and the note run-merger,
/// neither of which any test could reach while they lived inside the view.
@MainActor
@Suite struct PanelListsTests {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    private func clip(_ content: String, minutesAgo: Int = 0) -> Item {
        let item = Item(content: content)
        item.usedAt = now.addingTimeInterval(-Double(minutesAgo) * 60)
        return item
    }

    private func note(_ content: String, daysAgo: Int = 0, pinned: Bool = false) -> Item {
        let item = Item(content: content, isNote: true)
        item.usedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        item.isPinned = pinned
        return item
    }

    @Test func linksSplitOutOnlyWhenTheSectionIsOn() {
        let items = [clip("https://example.com/a"), clip("plain text"), note("a note")]

        let split = PanelLists.make(items: items, query: "", links: .separate, now: now)
        #expect(split.clips.map(\.content) == ["plain text"])
        #expect(split.links.map(\.content) == ["https://example.com/a"])

        // Off, the same URL stays an ordinary clip — one copy, one row.
        let merged = PanelLists.make(items: items, query: "", links: .keep, now: now)
        #expect(merged.clips.count == 2)
        #expect(merged.links.isEmpty)
    }

    @Test func bothLeavesTheLinkInTheClipboardListAsWell() {
        let items = [clip("https://example.com/a"), clip("plain text"), note("a note")]

        let lists = PanelLists.make(items: items, query: "", links: .both, now: now)
        // The whole point of the mode: the link is still where the user
        // watched it land, and also in the section.
        #expect(lists.clips.map(\.content) == ["https://example.com/a", "plain text"])
        #expect(lists.links.map(\.content) == ["https://example.com/a"])
        // The same row object, not a copy — everything downstream keys off the
        // identifier, so a duplicated item would be two items to the store.
        #expect(lists.clips[0] === lists.links[0])
        #expect(lists.notes.map(\.content) == ["a note"])
    }

    @Test func theThreeModesDifferOnlyInWhereTheLinkGoes() {
        let items = [clip("https://example.com/a"), clip("plain text")]

        for mode in LinkCollection.allCases {
            let lists = PanelLists.make(items: items, query: "", links: mode, now: now)
            #expect(lists.links.isEmpty == !mode.showsLinks)
            // Nothing may go missing: a non-link is always a clip, and the
            // link is in the clipboard list unless the mode moved it out.
            #expect(lists.clips.contains { $0.content == "plain text" })
            #expect(
                lists.clips.contains { $0.content == "https://example.com/a" }
                    == !mode.movesLinksOut
            )
        }
    }

    @Test func theQueryNarrowsEverySectionAndNotesStaySeparate() {
        let items = [
            clip("https://example.com/needle"),
            clip("haystack"),
            note("needle in a note"),
        ]

        let lists = PanelLists.make(items: items, query: "needle", links: .separate, now: now)
        #expect(lists.clips.isEmpty)
        #expect(lists.links.map(\.content) == ["https://example.com/needle"])
        #expect(lists.notes.map(\.content) == ["needle in a note"])
    }

    @Test func pinnedNotesGetTheirOwnSectionAboveTheDateBuckets() {
        let items = [
            note("pinned one", daysAgo: 40, pinned: true),
            note("pinned two", daysAgo: 1, pinned: true),
            note("today one"),
            note("today two"),
            note("last week", daysAgo: 3),
        ]

        let sections = PanelLists.make(items: items, query: "", links: .separate, now: now)
            .noteSections

        #expect(sections.map(\.group) == [.pinned, .today, .last7Days])
        // The run-merger must coalesce adjacent equals, not emit one section
        // per note.
        #expect(sections.map(\.rows.count) == [2, 2, 1])
        #expect(sections[0].rows.map(\.item.content) == ["pinned one", "pinned two"])
    }

    @Test func aGroupThatRecursAfterAnotherStartsANewSection() {
        // Contrived on purpose: the merger keys off adjacency, so an
        // out-of-order list must not fold the two "today" runs together.
        let items = [note("today one"), note("older", daysAgo: 3), note("today two")]

        let sections = PanelLists.make(items: items, query: "", links: .separate, now: now)
            .noteSections

        #expect(sections.map(\.group) == [.today, .last7Days, .today])
    }
}
