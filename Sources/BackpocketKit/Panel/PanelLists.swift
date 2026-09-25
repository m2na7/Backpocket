import Foundation

/// What the panel shows, derived from the store — by way of its
/// `PanelIndex` — and the query. Pure: the same inputs always produce the
/// same lists, so the partition and the note sectioning can be tested without
/// standing up a view.
struct PanelLists {
    var clips: [Item] = []
    var links: [Item] = []
    var notes: [Item] = []
    var noteSections: [NoteSection] = []

    /// Straight from a list of items, indexing them on the way. The panel
    /// goes through `PanelContents.make(index:)` instead, which needs the
    /// matches for the selection's identifiers as well as for these lists.
    @MainActor
    static func make(
        items: [Item],
        query: String,
        links collection: LinkCollection,
        now: Date = Date()
    ) -> PanelLists {
        let matches = Matches(PanelIndex(items: items), query: query, links: collection)
        return PanelLists(matches, now: now)
    }
}

extension PanelLists {
    /// The entries each pane shows, before they are split into the items it
    /// draws and the identifiers the selection walks (`PaneRows`).
    struct Matches {
        var clips: [PanelIndex.Entry] = []
        var links: [PanelIndex.Entry] = []
        var notes: [PanelIndex.Entry] = []

        /// Narrows by the query and partitions in one pass over the index,
        /// keeping the index's order — the store's — within every list.
        init(_ index: PanelIndex, query: String, links collection: LinkCollection) {
            for entry in index.entries {
                guard query.isEmpty || entry.haystack.localizedCaseInsensitiveContains(query)
                else { continue }

                if entry.isNote {
                    notes.append(entry)
                    continue
                }
                switch collection {
                case .keep:
                    clips.append(entry)
                case .separate:
                    if entry.isLink {
                        links.append(entry)
                    } else {
                        clips.append(entry)
                    }
                case .both:
                    // The same rows in both lists, deliberately: everything
                    // downstream — the highlight, the paste stack, ⌘1..9 — is
                    // scoped to a pane, so one item appearing twice is two
                    // rows, not two items.
                    clips.append(entry)
                    if entry.isLink { links.append(entry) }
                }
            }
        }
    }

    @MainActor
    init(_ matches: Matches, now: Date) {
        clips = matches.clips.map(\.item)
        links = matches.links.map(\.item)
        notes = matches.notes.map(\.item)

        // The store hands notes over already ordered, so equal groups arrive
        // adjacent and a run-merger is enough — no bucketing pass. One clock
        // for the whole list, so the date math is done once and each day is
        // formatted once rather than once per note.
        var clock = NoteClock(now: now)
        for entry in matches.notes {
            let group = entry.isPinned ? NoteGroup.pinned : clock.group(for: entry.usedAt)
            let row = NoteRowData(item: entry.item, timeLabel: clock.rowLabel(for: entry.usedAt))
            if noteSections.last?.group == group {
                noteSections[noteSections.count - 1].rows.append(row)
            } else {
                noteSections.append(NoteSection(group: group, rows: [row]))
            }
        }
    }
}
