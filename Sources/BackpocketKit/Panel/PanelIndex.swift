import Foundation
import SwiftData

/// What the panel's lists are derived from: every fact a recompute reads off
/// an item, read once per store revision instead of once per keystroke.
///
/// Every property of an `@Model` is a trip through SwiftData's backing
/// store, and `isLink` parses a URL on top. Filtering the store directly
/// paid for both on every item, twice for some, on every keystroke. With
/// this in between a keystroke reads nothing from the store: it runs the
/// search and sorts what matched into panes.
///
/// It is only as current as the revision it was taken at. That is enough
/// because every change to an item goes through `Store`, and every one bumps
/// `Store.revision`; `refreshed(from:)` is how a caller gets an index it can
/// trust, and it has to be asked at the moment of use (see `ContentView`).
struct PanelIndex {
    struct Entry {
        let item: Item
        let id: PersistentIdentifier
        let isNote: Bool
        let isLink: Bool
        let isPinned: Bool
        let usedAt: Date
        /// Complete text, captured once per revision rather than read on every keystroke.
        let haystack: String
    }

    /// The store revision this was taken at. Nil for one taken from a bare
    /// list of items, and for the empty one a panel starts with, so that
    /// neither can ever pass for current.
    let revision: Int?
    let entries: [Entry]

    init() {
        revision = nil
        entries = []
    }

    @MainActor
    init(items: [Item], revision: Int? = nil) {
        self.revision = revision
        entries = items.map { item in
            // Each read once: `item.isLink` would read the first two again.
            let content = item.content
            let isNote = item.isNote
            return Entry(
                item: item,
                id: item.id,
                isNote: isNote,
                isLink: Item.linkURL(in: content, isNote: isNote, isImage: item.isImage) != nil,
                isPinned: item.isPinned,
                usedAt: item.usedAt,
                haystack: content
            )
        }
    }

}

extension PanelIndex {
    @MainActor
    init(_ store: Store) {
        self.init(items: store.items, revision: store.revision)
    }

    /// This index while the store has not changed since it was taken, a
    /// fresh one once it has.
    @MainActor
    func refreshed(from store: Store) -> PanelIndex {
        revision == store.revision ? self : PanelIndex(store)
    }
}
