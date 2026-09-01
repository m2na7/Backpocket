import Foundation

/// What the panel is showing right now: the three lists as rows to draw, and
/// the same three lists as identifiers for the selection to move through.
///
/// `PanelLists` derives them; this is what the view holds onto. The
/// distinction earns a type because they were five pieces of `@State`
/// recomputed side by side and kept in step by hand — and the moment one
/// recompute updates the lists but not the identifiers, the selection is
/// walking rows the panel is no longer drawing, arrows move the highlight to
/// nothing and ↩ pastes a clip that scrolled out of existence. Replaced whole
/// or not at all, so the two cannot disagree.
///
/// The per-pane lookups live here with them: every caller that wants one list
/// out of the three has to say WHICH, since under `LinkCollection.both` one
/// item is a row in two of them and nothing may work the pane out from the
/// row it is holding.
struct PanelContents {
    private(set) var lists = PanelLists()
    private(set) var rows = PaneRows()

    var clips: [Item] { lists.clips }
    var links: [Item] { lists.links }
    var notes: [Item] { lists.notes }
    /// The notes bucketed for display, rebuilt with them so row bodies never
    /// run date math or build a formatter.
    var noteSections: [NoteSection] { lists.noteSections }

    subscript(pane: Pane) -> [Item] {
        switch pane {
        case .clips: lists.clips
        case .links: lists.links
        case .notes: lists.notes
        }
    }

    /// Whether the pane the user is in has anything to act on.
    ///
    /// A new sentence that matches nothing becomes a note with a plain Enter,
    /// so this is what stands between typing and note capture. For the
    /// history panes "nothing" spans clips AND links: they are one history
    /// split in two, and a URL search that hits only the links section must
    /// not turn Enter into note capture the way it did before the split.
    func hasMatches(in pane: Pane) -> Bool {
        pane == .notes ? !notes.isEmpty : !(clips.isEmpty && links.isEmpty)
    }

    @MainActor
    static func make(
        items: [Item],
        query: String,
        links collection: LinkCollection,
        now: Date = Date()
    ) -> PanelContents {
        let lists = PanelLists.make(items: items, query: query, links: collection, now: now)
        return PanelContents(lists: lists, rows: PaneRows(lists))
    }
}
