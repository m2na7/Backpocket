import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import BackpocketKit

/// Smoke tests for the panel's views: they build, they lay out, they draw.
/// See `ViewSmokeHarness` for exactly what that is worth and what it is not.
@MainActor
@Suite
struct PanelViewSmokeTests {
    /// The panel's first-run frame, and its floor. Both are rendered because
    /// the two columns give way differently as the width runs out.
    private static let defaultFrame = NSSize(width: 680, height: 360)
    private static let minimumFrame = NSSize(
        width: PanelSize.minWidth, height: PanelSize.minHeight)

    /// The panel with every callback stubbed. Nothing here presses anything,
    /// so the closures exist only to satisfy the initializer.
    private func panel(_ store: Store) -> ContentView {
        ContentView(
            store: store,
            onPaste: { _ in },
            onClose: {},
            onOpenSettings: {},
            onDetail: { _, _ in },
            onEdit: { _ in },
            onPasteMarkdown: { _ in },
            onOpenLink: { _ in },
            onPasteStack: { _ in }
        )
    }

    /// Pins the preferences that would otherwise let the machine decide what
    /// gets rendered. The accessibility gate swaps the whole panel for the
    /// onboarding screen unless the permission is granted — turning automatic
    /// paste off satisfies the gate without asking anything of the machine —
    /// and the dwell preview would arm a timer behind the render.
    ///
    /// The panel snapshots the pane preferences into `@State` as it is built,
    /// so the view has to be constructed inside `body`, not handed in.
    private func withPanelDefaults(
        links: LinkCollection = .both,
        showsNotes: Bool = true,
        discriminator: String = "",
        fileID: String = #fileID,
        line: Int = #line,
        _ body: () throws -> Void
    ) throws {
        try withScratchPreferences(discriminator: discriminator, fileID: fileID, line: line) {
            defaults in
            defaults.set(false, forKey: PreferenceKey.pasteAutomatically)
            defaults.set(false, forKey: PreferenceKey.showPreview)
            defaults.set(showsNotes, forKey: PreferenceKey.showNotes)
            defaults.set(links.rawValue, forKey: PreferenceKey.collectLinks)
            try body()
        }
    }

    // MARK: The panel

    /// The first thing a new user sees. Empty is not a quiet case: the column
    /// builder takes its other branch entirely, and an off-by-one in a list
    /// with no rows has nowhere to hide.
    @Test func theemptyPanelRenders() throws {
        let fixture = try ViewFixture()
        try withPanelDefaults {
            try expectRenders(
                panel(fixture.store), named: "empty panel", at: Self.defaultFrame)
        }
    }

    @Test func thepopulatedPanelRenders() throws {
        let fixture = try ViewFixture()
        try fixture.fill()
        try withPanelDefaults {
            try expectRenders(
                panel(fixture.store), named: "populated panel", at: Self.defaultFrame)
        }
    }

    /// Both pane preferences, in every combination: each one removes or
    /// refills a column, and the geometry that divides the remaining width is
    /// written once for every arrangement. `.both` draws the same rows in two
    /// lists at once, which is the arrangement with the most to go wrong.
    @Test func thepanelRendersWithEitherColumnTurnedOff() throws {
        let fixture = try ViewFixture()
        try fixture.fill()

        for links in LinkCollection.allCases {
            for showsNotes in [true, false] {
                let name = "links=\(links.rawValue) notes=\(showsNotes)"
                try withPanelDefaults(
                    links: links,
                    showsNotes: showsNotes,
                    discriminator: name
                ) {
                    try expectRenders(panel(fixture.store), named: name, at: Self.defaultFrame)
                }
            }
        }
    }

    /// The panel is resizable down to a floor where both columns are near
    /// their minimum widths — the arithmetic that splits them is the part
    /// that goes wrong at the edge, not in the middle.
    @Test func thepanelRendersAtItsMinimumSize() throws {
        let fixture = try ViewFixture()
        try fixture.fill()
        try withPanelDefaults {
            try expectRenders(
                panel(fixture.store), named: "minimum frame", at: Self.minimumFrame)
        }
    }

    /// A store that only holds notes, and one that only holds clips: either
    /// way one column is empty while the other is not, which is the
    /// arrangement that mixes the two branches of the column builder.
    @Test func thepanelRendersWithOnlyOneKindOfContent() throws {
        let notesOnly = try ViewFixture()
        notesOnly.addNote("the only note")
        try withPanelDefaults(discriminator: "notes") {
            try expectRenders(panel(notesOnly.store), named: "notes only", at: Self.defaultFrame)
        }

        let clipsOnly = try ViewFixture()
        clipsOnly.addText("the only clip")
        try withPanelDefaults(discriminator: "clips") {
            try expectRenders(panel(clipsOnly.store), named: "clips only", at: Self.defaultFrame)
        }
    }

    /// The panel keeps rendering after the store moves under it. A deleted
    /// item is the one that bites: the lists hold references, and reading a
    /// property off a deleted SwiftData model traps.
    @Test func thepanelRendersAfterTheStoreChanges() throws {
        let fixture = try ViewFixture()
        try fixture.fill()
        try withPanelDefaults {
            let view = panel(fixture.store)
            try expectRenders(view, named: "before deletion", at: Self.defaultFrame)

            for item in fixture.store.items where !item.isPinned {
                fixture.store.delete(item)
            }
            try expectRenders(view, named: "after deletion", at: Self.defaultFrame)
        }
    }

    /// The real composition root: the window class the app builds at launch,
    /// hosting the real view. Built but never shown — `show()` would order a
    /// window onto the user's screen and read the pointer's display, neither
    /// of which belongs in a test — so this covers construction and the
    /// hosted view, not placement.
    @Test func thepanelWindowBuildsAndHostsTheView() throws {
        let fixture = try ViewFixture()
        try fixture.fill()
        try withPanelDefaults {
            let window = BackpocketPanel(rootView: panel(fixture.store))
            #expect(window.canBecomeKey)
            #expect(!window.isVisible)
            #expect(
                window.minSize == NSSize(width: PanelSize.minWidth, height: PanelSize.minHeight))

            let hosted = try #require(window.contentView)
            hosted.frame = NSRect(origin: .zero, size: Self.defaultFrame)
            hosted.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        }
    }

    // MARK: Rows

    /// Rows are rendered on their own rather than through the panel: the
    /// AppKit table under a SwiftUI `List` builds no rows without a run loop
    /// (see the harness), and one row kind at a time is the only way to know
    /// which one broke.
    private static let rowFrame = NSSize(width: 320, height: 30)

    private func row(
        _ item: Item,
        query: String = "",
        highlighted: Bool = false,
        shortcut: String? = nil,
        stackNumber: Int? = nil,
        stacking: Bool = false,
        asLink: Bool = false
    ) -> ItemRow {
        ItemRow(
            item: item,
            usedAt: item.usedAt,
            isPinned: item.isPinned,
            shortcut: shortcut,
            stackNumber: stackNumber,
            stacking: stacking,
            query: query,
            highlighted: highlighted,
            asLink: asLink,
            onHover: {}, onExit: {}, onActivate: {}, onToggleStack: {},
            onConvert: {}, onTogglePin: {}, onDelete: {},
            onPasteMarkdown: {}, onOpenLink: {}
        )
    }

    /// Every content kind through the same row: each takes a different branch
    /// of `leading` and of `preview`, and the file and image branches reach
    /// outside the row for an icon and a decode.
    @Test func everyClipRowKindRenders() throws {
        let fixture = try ViewFixture()
        let cases: [(String, Item)] = [
            ("text", fixture.addText("an ordinary clipboard capture")),
            ("code", fixture.addCode("let total = items.reduce(0, +)")),
            ("link", fixture.addLink()),
            ("image", try fixture.addImage()),
            ("file", try fixture.addFileCopy()),
            ("note", fixture.addNote("a note shown in the history column")),
        ]

        for (name, item) in cases {
            try expectRenders(row(item), named: "row \(name)", at: Self.rowFrame)
        }
    }

    /// An image clip whose thumbnail bytes never arrived, or will not decode.
    /// The row has a branch for it, and that branch is what a user with a
    /// half-written capture actually sees.
    @Test func animageRowWithoutAthumbnailRenders() throws {
        let fixture = try ViewFixture()
        let item = try fixture.addImage()
        item.thumbnailData = nil
        try expectRenders(row(item), named: "image without thumbnail", at: Self.rowFrame)

        item.thumbnailData = Data("not a png".utf8)
        try expectRenders(row(item), named: "image with junk thumbnail", at: Self.rowFrame)
    }

    /// A link row draws its host emphasized in place, which means finding the
    /// host inside the raw string. The cases below are the ones where that
    /// search comes back empty or lands somewhere surprising.
    @Test func linkRowsRenderForawkwardURLs() throws {
        let fixture = try ViewFixture()
        let urls = [
            "https://example.com",
            "http://localhost:3000/#/route",
            "https://例え.テスト/path",
            "https://user:pw@example.com:8443/a?b=c#d",
            "https://example.com/" + String(repeating: "segment/", count: 60),
        ]
        for url in urls {
            let item = fixture.addLink(url)
            try expectRenders(
                row(item, asLink: true), named: "link \(url.prefix(40))",
                at: Self.rowFrame)
        }
    }

    /// The trailing column has several occupants and a priority order between
    /// them, and the leading one is taken over by the ⌘ slot while Command is
    /// held. Each arrangement is a different row to lay out.
    @Test func rowDecorationsRender() throws {
        let fixture = try ViewFixture()
        let item = fixture.addText("a clip wearing every decoration in turn", pinned: true)

        try expectRenders(
            row(item, highlighted: true), named: "highlighted", at: Self.rowFrame)
        try expectRenders(
            row(item, shortcut: "3"), named: "shortcut slot", at: Self.rowFrame)
        try expectRenders(
            row(item, shortcut: "⇧3", asLink: true), named: "links slot", at: Self.rowFrame)
        try expectRenders(
            row(item, stackNumber: 2, stacking: true), named: "stack badge", at: Self.rowFrame)
        try expectRenders(
            row(item, stacking: true), named: "stacking, unpicked", at: Self.rowFrame)
        try expectRenders(
            row(item, query: "clip"), named: "search match", at: Self.rowFrame)
        // A query that matches the row's presence but not its preview text is
        // routine while typing, and it is the branch where the range lookup
        // comes back nil.
        try expectRenders(
            row(item, query: "nothing here"), named: "search miss", at: Self.rowFrame)
    }

    /// Content that is not a tidy sentence. A row collapses whatever it is
    /// given into one line, and each of these makes that harder in a
    /// different way: nothing to show, only whitespace, far too much, a
    /// bidirectional override, graphemes built from several scalars.
    @Test func rowsRenderForawkwardContent() throws {
        let fixture = try ViewFixture()
        let contents = [
            "",
            "   \n\t  \n ",
            String(repeating: "long ", count: 4_000),
            "\u{202E}right to left override",
            "🇰🇷👨‍👩‍👧‍👦 family and flag graphemes",
            "line one\nline two\nline three",
        ]
        for content in contents {
            let item = fixture.addText(content)
            try expectRenders(
                row(item), named: "content \(content.prefix(20).debugDescription)",
                at: Self.rowFrame)
        }
    }

    private func noteRow(
        _ data: NoteRowData,
        query: String = "",
        highlighted: Bool = false,
        pointerHovering: Bool = false,
        shortcut: Int? = nil,
        stackNumber: Int? = nil,
        stacking: Bool = false
    ) -> NoteRow {
        NoteRow(
            item: data.item,
            usedAt: data.item.usedAt,
            isPinned: data.item.isPinned,
            timeLabel: data.timeLabel,
            shortcut: shortcut,
            stackNumber: stackNumber,
            stacking: stacking,
            query: query,
            highlighted: highlighted,
            pointerHovering: pointerHovering,
            onHover: {}, onExit: {}, onActivate: {}, onToggleStack: {},
            onEdit: {}, onTogglePin: {}, onDelete: {}
        )
    }

    /// The notes row's trailing slot swaps between a pick badge, the inline
    /// edit and delete buttons, and the timestamp. The label is built with a
    /// pinned calendar and locale so this says nothing about the machine's.
    @Test func noteRowsRender() throws {
        let fixture = try ViewFixture()
        let item = fixture.addNote("a note with something worth reading in it")
        let label = NoteGroup.rowLabel(
            for: item.usedAt, now: fixture.now,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US_POSIX"))
        let data = NoteRowData(item: item, timeLabel: label)

        try expectRenders(noteRow(data), named: "note row", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, highlighted: true), named: "note highlighted", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, pointerHovering: true), named: "note hovered", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, shortcut: 4), named: "note shortcut", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, stackNumber: 1, stacking: true), named: "note picked",
            at: Self.rowFrame)
        try expectRenders(
            noteRow(data, stacking: true), named: "note stacking", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, query: "worth"), named: "note search match", at: Self.rowFrame)
        try expectRenders(
            noteRow(data, query: "absent"), named: "note search miss", at: Self.rowFrame)
    }

    /// The shared row chrome, on its own. Both are tiny and both size
    /// themselves, so a degenerate fitting size here is a real defect.
    @Test func rowChromeRenders() throws {
        try expectRenders(
            StackBadge(number: 9), named: "stack badge",
            minimum: NSSize(width: 10, height: 10))
        for label in ["1", "⇧9", "10"] {
            try expectRenders(
                ShortcutChip(label: label), named: "chip \(label)",
                minimum: NSSize(width: 10, height: 10))
        }
        try expectRenders(
            SectionTitle(title: "clips.title", count: 0), named: "section title, zero",
            minimum: NSSize(width: 10, height: 10))
        try expectRenders(
            SectionTitle(title: "clips.title", count: 9_999), named: "section title, many",
            minimum: NSSize(width: 10, height: 10))
        try expectRenders(
            EmptyLine(text: "clips.empty"), named: "empty line",
            at: NSSize(width: 300, height: 60))
    }

    // MARK: The detail card

    /// The card is the one view already measured elsewhere; what is new here
    /// is that it is also drawn, and drawn for each of its layouts.
    @Test func thedetailCardRendersForEveryLayout() throws {
        let fixture = try ViewFixture()

        let prose = fixture.addText(
            String(repeating: "some ordinary prose that wraps. ", count: 20))
        try expectRenders(
            DetailContent(
                text: prose.content, highlighted: nil, language: nil, meta: DetailMeta(prose)),
            named: "prose card", minimum: NSSize(width: 50, height: 30))

        let code = fixture.addCode("func hello() {\n    print(\"hi\")\n}")
        try expectRenders(
            DetailContent(
                text: code.content,
                highlighted: SyntaxHighlighter.highlight(code.content, language: .swift),
                language: .swift, meta: DetailMeta(code)),
            named: "code card", minimum: NSSize(width: 50, height: 30))

        let link = fixture.addLink()
        try expectRenders(
            DetailContent(
                text: link.content, highlighted: nil, language: nil,
                linkHost: link.linkURL?.host(), meta: DetailMeta(link)),
            named: "link card", minimum: NSSize(width: 50, height: 30))

        let image = try fixture.addImage()
        let decoded = try #require(image.imageData.flatMap(NSImage.init(data:)))
        try expectRenders(
            DetailContent(
                text: "", highlighted: nil, language: nil, image: decoded,
                imageMax: CGSize(width: 400, height: 300), imageStats: "640×400 · 12 KB",
                meta: DetailMeta(image)),
            named: "image card", minimum: NSSize(width: 50, height: 30))

        // An empty clip still has a footer, so the card must not collapse to
        // nothing — which is precisely what a fitting size of zero would be.
        let empty = fixture.addText("")
        try expectRenders(
            DetailContent(
                text: "", highlighted: nil, language: nil, meta: DetailMeta(empty)),
            named: "empty card", minimum: NSSize(width: 50, height: 20))
    }
}
