import CryptoKit
import Foundation
import OSLog
import SwiftData

/// The single owner of all reads and writes. @MainActor because the UI is the
/// only consumer and it keeps SwiftData access single-threaded.
@MainActor
final class Store: ObservableObject {
    /// Pinned items first, then usedAt descending — see `ordered`. The array
    /// is maintained incrementally rather than refetched: a mutation that
    /// bumps usedAt sets it to Date(), the global maximum, so the item only
    /// has to move to the front of its own block (`insertionIndex`). Pinning
    /// is the one change that reorders across blocks, and re-sorts.
    @Published private(set) var items: [Item] = []

    /// Bumped on every mutation. Views must refilter on THIS, not on `items`:
    /// the array holds the same references after an in-place change (promoting
    /// the item that is already first, flipping isNote), so array equality
    /// swallows exactly the mutations that change section membership.
    @Published private(set) var revision = 0

    /// True while the database and `items` may disagree — a save or a fetch
    /// failed, or the store never opened and everything is in memory only.
    /// Settings surfaces it: silently reporting success for writes that never
    /// land is how a "cleared" history comes back at the next launch.
    @Published private(set) var hasStorageFailure: Bool

    private let context: ModelContext
    private let logger = Logger(subsystem: "dev.m2na.backpocket", category: "store")

    /// Notes and pinned items are exempt from expiry, so they are exempt from
    /// this cap as well. Zero means unlimited.
    ///
    /// Held as a closure, not a number: the user can change the limit in
    /// Settings while the app runs, and the very next add has to respect it.
    /// Storage asking Settings for it directly is what forced tests to write
    /// the process-wide defaults just to cap a throwaway store.
    private let disposableLimit: @MainActor () -> Int

    /// Copying tens of megabytes should not end up in the database verbatim.
    /// Bytes, not graphemes: `content` is a queried column, and 200,000
    /// graphemes of emoji is several megabytes in it.
    private let maxBytes = 200_000

    /// The tail of the image-capture chain. Digesting a copied image happens
    /// off the main actor (see `addImage`), and the suspension that buys is
    /// exactly what could let two copies interleave: each capture therefore
    /// awaits its predecessor before it looks at `items` at all.
    ///
    /// Without the chain, two images copied back to back would both still be
    /// digesting when either one reached the dedup lookup, so a re-copy of an
    /// image already in flight would miss the row it should have promoted and
    /// land as a second one; and whichever render happened to finish first
    /// would insert first, which `items` — maintained incrementally, never
    /// re-sorted — would then keep as the order the user copied in.
    ///
    /// Chaining onto it is safe because the property is main-actor isolated
    /// like everything else here: the read and the write in `addImage` happen
    /// in one uninterrupted turn, so no second copy can splice itself in.
    private var captureTail: Task<Void, Never>?

    /// The rows the last few deletes removed. Notes are permanent user data
    /// and ⌘⌫ is one keystroke away from the selection keys, so a delete has
    /// to be recoverable — briefly. See `DeletionUndo` for how briefly, and
    /// why holding it any longer would be the wrong kind of memory.
    ///
    /// Only the two `delete` methods record here. Expiry and the history limit
    /// are the app doing what the user configured, and Clear History is its
    /// own deliberate act; none of them is the slip this exists to catch.
    private var undo = DeletionUndo()

    /// Drops the retained rows when their window closes even if the app is
    /// never touched again.
    private var undoExpiry: Task<Void, Never>?

    init(
        context: ModelContext,
        disposableLimit: @escaping @MainActor () -> Int = { HistoryLimit.current }
    ) {
        self.context = context
        self.disposableLimit = disposableLimit
        // An in-memory fallback container is a storage failure that no later
        // success can clear — every write "succeeds" and none of it survives.
        hasStorageFailure = Persistence.isUsingFallbackStore
        reload()
    }

    // MARK: Reading

    func reload() {
        do {
            items = try context.fetch(FetchDescriptor<Item>()).sorted(by: Self.ordered)
            hasStorageFailure = Persistence.isUsingFallbackStore
        } catch {
            // Keeping the last known items beats publishing an empty array:
            // dedup, trimming and clearAll all read `items`, and "you have no
            // history" would make them operate on nothing.
            logger.error("fetch failed: \(error, privacy: .public)")
            hasStorageFailure = true
        }
    }

    /// Truncation counts UTF-8 bytes but never splits a character: a cut-off
    /// grapheme would render as garbage in every row that shows the clip.
    private func capped(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }

        var end = text.startIndex
        var used = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let size = text[end..<next].utf8.count
            if used + size > maxBytes { break }
            used += size
            end = next
        }
        return String(text[..<end])
    }

    /// Pinned first, then recency — a pin means "keep this in reach", and
    /// reach is the top of the list.
    private static func ordered(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.usedAt > rhs.usedAt
    }

    /// Where a fresh or promoted item lands: pinned items at the very top,
    /// everything else at the top of the unpinned block.
    private func insertionIndex(for item: Item) -> Int {
        item.isPinned ? 0 : (items.firstIndex { !$0.isPinned } ?? items.count)
    }

    // MARK: Writing

    func add(_ content: String, source: CopySource, html: String? = nil, rtf: Data? = nil) {
        let content = capped(content)

        // Copying the same thing again moves the existing entry to the top
        // instead of creating a duplicate. Images are excluded — their content
        // is a placeholder text must not hijack — and so are notes: copying
        // text that happens to equal a note must record a clip, not stamp a
        // source app onto the note and reorder it.
        if let existing = items.first(where: { !$0.isImage && !$0.isNote && $0.content == content })
        {
            existing.sourceApp = source.name
            existing.sourceBundleID = source.bundleID
            // Flavors only upgrade: re-copying identical text from a plain
            // source must not strip the rich flavors a styled copy captured.
            if html != nil { existing.contentHTML = html }
            if rtf != nil { existing.contentRTF = rtf }
            // File-ness follows the newest capture instead of upgrading: it is
            // a claim about what this clip IS, and an outdated claim is exactly
            // what makes a copied path paste as a file.
            existing.isFileCopy = source.isFileCopy
            promote(existing)
            save()
            return
        }

        let item = Item(
            content: content,
            source: source,
            isFileCopy: source.isFileCopy,
            html: html,
            rtf: rtf
        )
        context.insert(item)
        items.insert(item, at: insertionIndex(for: item))
        save()
        trimOverflow()
    }

    /// Returns before the row exists. Digesting a copied image — a SHA-256
    /// pass over up to ten megabytes, then a full ImageIO decode to render the
    /// thumbnail — is tens of milliseconds, and the poll that arrives here
    /// runs on the main thread deliberately, in `.common` run-loop mode, so it
    /// keeps firing while the panel is being scrolled. Doing that work inline
    /// dropped frames exactly when the user was looking at them.
    ///
    /// Only the digest moves; the database work still runs on the main actor,
    /// and in copy order, because `captureTail` serializes the captures.
    func addImage(_ data: Data, source: CopySource) {
        let previous = captureTail
        captureTail = Task { [weak self] in
            await previous?.value
            guard let digest = await Self.digest(data) else { return }
            self?.record(digest, data: data, source: source)
        }
    }

    /// Everything an image row needs that follows from the bytes alone, so
    /// that deriving it needs no store, no context, and no main actor.
    private struct ImageDigest {
        let width: Int
        let height: Int
        let hash: String
        let thumbnail: Data?
    }

    /// `nonisolated` and `async` together are what move this off the caller:
    /// such a function runs on the global executor by definition, never on the
    /// actor that awaited it. Nothing in here touches SwiftData, so there is
    /// no isolation left to give up.
    private nonisolated static func digest(_ data: Data) async -> ImageDigest? {
        // Before hashing: reading the header is a fraction of a SHA-256 pass
        // over ten megabytes, and bytes that don't decode can't be previewed
        // or pasted usefully — recording them would produce a dead row.
        guard let size = ImageInfo.pixelSize(of: data) else { return nil }

        return ImageDigest(
            width: size.width,
            height: size.height,
            hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            thumbnail: ImageInfo.thumbnailPNG(from: data)
        )
    }

    /// The half of `addImage` that has to be here: dedup against `items`, the
    /// insert, and the trim, in that order and one capture at a time.
    private func record(_ digest: ImageDigest, data: Data, source: CopySource) {
        // Same dedup contract as add(), keyed on the hash so re-copying an
        // image never compares megabytes of pixels.
        if let existing = items.first(where: { $0.imageHash == digest.hash }) {
            existing.sourceApp = source.name
            existing.sourceBundleID = source.bundleID
            promote(existing)
            save()
            return
        }

        let item = Item(
            content: "Image \(digest.width)×\(digest.height)",
            source: source,
            imageData: data,
            thumbnailData: digest.thumbnail,
            imageHash: digest.hash
        )
        context.insert(item)
        items.insert(item, at: insertionIndex(for: item))
        save()
        trimOverflow()
    }

    func addNote(_ text: String) {
        let note = Item(content: capped(text), isNote: true)
        context.insert(note)
        items.insert(note, at: insertionIndex(for: note))
        save()
    }

    /// Turns dropped content into a note: the matching clip converts in
    /// place, unknown content files as a new note. Content that already is a
    /// note stays put — a note dragged onto its own column must not duplicate.
    func adoptAsNote(_ content: String) {
        // Images are excluded like in add(): text matching an image's
        // placeholder must file as a new note, not silently hit the image.
        if let clip = items.first(where: { !$0.isNote && !$0.isImage && $0.content == content }) {
            convertToNote(clip)
        } else if !items.contains(where: { $0.isNote && $0.content == content }) {
            addNote(content)
        }
    }

    /// Turns a clipboard entry into a note in place, keeping its source and
    /// timestamps intact. Notes are text, so image clips never convert —
    /// this guard is also what makes adoptAsNote safe for image items.
    func convertToNote(_ item: Item) {
        guard isTracked(item), !item.isNote, !item.isImage else { return }
        item.isNote = true
        promote(item)
        save()
    }

    /// Returns whether the edit was applied and written; the editor stays open
    /// with the user's text rather than closing as if it had saved.
    @discardableResult
    func update(_ item: Item, content: String) -> Bool {
        // An image's content is a derived placeholder; overwriting it would
        // desync it from the pixels while the row still renders as an image.
        guard isTracked(item), !item.isImage else { return false }
        item.content = capped(content)
        // Hand-edited text is text, whatever it was captured as: an edited
        // path list must not keep pasting the files it no longer describes.
        item.isFileCopy = false
        promote(item)
        return save()
    }

    func markUsed(_ item: Item) {
        guard isTracked(item) else { return }
        promote(item)
        save()
    }

    func togglePin(_ item: Item) {
        guard isTracked(item) else { return }
        // usedAt stays put — pinning is not "using" — but the pinned block
        // lives at the top, so the list re-sorts around the flipped flag.
        item.isPinned.toggle()
        items.sort(by: Self.ordered)
        save()
    }

    func delete(_ item: Item) {
        guard isTracked(item) else { return }
        recordUndo([item])
        context.delete(item)
        items.removeAll { $0 === item }
        save()
    }

    /// One save for the whole handful — deleting a ⌘-collected selection
    /// must not write once per row.
    func delete(_ doomed: [Item]) {
        let tracked = doomed.filter(isTracked)
        guard !tracked.isEmpty else { return }
        recordUndo(tracked)
        remove(tracked)
        save()
    }

    // MARK: Undo

    /// Whether the last delete can still be taken back. Read alongside
    /// `revision` like everything else the panel derives from the store.
    var canUndoDelete: Bool {
        undo.canUndo(asOf: Date())
    }

    /// Puts the most recent delete back — one call per delete, however many
    /// rows that delete removed. Returns whether anything was restored, so a
    /// caller can stay silent instead of claiming an undo that had nothing
    /// left to give.
    ///
    /// The rows come back as new models: the deleted ones are gone from the
    /// context, and only `Store` may hand out references to live items.
    @discardableResult
    func undoDelete() -> Bool {
        guard let snapshots = undo.takeLatest(asOf: Date()) else { return false }

        let restored = snapshots.map { $0.restored() }
        restored.forEach(context.insert)
        items.append(contentsOf: restored)
        // A restore is the one insertion that does not carry the newest
        // usedAt, so `insertionIndex` — which assumes the global maximum —
        // would file a week-old row at the top. Re-sorting is what puts each
        // one back where it was, as pinning already does.
        items.sort(by: Self.ordered)
        // No trimOverflow here on purpose: reclaiming the row the user just
        // asked for would make undo silently do nothing whenever the history
        // sits at its cap. The cap is re-applied on the next copy and on
        // panel open, exactly as it is after the limit is lowered in Settings.
        return save()
    }

    private func recordUndo(_ doomed: some Collection<Item>) {
        undo.record(doomed, at: Date())
        // The window is enforced lazily on read, which is enough to decide
        // what may be restored but not enough to stop holding the bytes: an
        // app nobody touches again would keep the deleted content until quit.
        // One timer per recorded delete drops it on schedule instead, and
        // replacing it is safe because the newest batch always outlives the
        // ones beneath it.
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DeletionUndo.window))
            guard !Task.isCancelled else { return }
            self?.forgetExpiredDeletions()
        }
    }

    private func forgetExpiredDeletions() {
        // Views refilter on `revision` alone, so an offered undo going away
        // has to bump it — and a sweep that dropped nothing must not.
        if undo.forgetExpired(asOf: Date()) { revision += 1 }
    }

    // MARK: Housekeeping

    /// Deletes disposable entries older than `days`. Zero or negative means
    /// keep forever.
    func purgeExpired(days: Int) {
        guard days > 0 else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { $0.isDisposable && $0.usedAt < cutoff }
        guard !expired.isEmpty else { return }

        remove(expired)
        save()
    }

    /// Also called on panel open: the limit is read live from Settings, so
    /// lowering it — or unpinning past the cap — has nothing to reclaim the
    /// overflow until the next copy.
    func trimOverflow() {
        let limit = disposableLimit()
        guard limit > 0 else { return }

        let disposable = items.filter(\.isDisposable)
        guard disposable.count > limit else { return }

        remove(disposable.dropFirst(limit))
        save()
    }

    /// Clears clipboard history. Pinned items and notes stay — deleting what
    /// the user explicitly kept needs the dedicated actions below.
    func clearHistory() {
        // Guarded like every other mutation: views refilter on `revision`
        // alone, so bumping it for a clear that removed nothing is work with
        // nothing to show for it.
        let doomed = items.filter(\.isDisposable)
        guard !doomed.isEmpty else { return }
        remove(doomed)
        save()
    }

    func clearNotes() {
        let doomed = items.filter(\.isNote)
        guard !doomed.isEmpty else { return }
        remove(doomed)
        save()
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        items.forEach(context.delete)
        items = []
        save()
    }

    // MARK: Invariant maintenance

    /// Callers hold Item references across time — an open editor outlives its
    /// row, which trimming, expiry, or a delete elsewhere may remove meanwhile.
    /// Mutating a stale reference would re-insert the deleted model at the
    /// front: a ghost row with no backing store that also hijacks add()'s
    /// dedup. Such writes are dropped, as the old save-then-reload path did.
    private func isTracked(_ item: Item) -> Bool {
        items.contains { $0 === item }
    }

    /// usedAt = now is the global maximum, so the front of the item's own
    /// block keeps `items` ordered. Matched by identity: a note and a clip
    /// may carry equal content.
    private func promote(_ item: Item) {
        item.usedAt = Date()
        items.removeAll { $0 === item }
        items.insert(item, at: insertionIndex(for: item))
    }

    private func remove(_ doomed: some Collection<Item>) {
        doomed.forEach(context.delete)
        let ids = Set(doomed.map(ObjectIdentifier.init))
        items.removeAll { ids.contains(ObjectIdentifier($0)) }
    }

    /// Returns whether the write landed, so callers that promised the user
    /// something durable can tell them otherwise.
    @discardableResult
    private func save() -> Bool {
        defer { revision += 1 }
        do {
            try context.save()
            hasStorageFailure = Persistence.isUsingFallbackStore
            return true
        } catch {
            // Losing one write is recoverable; crashing over it is not. But
            // the published array must not keep claiming the write landed:
            // "Clear history" promising an irreversible delete and handing
            // every row back at the next launch is worse than the failure.
            logger.error("save failed: \(error, privacy: .public)")
            context.rollback()
            reload()
            hasStorageFailure = true
            return false
        }
    }

    #if DEBUG
    /// Waits until every image handed to `addImage` has been recorded. The app
    /// never needs this — a row that appears a few milliseconds later is the
    /// point — but a test that asserts on `items` straight after a copy does,
    /// and polling the published array instead would only re-introduce the
    /// timing it is trying to pin down.
    func imageCapturesDidFinish() async {
        await captureTail?.value
    }

    /// Demo seeding backdates timestamps directly on the models; the context
    /// has no autosave, so without this the spread never reaches the store
    /// file and a reused demo store collapses to a single instant.
    func persistDemoSeed() {
        save()
    }
    #endif
}
