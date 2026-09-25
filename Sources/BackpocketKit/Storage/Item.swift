import Foundation
import SwiftData

/// The current shape of the model. The stored properties live in
/// `BackpocketSchemaV4` so that older shapes can stay frozen alongside it;
/// everything outside Storage/ names only `Item` and never a version.
typealias Item = BackpocketSchemaV4.Item

/// Derived reads. Deliberately outside the versioned declaration: they are
/// about how the app interprets a row, not about what is on disk, and a
/// migration must never see them.
extension Item {
    /// One-line text for the list row.
    /// Copied code drags its indentation along and shows as blank space in the
    /// list, so whitespace is collapsed. Rows render a single line, so only the
    /// head is processed — regexing the full body would make scrolling stutter.
    var preview: String {
        String(content.prefix(400))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The longest path list, in UTF-8 bytes, still read as a file copy.
    /// Anything longer reads as text, whatever the capture recorded.
    static let maxFileListBytes = 8_192

    /// Every check `fileURLs` makes that does not need the disk. `FileClip`
    /// runs this on every row render, ahead of a cache keyed by content alone,
    /// so it must stay free of filesystem reads and must cover every input to
    /// `fileURLs` other than `content`. A check that lived only in `fileURLs`
    /// would let one row's answer be served to another row with the same
    /// text — the typed-path confusion `FileClip` describes.
    var mayBeFileCopy: Bool {
        isFileCopy && !isNote && !isImage && content.hasPrefix("/")
            && content.utf8.count <= Item.maxFileListBytes
    }

    /// The files a Finder-style copy put on the pasteboard, one absolute
    /// path per line. Only a capture that really was a file copy qualifies:
    /// text alone can never escalate into a file. Existence is still checked
    /// on every read, so a path that no longer exists stops being a file copy
    /// and no stale flag outlives the file.
    var fileURLs: [URL] {
        guard mayBeFileCopy else { return [] }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var urls: [URL] = []
        for line in lines {
            let path = String(line)
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
                return []
            }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    var isFile: Bool {
        !fileURLs.isEmpty
    }

    /// Whether expiry may delete this item. Hand-written notes and pinned
    /// items are never purged.
    var isDisposable: Bool {
        !isNote && !isPinned
    }

    /// Judged by the hash column, not imageData: checking an .externalStorage
    /// attribute for nil faults the whole blob off disk, and this is read in
    /// hot paths (dedup scans, every row render).
    var isImage: Bool {
        imageHash != nil
    }

    /// The image's bytes, read without attaching them to this model. Paste,
    /// the detail card and undo all read the pixels through here.
    ///
    /// `imageData` read straight off a registered model faults the blob in,
    /// and the model keeps it for as long as it stays registered — for the
    /// rows `Store.items` holds, that is until quit, so every image pasted or
    /// previewed would stay resident for the rest of the session. A context
    /// made for this one fetch hands the bytes to the caller alone, and they
    /// are freed with the caller's copy.
    ///
    /// Only a saved image row takes that route. A text row answers from its
    /// property, which is nil and pins nothing. A model with no context was
    /// either never saved — a test's item, whose property still holds the
    /// bytes it was made with — or has been deleted, and a deleted image has
    /// nothing to give: the store no longer has the row, and the model may
    /// never have loaded the bytes, in which case reading the property traps.
    func loadImageData() -> Data? {
        guard isImage else { return imageData }
        guard let container = modelContext?.container else {
            // Saving is what gives a model a store identifier, so a model
            // without one never had a row to lose.
            return persistentModelID.storeIdentifier == nil ? imageData : nil
        }

        // A fetch rather than `model(for:)`: that hands back a placeholder
        // even for a row that is not in the store, and reading it traps. A
        // row that is not there yet — inserted, not saved — or a fetch that
        // fails falls back too: the bytes are still right, merely pinned.
        let id = persistentModelID
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let stored = try? ModelContext(container).fetch(descriptor).first else {
            return imageData
        }
        return stored.imageData
    }

    /// Non-nil when the content is a lone web URL — that is all "link" means
    /// here. A link stays an ordinary clip; the panel merely files it under
    /// its own section when the collect-links preference asks for that, so
    /// nothing is stored and the classification can never go stale.
    var linkURL: URL? {
        Self.linkURL(in: content, isNote: isNote, isImage: isImage)
    }

    /// `linkURL` over fields the caller has already read. Every property read
    /// on an `@Model` is a trip through SwiftData, and `PanelIndex` reads
    /// these for every item on every store change; this keeps the rule in one
    /// place without making it read them twice.
    static func linkURL(in content: String, isNote: Bool, isImage: Bool) -> URL? {
        // Notes and images are excluded here rather than in WebLink: the rule
        // is about the text, the exclusions are about what this row IS.
        guard !isNote, !isImage else { return nil }
        return WebLink.url(in: content)
    }

    var isLink: Bool {
        linkURL != nil
    }
}
