import Foundation
import Testing

@testable import BackpocketKit

/// The sentence VoiceOver reads in place of a row. Everything the row says
/// silently — the source app's icon, a pin, a pick badge, a thumbnail, which
/// column it sits in — has to survive into these strings, because for a
/// screen-reader user they are the only thing the row says at all.
@MainActor
@Suite struct RowVoiceTests {
    /// Stands in for the four `.lproj` bundles, which ship inside the built
    /// app and are absent from a test process. A key nobody translated comes
    /// back shouting rather than silently reading as itself.
    private let table = [
        "a11y.kind.clip": "Clip",
        "a11y.kind.note": "Note",
        "a11y.kind.file": "File",
        "kind.image": "Image",
        "kind.link": "Link",
        "group.pinned": "Pinned",
        "a11y.from %@": "from %@",
        "a11y.stack %lld": "number %lld in the paste stack",
    ]

    private func localize(_ key: String) -> String {
        table[key] ?? "UNTRANSLATED(\(key))"
    }

    private func label(_ voice: RowVoice) -> String {
        voice.label(localize)
    }

    private var safari: CopySource {
        CopySource(name: "Safari", bundleID: "com.apple.Safari")
    }

    // MARK: What a row is

    @Test func aplainClipLeadsWithItsKindThenWhatItHolds() {
        let item = Item(content: "the quick brown fox", source: safari)
        let voice = RowVoice(clip: item, isPinned: false, stackNumber: nil)

        #expect(label(voice) == "Clip, the quick brown fox, from Safari")
    }

    /// The stored content of an image is the placeholder "Image 640×400", and
    /// speaking it whole reads the word "Image" twice. The thumbnail carries
    /// the rest for everyone else; here the dimensions are all there is.
    @Test func animageSaysItsSizeAndNotItsPlaceholder() {
        let item = Item(content: "Image 640×400", imageHash: "abc123")
        let voice = RowVoice(clip: item, isPinned: false, stackNumber: nil)

        #expect(voice.kind == .image(dimensions: "640×400"))
        #expect(label(voice) == "Image, 640×400")
    }

    /// A file copy's content is an absolute path, which is plumbing: the row
    /// draws the name and the icon, so the name is what is spoken.
    @Test func afileCopySaysItsNameAndNotItsPath() throws {
        try withRealFile { file in
            let item = Item(content: file.path(percentEncoded: false), source: safari)
            item.isFileCopy = true
            let voice = RowVoice(clip: item, isPinned: false, stackNumber: nil)

            #expect(voice.kind == .file(name: "id_rsa"))
            #expect(label(voice) == "File, id_rsa, from Safari")
        }
    }

    /// Asked of the item, never of the column. Under `LinkCollection.both`
    /// one link is a row in the clips list and a row in the links list, and
    /// the two must not describe the same thing differently.
    @Test func alinkIsALinkWhicheverColumnItWasReachedIn() {
        let item = Item(content: "https://example.com/docs#anchor", source: safari)
        let voice = RowVoice(clip: item, isPinned: false, stackNumber: nil)

        #expect(voice.kind == .link)
        // The whole URL, not a rebuilt one: the path and the fragment are
        // what tell two links from the same host apart.
        #expect(label(voice) == "Link, https://example.com/docs#anchor, from Safari")
    }

    @Test func anoteSaysItIsANoteAndNamesNoSource() {
        // A clip converted to a note keeps the app it was copied from, which
        // the notes column deliberately never shows — a note is something you
        // wrote, and "from Safari" would contradict the word before it.
        let item = Item(content: "buy milk", isNote: true, source: safari)
        let voice = RowVoice(note: item, isPinned: false, stackNumber: nil)

        #expect(label(voice) == "Note, buy milk")
    }

    // MARK: The state the row shows silently

    @Test func apinnedRowSaysSo() {
        let item = Item(content: "keep me")
        let clip = RowVoice(clip: item, isPinned: true, stackNumber: nil)
        let note = RowVoice(note: item, isPinned: true, stackNumber: nil)

        #expect(label(clip) == "Clip, keep me, Pinned")
        #expect(label(note) == "Note, keep me, Pinned")
    }

    /// The pin is read off the parameter, not off the item, for the same
    /// reason the row's `Equatable` conformance takes it separately: pinning
    /// leaves `usedAt` alone, and the flag is passed down as its own stamp.
    @Test func thepinComesFromTheRowAndNotFromTheItem() {
        let item = Item(content: "keep me")
        item.isPinned = true

        #expect(!label(RowVoice(clip: item, isPinned: false, stackNumber: nil)).contains("Pinned"))
    }

    /// The pick badge replaces the timestamp while a handful is collected, so
    /// its number is the only place the position exists on screen.
    @Test func acollectedRowSaysWhereItIsInTheStack() {
        let item = Item(content: "second")
        let voice = RowVoice(clip: item, isPinned: false, stackNumber: 2)

        #expect(label(voice) == "Clip, second, number 2 in the paste stack")
    }

    @Test func anuncollectedRowSaysNothingAboutTheStack() {
        let item = Item(content: "loose")
        #expect(label(RowVoice(clip: item, isPinned: false, stackNumber: nil)) == "Clip, loose")
    }

    /// Everything at once, in the order the eye takes the row: what it is,
    /// what it holds, then the trailing column's state.
    @Test func thesentenceRunsKindThenContentThenState() {
        let item = Item(content: "https://example.com", source: safari)
        let voice = RowVoice(clip: item, isPinned: true, stackNumber: 3)

        #expect(
            label(voice)
                == "Link, https://example.com, Pinned, from Safari, number 3 in the paste stack"
        )
    }

    // MARK: Nothing is spoken in English by accident

    /// Every word but the user's own content has to come out of the strings
    /// file. A hard-coded "Image" or "Pinned" would not fail a build, would
    /// not fail the key-parity check, and would simply be English in a
    /// Japanese app — so it is asserted here instead.
    @Test func everyWordButTheContentComesFromTheStringsFile() {
        let marked: (String) -> String = { "<\($0)>" }

        let image = Item(content: "Image 640×400", imageHash: "abc123")
        #expect(
            RowVoice(clip: image, isPinned: true, stackNumber: nil).label(marked)
                == "<kind.image>, 640×400, <group.pinned>"
        )

        let note = RowVoice(
            note: Item(content: "buy milk", isNote: true), isPinned: false, stackNumber: nil)
        #expect(note.label(marked) == "<a11y.kind.note>, buy milk")
    }

    /// The two counted phrases are formats, so a translation is free to put
    /// the number and the name where its own grammar wants them.
    @Test func thecountedPhrasesFillTheirPlaceholdersWhereverTheySit() {
        let item = Item(content: "x", source: safari)
        let voice = RowVoice(clip: item, isPinned: false, stackNumber: 7)

        let reordered: (String) -> String = { key in
            switch key {
            case "a11y.kind.clip": "클립"
            case "a11y.from %@": "%@에서 복사"
            case "a11y.stack %lld": "묶어 붙여넣기 %lld번"
            default: "UNTRANSLATED(\(key))"
            }
        }

        #expect(voice.label(reordered) == "클립, x, Safari에서 복사, 묶어 붙여넣기 7번")
    }

    // MARK: The image placeholder it is all built on

    @Test func imageDimensionsTakeTheTailOfThePlaceholder() {
        #expect(imageDimensions(of: "Image 1920×1080") == "1920×1080")
        // A placeholder that never got its size stays whole rather than
        // becoming an empty announcement.
        #expect(imageDimensions(of: "Image") == "Image")
        #expect(imageDimensions(of: "") == "")
    }

    /// A real file, because `Item.fileURLs` checks existence on every read
    /// and a made-up path would come back empty for the wrong reason.
    private func withRealFile(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-rowvoice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "id_rsa")
        try Data("private key".utf8).write(to: file)
        try body(file)
    }
}
