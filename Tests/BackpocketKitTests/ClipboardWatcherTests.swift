import AppKit
import Testing

@testable import BackpocketKit

@MainActor
@Suite("ClipboardWatcher")
struct ClipboardWatcherTests {
    private static let finder = CopySource(name: "Finder", bundleID: "com.apple.finder")

    /// What one poll reports for whatever `write` puts on a private
    /// pasteboard, attributed to `source`. Most tests here are exactly that —
    /// clear, write, poll once, look at what came out — so they share it; the
    /// ones that need the watcher between two steps build their own.
    private func captures(
        from source: CopySource = CopySource(name: nil, bundleID: nil),
        _ write: (NSPasteboard) throws -> Void
    ) rethrows -> [(content: CopiedContent, source: CopySource)] {
        try withPrivatePasteboard { pasteboard in
            let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })
            var copies: [(content: CopiedContent, source: CopySource)] = []
            watcher.onCopy = { content, source in copies.append((content, source)) }

            pasteboard.clearContents()
            try write(pasteboard)
            watcher.poll()
            return copies
        }
    }

    @Test func fileCopyIsRecordedAsPathsNotTheFileName() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Fixture.png(width: 3, height: 2).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Exactly what Finder puts on: the file URL, plus the display NAME as
        // text. Recording that name would paste a bare title where the file
        // belongs — the paths must win.
        let copies = captures(from: Self.finder) { pasteboard in
            pasteboard.writeObjects([file as NSURL])
            pasteboard.setString(file.deletingPathExtension().lastPathComponent, forType: .string)
        }

        #expect(copies.map(\.content.string) == [file.path])

        let item = Item(content: try #require(copies.first?.content.string), isFileCopy: true)
        #expect(item.fileURLs.map(\.path) == [file.path])
    }

    @Test func aMultiFileCopyKeepsPickOrderAndIsAllOrNothing() throws {
        let first = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-a-\(UUID().uuidString).png")
        let second = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-b-\(UUID().uuidString).png")
        try Fixture.png(width: 3, height: 2).write(to: first)
        try Fixture.png(width: 3, height: 2).write(to: second)
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
        try Fixture.png(width: 3, height: 2).write(to: file)
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
        try Fixture.png(width: 3, height: 2).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // A clip converted to a note keeps its content; pasting it as a file
        // afterwards would contradict what the notes column shows.
        let note = Item(content: file.path, isNote: true, isFileCopy: true)
        #expect(note.fileURLs.isEmpty)

        let image = Item(content: file.path, isFileCopy: true, imageHash: "deadbeef")
        #expect(image.fileURLs.isEmpty)
    }

    @Test func pollReportsCopiedStringWithInjectedSource() {
        let source = CopySource(name: "Test App", bundleID: "dev.backpocket.test.source")

        let copies = captures(from: source) { $0.setString("hello", forType: .string) }

        #expect(copies.map(\.content.string) == ["hello"])
        #expect(copies.first?.source.name == "Test App")
        #expect(copies.first?.source.bundleID == "dev.backpocket.test.source")
    }

    @Test func pollWithUnchangedChangeCountDoesNotFireTwice() {
        withPrivatePasteboard { pasteboard in
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
    }

    @Test func skipCurrentChangeMutesOwnWriteButNotSubsequentCopy() {
        withPrivatePasteboard { pasteboard in
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
    }

    @Test func concealedItemIsNotReported() {
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.string, ClipboardWatcher.concealedType], owner: nil)
            pasteboard.setString("secret", forType: .string)
        }

        #expect(copies.isEmpty)
    }

    @Test func transientItemIsNotReported() {
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.string, ClipboardWatcher.transientType], owner: nil)
            pasteboard.setString("transient", forType: .string)
        }

        #expect(copies.isEmpty)
    }

    @Test func autoGeneratedItemIsNotReported() {
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.string, ClipboardWatcher.autoGeneratedType], owner: nil)
            pasteboard.setString("generated", forType: .string)
        }

        #expect(copies.isEmpty)
    }

    @Test func whitespaceOnlyStringIsNotReported() {
        let copies = captures { $0.setString("  \n\t  ", forType: .string) }

        #expect(copies.isEmpty)
    }

    @Test func sourceInIgnoredAppsIsNotReported() throws {
        let bundleID = "dev.backpocket.test.ignored"

        try withScratchPreferences { defaults in
            defaults.set([bundleID], forKey: PreferenceKey.ignoredApps)

            let source = CopySource(name: "Ignored App", bundleID: bundleID)
            let copies = captures(from: source) {
                $0.setString("should not surface", forType: .string)
            }

            #expect(copies.isEmpty)
        }
    }

    @Test func pngOnPasteboardIsReportedAsImage() throws {
        let png = try Fixture.png(width: 3, height: 2)

        let copies = captures { $0.setData(png, forType: .png) }

        #expect(copies.map(\.content.image) == [png])
    }

    @Test func oversizedImageFallsThroughToStringFlavor() {
        // The size gate reads only the byte count, so zero-filled data
        // stands in for a >10MB image without the cost of encoding one.
        let copies = captures { pasteboard in
            pasteboard.setData(Data(count: 10_000_001), forType: .png)
            pasteboard.setString("textual fallback", forType: .string)
        }

        #expect(copies.map(\.content.string) == ["textual fallback"])
    }

    /// The other side of that gate. Only the pair pins it: a test that
    /// records a 3-pixel PNG proves nothing about where the cap sits, and an
    /// inclusive limit that quietly turned exclusive would drop the largest
    /// screenshots a user can copy while leaving every small one working.
    @Test func animageMeasuringExactlyTheCapIsStillRecorded() {
        let copies = captures { $0.setData(Data(count: 10_000_000), forType: .png) }

        #expect(copies.map(\.content.image?.count) == [10_000_000])
    }

    @Test func fileCopyWithImageFlavorsIsReportedAsText() throws {
        let png = try Fixture.png(width: 3, height: 2)

        // Copying an image file in Finder puts the file URL and bitmap
        // renditions on the pasteboard together; the path must win.
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.fileURL, .png, .string], owner: nil)
            pasteboard.setData(png, forType: .png)
            pasteboard.setString("/tmp/picture.png", forType: .string)
        }

        #expect(copies.map(\.content.string) == ["/tmp/picture.png"])
    }

    @Test func textBesideImageRenditionIsReportedAsText() throws {
        let png = try Fixture.png(width: 3, height: 2)

        // Excel-style copies carry a bitmap rendition of the selection beside
        // the cell text; the searchable text must win.
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.string, .png], owner: nil)
            pasteboard.setString("Q1\t1200\nQ2\t1350", forType: .string)
            pasteboard.setData(png, forType: .png)
        }

        #expect(copies.map(\.content.string) == ["Q1\t1200\nQ2\t1350"])
    }

    @Test func loneURLBesideImageIsReportedAsImage() throws {
        let png = try Fixture.png(width: 3, height: 2)

        // A browser image copy ships the bitmap with the image's URL as its
        // only text; the bitmap is what the user meant to copy.
        let copies = captures { pasteboard in
            pasteboard.declareTypes([.string, .png], owner: nil)
            pasteboard.setString("https://example.com/pic.png", forType: .string)
            pasteboard.setData(png, forType: .png)
        }

        #expect(copies.map(\.content.image) == [png])
    }

    @Test func rtfFlavorIsCapturedOnTextCopies() {
        let rtf = Data("{\\rtf1 hello}".utf8)

        let copies = captures { pasteboard in
            pasteboard.setString("hello", forType: .string)
            pasteboard.setData(rtf, forType: .rtf)
        }

        #expect(copies.map(\.content.rtf) == [rtf])
    }

    @Test func oversizedRTFIsDroppedButStringStillReported() {
        let copies = captures { pasteboard in
            pasteboard.setString("still recorded", forType: .string)
            pasteboard.setData(Data(count: 300_001), forType: .rtf)
        }

        #expect(copies.map(\.content.string) == ["still recorded"])
        #expect(copies.map(\.content.rtf) == [nil])
    }

    @Test func ownWriteSuppressionStillRecordsACopyThePollerNeverSaw() {
        withPrivatePasteboard { pasteboard in
            let source = CopySource(name: nil, bundleID: nil)
            let watcher = ClipboardWatcher(pasteboard: pasteboard, frontmostApplication: { source })

            var copies: [String] = []
            watcher.onCopy = { content, _ in
                guard case .text(let string, _, _) = content else { return }
                copies.append(string)
            }

            // The exact losing sequence: the user copies in another app and
            // hits the hotkey before the next poll tick, so this change is
            // still pending. Resyncing without draining it first discarded it
            // forever — the pasteboard only ever exposes its latest state.
            pasteboard.clearContents()
            pasteboard.setString("copied a moment ago", forType: .string)

            watcher.suppressingOwnWrite {
                pasteboard.clearContents()
                pasteboard.setString("what Backpocket pasted", forType: .string)
            }

            #expect(copies == ["copied a moment ago"])

            // And the app's own write stays suppressed afterwards, which is
            // the other half of the contract: pasting must not re-record the
            // item attributed to whatever app it was pasted into.
            watcher.poll()
            #expect(copies == ["copied a moment ago"])
        }
    }

    @Test func suppressionCoversOnlyTheWriteItWraps() {
        withPrivatePasteboard { pasteboard in
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
    }

    @Test func aFileCopyIsCapturedAsAFileCopyAndPlainTextIsNot() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "backpocket-\(UUID().uuidString).png")
        try Fixture.png(width: 3, height: 2).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // File-ness cannot be recovered later — the TEXT of a path and a copy
        // of the FILE at that path produce identical content — so the capture
        // is the only place that can tell them apart.
        let fileCopy = try #require(
            captures(from: Self.finder) { $0.writeObjects([file as NSURL]) }.first)
        #expect(fileCopy.source.isFileCopy)

        let typed = try #require(
            captures(from: Self.finder) { $0.setString(file.path, forType: .string) }.first)
        #expect(!typed.source.isFileCopy)
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

        let copies = captures(from: Self.finder) { $0.writeObjects(urls) }

        // Recording a truncated list AS a file copy would paste a silent
        // subset of what the user selected; as text the paths at least stay
        // readable and honest.
        #expect(try #require(copies.first).source.isFileCopy == false)
    }
}

/// The parts of a copy the assertions above compare, so each can state what
/// it expects in one line rather than unwrap the payload by hand. nil when the
/// copy is the other kind.
extension CopiedContent {
    fileprivate var string: String? {
        guard case .text(let string, _, _) = self else { return nil }
        return string
    }

    fileprivate var rtf: Data? {
        guard case .text(_, _, let rtf) = self else { return nil }
        return rtf
    }

    fileprivate var image: Data? {
        guard case .image(let data) = self else { return nil }
        return data
    }
}
