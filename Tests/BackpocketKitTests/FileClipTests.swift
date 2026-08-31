import Foundation
import Testing

@testable import BackpocketKit

/// The row's file-copy lookup. `Item.fileURLs` is defended heavily — a copied
/// piece of TEXT that merely looks like a path must never come back as a file —
/// and this cache sits in front of it, in the one layer no other test reaches.
@MainActor
@Suite struct FileClipTests {
    /// A real file, because `fileURLs` checks existence on every read and a
    /// made-up path would make every case below return empty for the wrong
    /// reason.
    private func withRealFile(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-fileclip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "id_rsa")
        try Data("private key".utf8).write(to: file)
        try body(file)
    }

    @Test func aFileCopyResolvesToItsURL() throws {
        try withRealFile { file in
            let item = Item(content: file.path(percentEncoded: false), isFileCopy: true)
            #expect(FileClip.urls(for: item) == [file])
        }
    }

    @Test func typedTextIsNeverAFileEvenWhenThePathExists() throws {
        try withRealFile { file in
            // The premise the whole isFileCopy flag exists for: the TEXT
            // `/Users/you/.ssh/id_rsa` and a copy of that FILE hold identical
            // content, and only the flag tells them apart.
            let typed = Item(content: file.path(percentEncoded: false))
            #expect(FileClip.urls(for: typed).isEmpty)
        }
    }

    @Test func aFileCopyAndTypedTextWithTheSamePathDoNotShareAnAnswer() throws {
        try withRealFile { file in
            let path = file.path(percentEncoded: false)

            // The regression: the cache was keyed on content alone, while
            // fileURLs also reads isFileCopy, isNote and isImage. Resolving
            // the real file copy first primed the entry, and the typed text
            // then hit it and rendered with a file icon and filename — the
            // exact confusion the capture path refuses to make.
            #expect(FileClip.urls(for: Item(content: path, isFileCopy: true)) == [file])
            #expect(FileClip.urls(for: Item(content: path)).isEmpty)

            // And in the other order, so neither one poisons the other.
            #expect(FileClip.urls(for: Item(content: path)).isEmpty)
            #expect(FileClip.urls(for: Item(content: path, isFileCopy: true)) == [file])
        }
    }

    @Test func flippingTheFlagOnOneItemChangesItsAnswer() throws {
        try withRealFile { file in
            // Store.add reuses the existing row for repeated content and
            // assigns isFileCopy in place, so the same Item really does flip.
            // A cache that ignored the flag would keep serving the old answer
            // for the rest of the session.
            let item = Item(content: file.path(percentEncoded: false), isFileCopy: true)
            #expect(FileClip.urls(for: item) == [file])

            item.isFileCopy = false
            #expect(FileClip.urls(for: item).isEmpty)
        }
    }

    @Test func aNoteIsNeverAFileCopy() throws {
        try withRealFile { file in
            let note = Item(content: file.path(percentEncoded: false), isNote: true)
            note.isFileCopy = true
            #expect(FileClip.urls(for: note).isEmpty)
        }
    }

    @Test func aMissingFileStopsBeingAFileCopy() throws {
        let gone = "/var/folders/backpocket-does-not-exist-\(UUID().uuidString)"
        #expect(FileClip.urls(for: Item(content: gone, isFileCopy: true)).isEmpty)
    }

    /// Writes files whose newline-joined paths measure exactly `bytes`, and
    /// hands back that content string. A large multi-file copy is the only way
    /// to reach the length cap: a single path cannot approach it, since the
    /// filesystem stops at a far shorter one.
    private func withFileCopy(ofExactly bytes: Int, _ body: (String) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-fileclip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stem = directory.path(percentEncoded: false) + "/"
        // Fixed-width names keep every path the same length, so only the last
        // one has to be measured to land the total on the byte.
        let width = 40
        let step = stem.count + width + 1  // the +1 is the joining newline

        var paths: [String] = []
        var total = -1  // the first path carries no newline before it
        while total + step + step <= bytes {
            paths.append(stem + String(format: "%0\(width)d", paths.count))
            total += step
        }

        let lastWidth = bytes - total - 1 - stem.count
        try #require((1...255).contains(lastWidth), "a temporary path this long breaks the setup")
        paths.append(stem + String(repeating: "z", count: lastWidth))

        for path in paths { try Data("file".utf8).write(to: URL(fileURLWithPath: path)) }

        let content = paths.joined(separator: "\n")
        try #require(content.utf8.count == bytes)
        try body(content)
    }

    /// The cap is inclusive, and the boundary is the whole of it: a copy that
    /// measures the limit exactly is a legitimate multi-file selection and must
    /// still resolve. Off by one here and the largest copies a user can make
    /// silently lose their file icons and paste as plain text.
    @Test func acopyMeasuringExactlyTheLengthCapStillResolves() throws {
        try withFileCopy(ofExactly: 8_192) { content in
            let item = Item(content: content, isFileCopy: true)
            #expect(FileClip.urls(for: item).count == content.components(separatedBy: "\n").count)
        }
    }

    /// And the other side of it, so the cap is a cap and not decoration.
    @Test func acopyOneByteOverTheLengthCapIsRejected() throws {
        try withFileCopy(ofExactly: 8_193) { content in
            #expect(FileClip.urls(for: Item(content: content, isFileCopy: true)).isEmpty)
        }
    }

    @Test func amultiFileCopyIsLabelledWithHowManyMoreThereAre() {
        // The count is of the files the name does not show, so it is one
        // fewer than the copy holds. Off by one and a two-file copy reads
        // "photo.png +2", which names a file that is not there.
        let urls = [URL(fileURLWithPath: "/tmp/photo.png"), URL(fileURLWithPath: "/tmp/note.txt")]
        #expect(FileClip.label(for: urls) == "photo.png +1")
        #expect(FileClip.label(for: [urls[0]]) == "photo.png")
        #expect(FileClip.label(for: []) == "")
    }

    @Test func nonPathContentIsRejectedWithoutTouchingTheDisk() {
        #expect(FileClip.urls(for: Item(content: "just some text")).isEmpty)
        #expect(FileClip.urls(for: Item(content: "")).isEmpty)
    }
}
