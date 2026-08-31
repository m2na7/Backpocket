import Foundation
import Testing

@testable import BackpocketKit

/// `ItemRow` is `Equatable` so SwiftUI may skip redrawing a row, which puts
/// this one operator in charge of what the user actually sees: any field it
/// forgets to compare is a row left standing with stale pixels — a timestamp
/// that never advances, a pin glyph that never appears. The panel has shipped
/// that bug once already (the refresh used to skip in-place changes at the top
/// of the list), and the render smoke tests cannot catch it: they draw a row
/// and look at the raster, never at whether a second row would be drawn at all.
@MainActor
@Suite struct ItemRowEqualityTests {
    private let item = Item(content: "an ordinary clipboard capture")
    private let usedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every stored property, defaulted, so each case below varies exactly one.
    private func row(
        item: Item? = nil,
        usedAt: Date? = nil,
        isPinned: Bool = false,
        shortcut: String? = nil,
        stackNumber: Int? = nil,
        stacking: Bool = false,
        query: String = "",
        highlighted: Bool = false,
        asLink: Bool = false
    ) -> ItemRow {
        ItemRow(
            item: item ?? self.item,
            usedAt: usedAt ?? self.usedAt,
            isPinned: isPinned,
            shortcut: shortcut,
            stackNumber: stackNumber,
            stacking: stacking,
            query: query,
            highlighted: highlighted,
            asLink: asLink,
            onHover: {}, onExit: {}, onActivate: {}, onToggleStack: {},
            onConvert: {}, onTogglePin: {}, onDelete: {},
            onPasteMarkdown: {}, onOpenLink: {}
        )
    }

    /// Without this the rest is vacuous, and it is the property the whole
    /// optimization rests on: an unchanged row must compare equal, or hover
    /// tracking redraws the entire visible list on every pointer move again.
    @Test func anUnchangedRowComparesEqual() {
        #expect(row() == row())
    }

    /// The identity check is the anchor. Judged by its captured values alone,
    /// a row would compare equal to the row of a *different* clip that happens
    /// to share a timestamp and a pin state — so two neighbours swapping
    /// places, or a deletion shifting the list up, would leave both drawn with
    /// the wrong content.
    @Test func twoRowsOverDifferentItemsAreNeverEqual() {
        let other = Item(content: "a different capture")
        #expect(row() != row(item: other))
    }

    /// One case per field the row body reads. Each is a redraw trigger: if the
    /// operator stops distinguishing it, the row keeps whatever it drew last.
    @Test func changingAnyDrawnFieldForcesAredraw() {
        let base = row()

        // Edits bump usedAt deliberately, so this stands in for "the content
        // changed" without the operator having to compare the content itself.
        #expect(base != row(usedAt: usedAt.addingTimeInterval(1)))
        // Pinning leaves usedAt alone on purpose; nothing else would notice it.
        #expect(base != row(isPinned: true))
        // Holding and releasing Command swaps the badge in for the icon.
        #expect(base != row(shortcut: "3"))
        #expect(base != row(stackNumber: 1))
        // Collecting a stack replaces the whole trailing column.
        #expect(base != row(stacking: true))
        // The query drives the match highlight inside the preview text.
        #expect(base != row(query: "clipboard"))
        #expect(base != row(highlighted: true))
        // The links section draws a globe and splits the URL into domain and
        // path; the same item renders differently on either side of this flag.
        #expect(base != row(asLink: true))
    }
}
