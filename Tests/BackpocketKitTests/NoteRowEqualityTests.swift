import Foundation
import Testing

@testable import BackpocketKit

/// `NoteRow` is `Equatable` for the same reason `ItemRow` is, and had none of
/// the same cover: the exhaustive mutation pass could flip every `&&` in this
/// operator to `||`, and every `==` to `!=`, without a single test noticing.
/// The clips list learned this already — the comment on
/// `ItemRowEqualityTests` names the shipped bug — and the notes list is the
/// same optimization with the same failure mode: a field the operator forgets
/// is a row left standing with stale pixels.
@MainActor
@Suite struct NoteRowEqualityTests {
    private let item = Item(content: "a hand-written note", isNote: true)
    private let usedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every stored value, defaulted, so each case below varies exactly one.
    private func row(
        item: Item? = nil,
        usedAt: Date? = nil,
        isPinned: Bool = false,
        timeLabel: String = "3:04 PM",
        shortcut: Int? = nil,
        stackNumber: Int? = nil,
        stacking: Bool = false,
        query: String = "",
        highlighted: Bool = false,
        pointerHovering: Bool = false
    ) -> NoteRow {
        NoteRow(
            item: item ?? self.item,
            usedAt: usedAt ?? self.usedAt,
            isPinned: isPinned,
            timeLabel: timeLabel,
            shortcut: shortcut,
            stackNumber: stackNumber,
            stacking: stacking,
            query: query,
            highlighted: highlighted,
            pointerHovering: pointerHovering,
            onHover: {}, onExit: {}, onActivate: {}, onToggleStack: {},
            onEdit: {}, onTogglePin: {}, onDelete: {}
        )
    }

    /// Without this the rest is vacuous, and it is the property the whole
    /// optimization rests on: an unchanged row must compare equal, or moving
    /// the pointer redraws every visible note again.
    @Test func anUnchangedRowComparesEqual() {
        #expect(row() == row())
    }

    /// The identity check is the anchor. Judged by its captured values alone
    /// a row would equal the row of a *different* note sharing a timestamp,
    /// so two neighbours swapping places would leave both drawn with the
    /// wrong text.
    @Test func twoRowsOverDifferentNotesAreNeverEqual() {
        #expect(row() != row(item: Item(content: "a different note", isNote: true)))
    }

    /// One case per field the row body reads. Each is a redraw trigger: stop
    /// distinguishing it and the row keeps whatever it drew last.
    @Test func changingAnyDrawnFieldForcesAredraw() {
        let base = row()

        // Edits bump usedAt deliberately, standing in for "the text changed"
        // without the operator comparing the text itself.
        #expect(base != row(usedAt: usedAt.addingTimeInterval(1)))
        // Pinning leaves usedAt alone on purpose; nothing else would notice.
        #expect(base != row(isPinned: true))
        // Preformatted upstream, so the row body never touches a formatter —
        // which also means the row cannot recompute it when it goes stale.
        #expect(base != row(timeLabel: "3:05 PM"))
        // Holding Command swaps the number badge in.
        #expect(base != row(shortcut: 3))
        #expect(base != row(stackNumber: 1))
        // Collecting a stack replaces the whole trailing column.
        #expect(base != row(stacking: true))
        // The query drives the match highlight inside the preview text.
        #expect(base != row(query: "written"))
        #expect(base != row(highlighted: true))
        // Gates the inline row actions, so this one is the difference between
        // buttons being there and not.
        #expect(base != row(pointerHovering: true))
    }

    /// The section's own row values, which decide whether a whole bucket
    /// redraws. Same operator, same failure: a note edited in place would
    /// leave its section drawn as it was.
    @Test func sectionRowDataComparesIdentityAndItsLabel() {
        let data = NoteRowData(item: item, timeLabel: "3:04 PM")

        let other = NoteRowData(
            item: Item(content: "a different note", isNote: true), timeLabel: "3:04 PM")

        #expect(data == NoteRowData(item: item, timeLabel: "3:04 PM"))
        #expect(data != NoteRowData(item: item, timeLabel: "3:05 PM"))
        #expect(data != other)
    }
}
