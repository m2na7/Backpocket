import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// Link classification is derived, never stored, so these pin the boundary:
/// what counts as a link decides what moves into the links section.
@MainActor
@Suite struct LinkTests {
    private let store: Store
    private let source = CopySource(name: "TestApp", bundleID: "dev.test.app")

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Item.self, configurations: configuration)
        store = Store(context: ModelContext(container))
    }

    private func item(_ content: String) throws -> Item {
        try #require(store.items.first { $0.content == content })
    }

    /// Classification reads only the content, so an unsaved Item is the
    /// cheapest way to pin a boundary without a round-trip through the store.
    private func linkURL(_ content: String) -> URL? {
        Item(content: content).linkURL
    }

    @Test func loneWebURLIsALink() throws {
        store.add("https://github.com/m2na7/backpocket/pull/12", source: source)

        let link = try item("https://github.com/m2na7/backpocket/pull/12")
        #expect(link.isLink)
        #expect(link.linkURL?.host() == "github.com")
    }

    @Test func surroundingWhitespaceIsTolerated() throws {
        // Browsers and chat apps often copy the URL with a trailing newline.
        store.add("  https://maccy.app\n", source: source)

        #expect(try #require(store.items.first).isLink)
    }

    @Test func proseContainingAURLIsNotALink() throws {
        store.add("see https://maccy.app for details", source: source)

        #expect(!(try #require(store.items.first).isLink))
    }

    @Test func internalWhitespaceIsNotALink() {
        // Two URLs, or a URL with a line break inside it, are content — the
        // section is for the single link the user meant to grab.
        #expect(linkURL("https://a.example.com https://b.example.com") == nil)
        #expect(linkURL("https://example.com/a\nhttps://example.com/b") == nil)
    }

    @Test func nonWebSchemesAreNotLinks() throws {
        store.add("ftp://mirror.example.com/file", source: source)
        store.add("file:///Users/me/notes.txt", source: source)
        store.add("mailto:me@example.com", source: source)

        // "Link" means a web page the panel can open and show a favicon for;
        // a scheme check that only asked for "some scheme" would file every
        // one of these under links.
        #expect(store.items.allSatisfy { !$0.isLink })
    }

    @Test func schemeMatchingIsCaseInsensitive() {
        // Copying from a mail client or an old document can hand back an
        // upper-cased scheme; URL keeps the case, so the comparison must not.
        #expect(linkURL("HTTPS://example.com")?.host() == "example.com")
        #expect(linkURL("Http://example.com")?.host() == "example.com")
    }

    @Test func schemelessAndPlainTextAreNotLinks() throws {
        store.add("github.com/m2na7/backpocket", source: source)
        store.add("just a sentence", source: source)
        store.add("https://", source: source)

        #expect(store.items.allSatisfy { !$0.isLink })
    }

    @Test func notesAreNeverLinks() throws {
        store.addNote("https://maccy.app")

        #expect(!(try #require(store.items.first).isLink))
    }

    @Test func imagesAreNeverLinks() {
        // An image's content is a generated placeholder, but were one ever to
        // read as a URL the row would file itself under links with no page to
        // open. isImage is checked before the text is parsed at all.
        let image = Item(content: "https://example.com/pic.png", imageHash: "deadbeef")
        #expect(image.isImage)
        #expect(!image.isLink)
    }

    @Test func theLengthCapIsExactlyTwoThousandFortyEightBytes() {
        // The cap is what separates a link from prose that starts with a
        // scheme; without both sides pinned it can drift silently.
        #expect(WebLink.maxBytes == 2_048)

        let atCap = "https://example.com/" + String(repeating: "a", count: WebLink.maxBytes - 20)
        #expect(atCap.utf8.count == WebLink.maxBytes)
        #expect(linkURL(atCap) != nil)

        let overCap = atCap + "a"
        #expect(overCap.utf8.count == WebLink.maxBytes + 1)
        #expect(linkURL(overCap) == nil)
    }

    @Test func theCapCountsBytesNotCharacters() {
        // "가" is three UTF-8 bytes, so this is 720 characters but 2,120
        // bytes. A `count`-based cap would admit it, and the byte count is
        // what the storage and the per-render work actually cost.
        let multibyte = "https://example.com/" + String(repeating: "가", count: 700)
        #expect(multibyte.count < WebLink.maxBytes)
        #expect(multibyte.utf8.count > WebLink.maxBytes)
        #expect(linkURL(multibyte) == nil)

        // Control: the same shape well under the cap is a link, so the
        // rejection above is the cap and not the non-ASCII characters.
        #expect(linkURL("https://example.com/" + String(repeating: "가", count: 10)) != nil)
    }

    /// Two definitions of "a lone web URL" existed once and disagreed: the
    /// watcher accepted any scheme and did not trim, so copying
    /// `mailto:...` beside a bitmap discarded text that Item refused to call
    /// a link. Both paths now call WebLink; this is the check that they
    /// still do.
    @Test(
        arguments: [
            "https://example.com/pic.png",
            "https://example.com/pic.png\n",
            "  https://example.com  ",
            "HTTPS://EXAMPLE.COM",
            "see https://example.com for details",
            "ftp://mirror.example.com/file",
            "mailto:me@example.com",
            "file:///Users/me/notes.txt",
            "example.com",
            "",
            "   ",
            "https://",
        ])
    func theWatcherAndItemAgreeOnWhatALinkIs(content: String) {
        // The watcher asks WebLink whether a bitmap beside this text is the
        // real copy; Item asks it whether the row belongs under links. A
        // string the two answer differently is content the user loses.
        #expect((WebLink.url(in: content) != nil) == Item(content: content).isLink)
    }
}
