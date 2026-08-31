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

    /// The files a Finder-style copy put on the pasteboard, one absolute
    /// path per line. Only a capture that really was a file copy qualifies:
    /// text alone can never escalate into a file. Existence is still checked
    /// on every read, so a path that no longer exists stops being a file copy
    /// and no stale flag outlives the file.
    var fileURLs: [URL] {
        guard isFileCopy, !isNote, !isImage, content.utf8.count <= 8_192,
            content.hasPrefix("/")
        else {
            return []
        }

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

    /// Non-nil when the content is a lone web URL — that is all "link" means
    /// here. A link stays an ordinary clip; the panel merely files it under
    /// its own section when the collect-links preference asks for that, so
    /// nothing is stored and the classification can never go stale.
    var linkURL: URL? {
        // Notes and images are excluded here rather than in WebLink: the rule
        // is about the text, the exclusions are about what this row IS.
        guard !isNote, !isImage else { return nil }
        return WebLink.url(in: content)
    }

    var isLink: Bool {
        linkURL != nil
    }
}
