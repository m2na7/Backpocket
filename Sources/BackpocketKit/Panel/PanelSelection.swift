import Foundation
import SwiftData

/// The three lists the selection moves through, reduced to identifiers.
///
/// The selection only ever asks "is this row still on screen" and "what comes
/// after it", so it takes the rows stripped of everything else: that is what
/// keeps the rules below testable without a store, a query, or a view.
struct PaneRows: Equatable {
    var clips: [PersistentIdentifier] = []
    var links: [PersistentIdentifier] = []
    var notes: [PersistentIdentifier] = []

    subscript(pane: Pane) -> [PersistentIdentifier] {
        switch pane {
        case .clips: clips
        case .links: links
        case .notes: notes
        }
    }
}

extension PaneRows {
    @MainActor
    init(_ lists: PanelLists) {
        self.init(
            clips: lists.clips.map(\.id),
            links: lists.links.map(\.id),
            notes: lists.notes.map(\.id)
        )
    }
}

/// Which row is lit, and which pane it belongs to.
///
/// Exactly one row is ever highlighted, and it belongs to the focused pane.
/// Each pane still remembers its own row so Tab can return the user to where
/// they left it, but only the focused pane's memory is drawn — so moving the
/// focus and moving the highlight are one act, and this is the one place that
/// performs it.
///
/// Every move also records whether the user asked for it. A selection that
/// merely followed typing, or the panel opening, must never grow a preview
/// card; that used to be a separate flag with six writers and a single
/// reader, which the seventh writer would inevitably forget. Here it is a
/// required argument — there is no way to move the highlight without saying
/// where it came from.
///
/// A value type with no SwiftUI and no store: these are rules the view they
/// used to live in could not be tested for at all.
struct PanelSelection: Equatable {
    /// Who put the highlight where it is.
    enum Origin {
        /// Arrows, Tab, hover, a click — the user aimed at this row.
        case user
        /// Filtering, a drop, or the panel opening landed on it.
        case automatic
    }

    private(set) var pane: Pane = .clips
    /// True while the highlight was placed by something other than the user;
    /// the detail card reads this and stays shut.
    private(set) var isAutomatic = true
    /// The row the lists should reveal. Only keyboard navigation sets it:
    /// hover must not yank the list around under the pointer.
    private(set) var scrollTarget: PersistentIdentifier?

    private var clip: PersistentIdentifier?
    private var link: PersistentIdentifier?
    private var note: PersistentIdentifier?

    /// The row a pane remembers. Only the focused pane's is drawn.
    subscript(pane: Pane) -> PersistentIdentifier? {
        switch pane {
        case .clips: clip
        case .links: link
        case .notes: note
        }
    }

    /// The row that is lit right now.
    var selected: PersistentIdentifier? { self[pane] }

    private mutating func remember(_ id: PersistentIdentifier?, for pane: Pane) {
        switch pane {
        case .clips: clip = id
        case .links: link = id
        case .notes: note = id
        }
    }

    /// Moves the focus and the highlight together — hover and clicks come
    /// through here. Selection without focus left the previous pane's row
    /// glowing as a second highlight.
    mutating func select(_ id: PersistentIdentifier?, in pane: Pane, origin: Origin) {
        isAutomatic = origin == .automatic
        self.pane = pane
        remember(id, for: pane)
    }

    /// Enters a pane, keeping the row it remembers.
    mutating func focus(_ target: Pane, in rows: PaneRows, origin: Origin) {
        isAutomatic = origin == .automatic
        pane = target
        // Judged against the rows on screen, not on the id alone: a
        // remembered id can point at a row that conversion or deletion moved
        // out of this pane meanwhile.
        if !rows[target].contains(where: { $0 == self[target] }) {
            remember(rows[target].first, for: target)
        }
        // Reveal the remembered selection when entering a pane.
        scrollTarget = self[target]
    }

    /// One arrow press. Returns whether there were rows to move through, so
    /// the caller can leave the pointer's highlight alone when there were not.
    @discardableResult
    mutating func move(_ delta: Int, in rows: PaneRows) -> Bool {
        // Pressing an arrow is the user aiming, even at an empty pane.
        isAutomatic = false
        let items = rows[pane]
        guard !items.isEmpty else { return false }

        // With nothing selected the first arrow press lands on the top row —
        // treating "no selection" as "row 0" would skip it.
        let next: Int
        if let current = items.firstIndex(where: { $0 == selected }) {
            next = min(max(current + delta, 0), items.count - 1)
        } else {
            next = 0
        }

        remember(items[next], for: pane)
        scrollTarget = items[next]
        return true
    }

    /// Puts every pane's selection back on its top row. Nobody aimed at those
    /// rows, so the result is automatic by construction — the old flag was
    /// easiest to forget exactly here, and it is no longer a flag.
    mutating func selectTopRows(in rows: PaneRows) {
        clip = rows.clips.first
        link = rows.links.first
        note = rows.notes.first
        isAutomatic = true
    }

    /// The query changed under the lists.
    ///
    /// Results must stay reachable: when the query empties the focused pane
    /// while another still matches, the focus follows the matches — otherwise
    /// Enter goes dead in front of visible results. Only among the panes on
    /// screen: a query that matches nothing but a note, with the notes column
    /// off, would otherwise focus an invisible pane and offer Enter to edit a
    /// row nobody can see.
    ///
    /// One call rather than three statements. The old version ended with a
    /// bare `selectionIsAutomatic = true` that had to come last, because the
    /// focus step above it marked the selection user-driven; nothing here
    /// depends on statement order any more.
    mutating func queryChanged(to rows: PaneRows, hasQuery: Bool, visiblePanes: [Pane]) {
        selectTopRows(in: rows)
        if hasQuery, rows[pane].isEmpty,
            let populated = visiblePanes.first(where: { !rows[$0].isEmpty })
        {
            focus(populated, in: rows, origin: .automatic)
        }
    }

    /// Hands the highlight from a row about to be deleted to the one below
    /// it, falling back to the top of that pane when it was the last row.
    /// Takes the rows as they stand BEFORE the delete: that list is the only
    /// one that still knows which row "the one below" was. The focus does not
    /// move — deleting under the pointer must not pull it out of its pane.
    mutating func deleteAdjusting(_ id: PersistentIdentifier, in owner: Pane, rows: PaneRows) {
        let items = rows[owner]
        let next = items.firstIndex(of: id).map { $0 + 1 } ?? 0
        let following = items.indices.contains(next) ? items[next] : nil
        remember(following ?? items.first, for: owner)
    }

    /// Drops the claim that the user aimed at this row, without moving it.
    /// The pointer leaving a row is the one case: hover also selects, so the
    /// dwell target would fall back to it and the card would never be
    /// dismissed. Arrow keys re-assert the claim themselves.
    mutating func markAutomatic() {
        isAutomatic = true
    }

    /// A fresh panel show: clips focused, every pane on its top row, and the
    /// clips list rewound to it.
    mutating func reset(to rows: PaneRows) {
        pane = .clips
        selectTopRows(in: rows)
        scrollTarget = rows.clips.first
    }
}
