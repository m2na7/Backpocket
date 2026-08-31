import Foundation

/// The one definition of "this text is a lone web URL".
///
/// Two copies of this rule drifted apart once already: the watcher accepted
/// any scheme while `Item.linkURL` required http/https, so copying
/// `mailto:me@example.com` beside a bitmap made the watcher treat the text as
/// a URL, keep the image, and discard text that Item then refused to call a
/// link at all. Both paths call this instead, so a change reaches both.
enum WebLink {
    /// Bytes, not characters: this runs per item on refilter and render hot
    /// paths, and grapheme-counting a 200k clip per call is the exact cost
    /// the caps elsewhere exist to avoid.
    static let maxBytes = 2_048

    /// Non-nil only for a single http(s) URL and nothing else. Surrounding
    /// whitespace is trimmed — a copy that picked up a trailing newline is
    /// still one URL — but any whitespace inside means this is prose.
    static func url(in text: String) -> URL? {
        guard text.utf8.count <= maxBytes else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host() != nil
        else { return nil }

        return url
    }
}
