import AppKit
import Testing

@testable import BackpocketKit

@MainActor
@Suite("ClipboardWatcher")
struct ClipboardWatcherTests {
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("backpocket-test-" + UUID().uuidString))
    }

    /// Real encoded bytes, not a stub: the watcher hands the data through
    /// verbatim, so tests compare against exactly what was written.
    private static func pngData(width: Int = 3, height: Int = 2) throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func fileCopyIsRecordedAsPathsNotTheFileName() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Self.pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let watcher = ClipboardWatcher(
            pasteboard: pasteboard,
            frontmostApplication: { CopySource(name: "Finder", bundleID: "com.apple.finder") }
        )
        var recorded: String?
        watcher.onCopy = { content, _ in
            guard case .text(let string, _, _) = content else { return }
            recorded = string
        }

        // Exactly what Finder puts on: the file URL, plus the display NAME as
        // text. Recording that name would paste a bare title where the file
        // belongs — the paths must win.
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString(file.deletingPathExtension().lastPathComponent, forType: .string)
        watcher.poll()

        #expect(recorded == file.path)

        let item = Item(content: try #require(recorded), isFileCopy: true)
        #expect(item.fileURLs.map(\.path) == [file.path])
    }

    @Test func aMultiFileCopyKeepsPickOrderAndIsAllOrNothing() throws {
        let first = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-a-\(UUID().uuidString).png")
        let second = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-b-\(UUID().uuidString).png")
        try Self.pngData().write(to: first)
        try Self.pngData().write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        // Order is load-bearing: Paster.pasteFiles hands these to the
        // receiver in exactly this sequence.
        let both = Item(content: "\(first.path)\n\(second.path)", isFileCopy: true)
        #expect(both.fileURLs.map(\.path) == [first.path, second.path])

        // One missing path invalidates the whole copy — half a file copy
        // would paste a partial selection.
        let partial = Item(
            content: "\(first.path)\n/tmp/backpocket-gone-\(UUID().uuidString)",
            isFileCopy: true
        )
        #expect(partial.fileURLs.isEmpty)
    }

    @Test func aPathThatNoLongerExistsIsNotAFileCopy() {
        let item = Item(
            content: "/tmp/backpocket-does-not-exist-\(UUID().uuidString).png",
            isFileCopy: true
        )
        // Existence is rechecked on every read, so the flag cannot outlive
        // the file it was set for.
        #expect(item.fileURLs.isEmpty)
        #expect(!item.isFile)
    }

    @Test func copiedTextThatLooksLikeAPathIsNeverAFileCopy() throws {
        // The flag is set at capture time from the pasteboard's own file
        // URLs, and only that can make an item paste as a file. Typing or
        // copying a real path as plain text must not escalate into one —
        // this is the whole point of storing the flag rather than sniffing
        // the content.
        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Self.pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let typed = Item(content: file.path)
        #expect(typed.fileURLs.isEmpty)
        #expect(!typed.isFile)

        // Control: the same existing path with the capture flag set is one.
        #expect(Item(content: file.path, isFileCopy: true).isFile)
    }

    @Test func notesAndImagesAreNeverFileCopies() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Self.pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // A clip converted to a note keeps its content; pasting it as a file
        // afterwards would contradict what the notes column shows.
        let note = Item(content: file.path, isNote: true, isFileCopy: true)
        #expect(note.fileURLs.isEmpty)

        let image = Item(content: file.path, isFileCopy: true, imageHash: "deadbeef")
        #expect(image.fileURLs.isEmpty)
    }

    @Test func pollReportsCopiedStringWithInjectedSource() {
        let pasteboard = Self.makePasteboard()
        // Named pasteboards live in the pasteboard server beyond the process;
        // release so repeated test runs don't accumulate them.
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: "Test App", bundleID: "dev.backpocket.test.source")
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [(string: String, source: CopySource)] = []
        watcher.onCopy = { content, source in
            guard case .text(let string, _, _) = content else { return }
            copies.append((string: string, source: source))
        }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        watcher.poll()

        #expect(copies.count == 1)
        #expect(copies.first?.string == "hello")
        #expect(copies.first?.source.name == "Test App")
        #expect(copies.first?.source.bundleID == "dev.backpocket.test.source")
    }

    @Test func pollWithUnchangedChangeCountDoesNotFireTwice() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copyCount = 0
        watcher.onCopy = { _, _ in copyCount += 1 }

        pasteboard.clearContents()
        pasteboard.setString("once", forType: .string)
        watcher.poll()
        watcher.poll()

        #expect(copyCount == 1)
    }

    @Test func skipCurrentChangeMutesOwnWriteButNotSubsequentCopy() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [String] = []
        watcher.onCopy = { content, _ in
            guard case .text(let string, _, _) = content else { return }
            copies.append(string)
        }

        pasteboard.clearContents()
        pasteboard.setString("own paste", forType: .string)
        watcher.skipCurrentChange()
        watcher.poll()

        #expect(copies.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("genuine copy", forType: .string)
        watcher.poll()

        #expect(copies == ["genuine copy"])
    }

    @Test func concealedItemIsNotReported() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copyCount = 0
        watcher.onCopy = { _, _ in copyCount += 1 }

        pasteboard.declareTypes([.string, ClipboardWatcher.concealedType], owner: nil)
        pasteboard.setString("secret", forType: .string)
        watcher.poll()

        #expect(copyCount == 0)
    }

    @Test func transientItemIsNotReported() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copyCount = 0
        watcher.onCopy = { _, _ in copyCount += 1 }

        pasteboard.declareTypes([.string, ClipboardWatcher.transientType], owner: nil)
        pasteboard.setString("transient", forType: .string)
        watcher.poll()

        #expect(copyCount == 0)
    }

    @Test func autoGeneratedItemIsNotReported() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copyCount = 0
        watcher.onCopy = { _, _ in copyCount += 1 }

        pasteboard.declareTypes([.string, ClipboardWatcher.autoGeneratedType], owner: nil)
        pasteboard.setString("generated", forType: .string)
        watcher.poll()

        #expect(copyCount == 0)
    }

    @Test func whitespaceOnlyStringIsNotReported() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copyCount = 0
        watcher.onCopy = { _, _ in copyCount += 1 }

        pasteboard.clearContents()
        pasteboard.setString("  \n\t  ", forType: .string)
        watcher.poll()

        #expect(copyCount == 0)
    }

    @Test func sourceInIgnoredAppsIsNotReported() throws {
        let bundleID = "dev.backpocket.test.ignored"

        try withScratchPreferences { defaults in
            defaults.set([bundleID], forKey: PreferenceKey.ignoredApps)

            let pasteboard = Self.makePasteboard()
            defer { pasteboard.releaseGlobally() }

            let source = CopySource(name: "Ignored App", bundleID: bundleID)
            let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

            var copyCount = 0
            watcher.onCopy = { _, _ in copyCount += 1 }

            pasteboard.clearContents()
            pasteboard.setString("should not surface", forType: .string)
            watcher.poll()

            #expect(copyCount == 0)
        }
    }

    @Test func pngOnPasteboardIsReportedAsImage() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        let png = try Self.pngData()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        watcher.poll()

        #expect(copies.count == 1)
        guard case .image(let data) = copies.first else {
            Issue.record("expected an image payload")
            return
        }
        #expect(data == png)
    }

    @Test func oversizedImageFallsThroughToStringFlavor() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        // The size gate reads only the byte count, so zero-filled data
        // stands in for a >10MB image without the cost of encoding one.
        pasteboard.clearContents()
        pasteboard.setData(Data(count: 10_000_001), forType: .png)
        pasteboard.setString("textual fallback", forType: .string)
        watcher.poll()

        #expect(copies.count == 1)
        guard case .text(let string, _, _) = copies.first else {
            Issue.record("expected the text fallback")
            return
        }
        #expect(string == "textual fallback")
    }

    /// The other side of that gate. Only the pair pins it: a test that
    /// records a 3-pixel PNG proves nothing about where the cap sits, and an
    /// inclusive limit that quietly turned exclusive would drop the largest
    /// screenshots a user can copy while leaving every small one working.
    @Test func animageMeasuringExactlyTheCapIsStillRecorded() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        pasteboard.clearContents()
        pasteboard.setData(Data(count: 10_000_000), forType: .png)
        watcher.poll()

        guard case .image(let data) = copies.first else {
            Issue.record("expected the image at the cap to be recorded")
            return
        }
        #expect(data.count == 10_000_000)
    }

    @Test func fileCopyWithImageFlavorsIsReportedAsText() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        // Copying an image file in Finder puts the file URL and bitmap
        // renditions on the pasteboard together; the path must win.
        pasteboard.declareTypes([.fileURL, .png, .string], owner: nil)
        pasteboard.setData(try Self.pngData(), forType: .png)
        pasteboard.setString("/tmp/picture.png", forType: .string)
        watcher.poll()

        #expect(copies.count == 1)
        guard case .text(let string, _, _) = copies.first else {
            Issue.record("expected the file path as text")
            return
        }
        #expect(string == "/tmp/picture.png")
    }

    @Test func textBesideImageRenditionIsReportedAsText() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        // Excel-style copies carry a bitmap rendition of the selection beside
        // the cell text; the searchable text must win.
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("Q1\t1200\nQ2\t1350", forType: .string)
        pasteboard.setData(try Self.pngData(), forType: .png)
        watcher.poll()

        #expect(copies.count == 1)
        guard case .text(let string, _, _) = copies.first else {
            Issue.record("expected the cell text")
            return
        }
        #expect(string == "Q1\t1200\nQ2\t1350")
    }

    @Test func loneURLBesideImageIsReportedAsImage() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [CopiedContent] = []
        watcher.onCopy = { content, _ in copies.append(content) }

        // A browser image copy ships the bitmap with the image's URL as its
        // only text; the bitmap is what the user meant to copy.
        let png = try Self.pngData()
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("https://example.com/pic.png", forType: .string)
        pasteboard.setData(png, forType: .png)
        watcher.poll()

        #expect(copies.count == 1)
        guard case .image(let data) = copies.first else {
            Issue.record("expected the bitmap")
            return
        }
        #expect(data == png)
    }

    @Test func rtfFlavorIsCapturedOnTextCopies() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var captured: [Data?] = []
        watcher.onCopy = { content, _ in
            guard case .text(_, _, let rtf) = content else { return }
            captured.append(rtf)
        }

        let rtf = Data("{\\rtf1 hello}".utf8)
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(rtf, forType: .rtf)
        watcher.poll()

        #expect(captured == [rtf])
    }

    @Test func oversizedRTFIsDroppedButStringStillReported() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [(string: String, rtf: Data?)] = []
        watcher.onCopy = { content, _ in
            guard case .text(let string, _, let rtf) = content else { return }
            copies.append((string: string, rtf: rtf))
        }

        pasteboard.clearContents()
        pasteboard.setString("still recorded", forType: .string)
        pasteboard.setData(Data(count: 300_001), forType: .rtf)
        watcher.poll()

        #expect(copies.count == 1)
        #expect(copies.first?.string == "still recorded")
        #expect(copies.first?.rtf == nil)
    }

    @Test func ownWriteSuppressionStillRecordsACopyThePollerNeverSaw() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [String] = []
        watcher.onCopy = { content, _ in
            guard case .text(let string, _, _) = content else { return }
            copies.append(string)
        }

        // The exact losing sequence: the user copies in another app and hits
        // the hotkey before the next poll tick, so this change is still
        // pending. Resyncing without draining it first discarded it forever —
        // the pasteboard only ever exposes its latest state.
        pasteboard.clearContents()
        pasteboard.setString("copied a moment ago", forType: .string)

        watcher.suppressingOwnWrite {
            pasteboard.clearContents()
            pasteboard.setString("what Backpocket pasted", forType: .string)
        }

        #expect(copies == ["copied a moment ago"])

        // And the app's own write stays suppressed afterwards, which is the
        // other half of the contract: pasting must not re-record the item
        // attributed to whatever app it was pasted into.
        watcher.poll()
        #expect(copies == ["copied a moment ago"])
    }

    @Test func suppressionCoversOnlyTheWriteItWraps() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let source = CopySource(name: nil, bundleID: nil)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

        var copies: [String] = []
        watcher.onCopy = { content, _ in
            guard case .text(let string, _, _) = content else { return }
            copies.append(string)
        }

        watcher.suppressingOwnWrite {
            pasteboard.clearContents()
            pasteboard.setString("our paste", forType: .string)
        }

        // A genuine copy landing after the suppressed write is ordinary
        // traffic again — the suppression must not latch.
        pasteboard.clearContents()
        pasteboard.setString("the next real copy", forType: .string)
        watcher.poll()

        #expect(copies == ["the next real copy"])
    }

    @Test func aFileCopyIsCapturedAsAFileCopyAndPlainTextIsNot() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Self.pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        func capture(_ write: (NSPasteboard) -> Void) -> CopySource? {
            let pasteboard = Self.makePasteboard()
            defer { pasteboard.releaseGlobally() }

            let watcher = ClipboardWatcher(
                pasteboard: pasteboard,
                frontmostApplication: { CopySource(name: "Finder", bundleID: "com.apple.finder") }
            )
            var captured: CopySource?
            watcher.onCopy = { _, source in captured = source }

            pasteboard.clearContents()
            write(pasteboard)
            watcher.poll()
            return captured
        }

        // File-ness cannot be recovered later — the TEXT of a path and a copy
        // of the FILE at that path produce identical content — so the capture
        // is the only place that can tell them apart.
        let fileCopy = try #require(capture { $0.writeObjects([file as NSURL]) })
        #expect(fileCopy.isFileCopy)

        let typed = try #require(capture { $0.setString(file.path, forType: .string) })
        #expect(!typed.isFileCopy)
    }

    @Test func aCopyOfTooManyFilesIsRecordedAsPlainText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One past the 64-file cap.
        let urls: [NSURL] = try (0..<65).map { index in
            let file = directory.appending(path: "file-\(index).txt")
            try Data("x".utf8).write(to: file)
            return file as NSURL
        }

        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let watcher = ClipboardWatcher(
            pasteboard: pasteboard,
            frontmostApplication: { CopySource(name: "Finder", bundleID: "com.apple.finder") }
        )
        var captured: CopySource?
        watcher.onCopy = { _, source in captured = source }

        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        watcher.poll()

        // Recording a truncated list AS a file copy would paste a silent
        // subset of what the user selected; as text the paths at least stay
        // readable and honest.
        #expect(try #require(captured).isFileCopy == false)
    }
}

// No longer serialized: every test that needs a stored value binds a defaults
// database of its own through withScratchPreferences, so two of them running at
// once cannot see each other's writes.
@Suite("Preferences")
struct PreferencesTests {
    @Test func rowCountsClampToTheirRanges() throws {
        try withScratchPreferences { defaults in
            #expect(LinkRows.current == LinkRows.default)
            defaults.set(-3, forKey: PreferenceKey.linkRows)
            #expect(LinkRows.current == LinkRows.range.lowerBound)
            defaults.set(99, forKey: PreferenceKey.linkRows)
            #expect(LinkRows.current == LinkRows.range.upperBound)
        }
    }

    /// An untouched install must behave exactly as the shipped defaults say,
    /// and the Settings controls start from these same constants — so a
    /// fallback drifting away from its declared default shows up here before
    /// it can show up as a control that disagrees with the running app.
    @Test func everyPreferenceFallsBackToItsDeclaredDefault() throws {
        try withScratchPreferences { _ in
            #expect(PasteBehavior.isAutomatic == PasteBehavior.default)
            #expect(PreviewBehavior.isEnabled == PreviewBehavior.default)
            #expect(NotesVisibility.isEnabled == NotesVisibility.default)
            #expect(FaviconFetching.isEnabled == FaviconFetching.default)
            #expect(PopupPosition.current == PopupPosition.default)
            #expect(LinkCollection.current == LinkCollection.default)
            #expect(LinkClickAction.current == LinkClickAction.default)
            #expect(AppLanguage.current == AppLanguage.default)
            #expect(LinkRows.current == LinkRows.default)
            #expect(HistoryLimit.current == HistoryLimit.default.rawValue)
            #expect(ExpiryOption.current == ExpiryOption.default.rawValue)
            #expect(NotesFraction.current == NotesFraction.default)
            #expect(PanelSize.stored == nil)
            #expect(IgnoredApps.bundleIDs.isEmpty)
        }
    }

    /// The values themselves, pinned: what a fresh install does is a product
    /// decision, and the test above would happily agree with a changed one.
    @Test func theShippedDefaultsAreWhatTheyHaveAlwaysBeen() {
        #expect(PasteBehavior.default == true)
        #expect(PreviewBehavior.default == true)
        #expect(NotesVisibility.default == true)
        #expect(FaviconFetching.default == true)
        #expect(PopupPosition.default == .mouse)
        #expect(LinkCollection.default == .both)
        #expect(LinkClickAction.default == .paste)
        #expect(AppLanguage.default == .system)
        #expect(LinkRows.default == 5)
        #expect(HistoryLimit.default == .fiveHundred)
        #expect(ExpiryOption.default == .week)
    }

    /// "Reset everything" iterates PreferenceKey.all, so a key missing from it
    /// would quietly survive the reset — a custom shortcut still bound, a
    /// language override still in force. Writing every declared key and
    /// demanding an empty store afterwards is the only check that cannot be
    /// fooled by a list that has fallen behind.
    @Test func resettingEverythingLeavesNoPreferenceBehind() throws {
        try withScratchPreferences { defaults in
            for name in PreferenceName.allCases {
                defaults.set("set", forKey: name.rawValue)
            }
            for key in PanelShortcut.defaultsKeys {
                defaults.set("set", forKey: key)
            }
            // Not a real language tag: AppleLanguages also lives in the global
            // domain, which every store reads through, so the reset cannot make
            // the key absent here — only its own write can be shown to be gone.
            // A tag no machine can be configured with keeps that distinction
            // true whatever the box running the suite has set.
            defaults.set(["zz-Reset"], forKey: "AppleLanguages")

            PreferenceKey.resetAll()

            let leftover = PreferenceName.allCases.map(\.rawValue)
                .filter { defaults.object(forKey: $0) != nil }
            #expect(leftover.isEmpty, "these keys outlived the reset: \(leftover)")
            #expect(PanelShortcut.defaultsKeys.allSatisfy { defaults.object(forKey: $0) == nil })
            #expect(defaults.array(forKey: "AppleLanguages") as? [String] != ["zz-Reset"])
        }
    }

    /// The guard on the injection itself. Every suite that dropped
    /// `.serialized` did so on the strength of reading a store of its own; if
    /// the accessors ever went back to the process-wide one those suites would
    /// still pass — writing and reading a single shared store agrees with
    /// itself — and would quietly be racing again. This is the one test that
    /// notices, because it checks both stores at once.
    @Test func preferencesReadTheInjectedStoreAndLeaveTheProcessOneAlone() throws {
        let key = PreferenceKey.linkRows
        let before = UserDefaults.standard.object(forKey: key) as? Int
        // Whatever this machine has stored, the injected value differs from it.
        let injected = before == 9 ? 8 : 9

        try withScratchPreferences { defaults in
            defaults.set(injected, forKey: key)
            #expect(LinkRows.current == injected)
            #expect(UserDefaults.standard.object(forKey: key) as? Int == before)
        }

        #expect(UserDefaults.standard.object(forKey: key) as? Int == before)
    }

    @Test func englishLanguageLabelIsSelfNamed() {
        #expect(AppLanguage.english.label == "English")
    }

    @Test func ignoredAppsDoesNotContainNilBundleID() {
        #expect(IgnoredApps.contains(nil) == false)
    }
}
