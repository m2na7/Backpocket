import Foundation

/// What a delete took away, kept just long enough to put back. SwiftData has
/// no undelete — once the context saves, the model is gone and the reference
/// to it is the ghost `Store.isTracked` exists to reject — so undo restores
/// from a copy of the row's values rather than reviving the object.
///
/// Retention is deliberately mean, and the meanness is the design. Every batch
/// held here keeps content the user asked to destroy alive in memory, image
/// bytes included: a clipboard manager that quietly kept a shadow copy of
/// everything deleted would undo the guarantee that expiry, the history limit
/// and Clear History exist to make. So the window is the length of a "wait,
/// no" and nothing beyond it — a mis-hit ⌘⌫ is noticed in the same breath,
/// while a delete the user thought about for a minute was not an accident —
/// and the depth stops at a short run of them.
struct DeletionUndo {
    /// How long one delete stays restorable. Long enough to see the row go and
    /// reach for the shortcut; short enough that this is never storage.
    static let window: TimeInterval = 20

    /// How many deletes back undo reaches. Clearing a few rows one at a time
    /// and regretting the run is the case worth covering; a depth that held a
    /// whole session would be a second copy of the history just deleted.
    static let depth = 3

    /// Every stored attribute of `Item`, because undo has to give the row back
    /// as it was: restoring content alone would file a two-week-old note at
    /// the top of today, unpinned, from no app. A field added to the model and
    /// forgotten here comes back blank, which is why this list is exhaustive
    /// rather than "the interesting ones".
    struct Snapshot {
        let content: String
        let createdAt: Date
        let usedAt: Date
        let isNote: Bool
        let isPinned: Bool
        let sourceApp: String?
        let sourceBundleID: String?
        let contentHTML: String?
        let contentRTF: Data?
        let imageData: Data?
        let thumbnailData: Data?
        let imageHash: String?
        let isFileCopy: Bool

        init(_ item: Item) {
            content = item.content
            createdAt = item.createdAt
            usedAt = item.usedAt
            isNote = item.isNote
            isPinned = item.isPinned
            sourceApp = item.sourceApp
            sourceBundleID = item.sourceBundleID
            contentHTML = item.contentHTML
            contentRTF = item.contentRTF
            imageData = item.imageData
            thumbnailData = item.thumbnailData
            imageHash = item.imageHash
            isFileCopy = item.isFileCopy
        }

        /// A new row carrying the old row's values. `Item.init` stamps both
        /// dates with now and starts unpinned — right for a fresh capture,
        /// wrong for a restore — so everything the initializer decides is
        /// overwritten here.
        func restored() -> Item {
            let item = Item(
                content: content,
                isNote: isNote,
                isFileCopy: isFileCopy,
                html: contentHTML,
                rtf: contentRTF,
                imageData: imageData,
                thumbnailData: thumbnailData,
                imageHash: imageHash
            )
            item.createdAt = createdAt
            item.usedAt = usedAt
            item.isPinned = isPinned
            item.sourceApp = sourceApp
            item.sourceBundleID = sourceBundleID
            return item
        }
    }

    /// One delete, however many rows it removed. A ⌘-collected handful is one
    /// action to the user, so it has to be one step back.
    private struct Batch {
        let deletedAt: Date
        let snapshots: [Snapshot]
    }

    /// Oldest first, so the newest batch — the one undo takes — is the last.
    private var batches: [Batch] = []

    mutating func record(_ doomed: some Collection<Item>, at now: Date) {
        guard !doomed.isEmpty else { return }
        batches.append(Batch(deletedAt: now, snapshots: doomed.map(Snapshot.init)))
        forgetExpired(asOf: now)
        batches.removeFirst(max(0, batches.count - Self.depth))
    }

    func canUndo(asOf now: Date) -> Bool {
        batches.contains { Self.isLive($0, at: now) }
    }

    /// The newest delete still inside the window, removed from the stack.
    /// Expired batches are dropped rather than skipped: undo must not reach
    /// past the window into something the user deleted minutes ago.
    mutating func takeLatest(asOf now: Date) -> [Snapshot]? {
        forgetExpired(asOf: now)
        return batches.popLast()?.snapshots
    }

    /// Returns whether anything was dropped, so a caller can tell a sweep that
    /// changed what the UI may offer from one that found nothing.
    @discardableResult
    mutating func forgetExpired(asOf now: Date) -> Bool {
        let before = batches.count
        batches.removeAll { !Self.isLive($0, at: now) }
        return batches.count != before
    }

    private static func isLive(_ batch: Batch, at now: Date) -> Bool {
        now.timeIntervalSince(batch.deletedAt) < window
    }
}
