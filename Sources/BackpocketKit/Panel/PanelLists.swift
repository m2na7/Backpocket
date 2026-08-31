import Foundation

/// What the panel shows, derived from the store and the query. Pure: the same
/// inputs always produce the same lists, so the partition and the note
/// sectioning can be tested without standing up a view.
struct PanelLists {
    var clips: [Item] = []
    var links: [Item] = []
    var notes: [Item] = []
    var noteSections: [NoteSection] = []

    /// ponytail: only the head of each item is searched — a full-content scan
    /// is O(items × 200k chars) per keystroke; build an index if matches past
    /// the cap ever matter.
    private static let searchCap = 10_000

    @MainActor
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
        // adjacent and a run-merger is enough — no bucketing pass.
        for item in lists.notes {
            let group =
                item.isPinned ? NoteGroup.pinned : NoteGroup.group(for: item.usedAt, now: now)
            let row = NoteRowData(
                item: item,
                timeLabel: NoteGroup.rowLabel(for: item.usedAt, now: now)
            )
            if lists.noteSections.last?.group == group {
                lists.noteSections[lists.noteSections.count - 1].rows.append(row)
            } else {
                lists.noteSections.append(NoteSection(group: group, rows: [row]))
            }
        }

        return lists
    }
}
