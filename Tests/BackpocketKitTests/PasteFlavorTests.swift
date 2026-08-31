import AppKit
import Foundation
import Testing

@testable import BackpocketKit

/// Which representation of a stored item leaves the app.
///
/// Everything upstream defends this decision obsessively — the watcher
/// refuses to let typed text escalate into a file copy, and the migration
/// refuses to infer file-ness from content, both naming a private key's path
/// as the case that must not go wrong. Until now the branch those invariants
/// all terminate in lived inside a private method on the app delegate and had
/// no test at all.
@MainActor
@Suite struct PasteFlavorTests {
    private func withRealFile(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-flavor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "id_rsa")
        try Data("private key".utf8).write(to: file)
        try body(file)
    }

    /// One-byte-per-channel PNG. Real bytes, so the flavor rules are decided
    /// the way they are in production rather than against a stub.
    private var pngBytes: Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    // MARK: Choosing the flavor

    @Test func plainTextPastesAsTextWithItsRichFlavors() {
        let item = Item(content: "hello", html: "<b>hello</b>", rtf: Data([0x7B]))

        guard case .text(let text, let html, let rtf) = PasteFlavor.flavor(for: item) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "hello")
        #expect(html == "<b>hello</b>")
        #expect(rtf == Data([0x7B]))
    }

    @Test func typedTextPastesAsTextEvenWhenThatPathIsARealFile() throws {
        try withRealFile { file in
            // The regression the isFileCopy flag exists for. The TEXT
            // `/Users/you/.ssh/id_rsa` and a copy of that FILE are the same
            // string; pasting the former as a file attaches the key itself.
            let typed = Item(content: file.path(percentEncoded: false))

            guard case .text(let text, _, _) = PasteFlavor.flavor(for: typed) else {
                Issue.record("a typed path must never paste as a file")
                return
            }
            #expect(text == file.path(percentEncoded: false))
        }
    }

    @Test func aGenuineFileCopyPastesAsFiles() throws {
        try withRealFile { file in
            let item = Item(content: file.path(percentEncoded: false), isFileCopy: true)

            guard case .files(let urls) = PasteFlavor.flavor(for: item) else {
                Issue.record("expected files")
                return
            }
            #expect(urls == [file])
        }
    }

    @Test func aFileCopyWhoseFileIsGoneFallsBackToText() {
        // Existence is re-checked on every read, so a stale flag never
        // outlives the file — the path pastes as the text it now is.
        let gone = "/var/folders/backpocket-missing-\(UUID().uuidString)"
        let item = Item(content: gone, isFileCopy: true)

        guard case .text(let text, _, _) = PasteFlavor.flavor(for: item) else {
            Issue.record("expected text")
            return
        }
        #expect(text == gone)
    }

    @Test func anImageWinsOverEverythingElse() throws {
        try withRealFile { file in
            // An image item's content is only a placeholder ("Image 4×3"), so
            // if the branches were ever reordered the user would paste that
            // string instead of their screenshot.
            let item = Item(
                content: file.path(percentEncoded: false),
                isFileCopy: true,
                imageData: pngBytes,
                imageHash: "deadbeef"
            )

            guard case .image(let data) = PasteFlavor.flavor(for: item) else {
                Issue.record("expected image")
                return
            }
            #expect(data == pngBytes)
        }
    }

    @Test func aNoteAlwaysPastesAsItsText() throws {
        try withRealFile { file in
            let note = Item(content: file.path(percentEncoded: false), isNote: true)
            note.isFileCopy = true

            guard case .text(let text, _, _) = PasteFlavor.flavor(for: note) else {
                Issue.record("a note must never paste a file")
                return
            }
            #expect(text == file.path(percentEncoded: false))
        }
    }

    // MARK: Writing it

    /// A pasteboard of its own per test: writing to `.general` would clobber
    /// whatever the person running the suite has on their real clipboard.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("backpocket-flavor-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    @Test func writingTextCarriesTheRichFlavorsAlongside() throws {
        try withPasteboard { pasteboard in
            Paster.write("hello", html: "<b>hello</b>", rtf: Data([0x7B]), to: pasteboard)

            #expect(pasteboard.string(forType: .string) == "hello")
            #expect(pasteboard.string(forType: .html) == "<b>hello</b>")
            #expect(pasteboard.data(forType: .rtf) == Data([0x7B]))
        }
    }

    @Test func writingFilesOffersBothTheURLAndThePathText() throws {
        try withRealFile { file in
            try withPasteboard { pasteboard in
                Paster.writeFiles([file], to: pasteboard)

                // The URL is what makes a receiver attach or duplicate the
                // real file; the text is for apps that only take strings.
                #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [file])
                #expect(pasteboard.string(forType: .string) == file.path(percentEncoded: false))
            }
        }
    }

    @Test func writingTextLeavesNoStaleFileURLBehind() throws {
        try withRealFile { file in
            try withPasteboard { pasteboard in
                // Same pasteboard, files then text. A receiver reading the
                // leftover file URL would attach a file the user did not
                // choose to paste.
                Paster.writeFiles([file], to: pasteboard)
                Paster.write(file.path(percentEncoded: false), html: nil, rtf: nil, to: pasteboard)

                #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] == [])
                #expect(pasteboard.string(forType: .string) == file.path(percentEncoded: false))
            }
        }
    }
}
