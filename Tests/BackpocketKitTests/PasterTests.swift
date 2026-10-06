import AppKit
import Testing

@testable import BackpocketKit

/// The flavor rules only — never the paste itself: pasteImage posts a
/// synthetic ⌘V into whatever window is frontmost.
///
/// On the main actor because an image's second container is a promise, and
/// AppKit warns when one is kept for a read on any other thread. The app's
/// own reads, and those it serves for other apps, all happen there.
///
/// Every image here is 5×3: not square, so a rendition that swapped the
/// sides would show.
@MainActor
@Suite struct PasterTests {
    @Test func delayedPasteRequiresTheChosenAppAndClipboardGeneration() {
        let request = AutomaticPasteRequest(processID: 42, changeCount: 100)
        #expect(request.matches(processID: 42, changeCount: 100))
        #expect(!request.matches(processID: 43, changeCount: 100))
        #expect(!request.matches(processID: nil, changeCount: 100))
        #expect(!request.matches(processID: 42, changeCount: 101))
    }
    /// Decoded, not just sniffed: a rendition has to be the same picture.
    private func pixelSize(of data: Data) throws -> [Int] {
        let rep = try #require(NSBitmapImageRep(data: data))
        return [rep.pixelsWide, rep.pixelsHigh]
    }

    @Test func tiffBytesAreNeverLabelledPNG() throws {
        try withPrivatePasteboard { pasteboard in
            let tiff = try #require(Fixture.bitmap(width: 5, height: 3).tiffRepresentation)
            Paster.writeImage(tiff, to: pasteboard)

            // The stored bytes keep their own container, offered first; the
            // other one is offered as a rendition, so a PNG-only reader still
            // gets something valid.
            #expect(pasteboard.pasteboardItems?.first?.types == [.tiff, .png])
            #expect(pasteboard.data(forType: .tiff) == tiff)
            let png = try #require(pasteboard.data(forType: .png))
            #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
            #expect(try pixelSize(of: png) == [5, 3])
        }
    }

    @Test func pngBytesRideAsPNGWithATIFFRendition() throws {
        try withPrivatePasteboard { pasteboard in
            let png = try Fixture.png(width: 5, height: 3)
            Paster.writeImage(png, to: pasteboard)

            #expect(pasteboard.pasteboardItems?.first?.types == [.png, .tiff])
            #expect(pasteboard.data(forType: .png) == png)
            let tiff = try #require(pasteboard.data(forType: .tiff))
            #expect(try pixelSize(of: tiff) == [5, 3])
        }
    }

    /// ClipboardWatcher.suppressingOwnWrite skips exactly one change. A
    /// second one would be recorded as a copy, and so would one made when a
    /// reader asks for the promised container long after the write.
    @Test func anImageWriteIsOneChangeAndKeepingItsPromiseIsNone() throws {
        try withPrivatePasteboard { pasteboard in
            let png = try Fixture.png(width: 5, height: 3)
            let tiff = try #require(Fixture.bitmap(width: 5, height: 3).tiffRepresentation)
            for stored in [png, tiff] {
                let before = pasteboard.changeCount
                Paster.writeImage(stored, to: pasteboard)
                #expect(pasteboard.changeCount == before + 1)

                #expect(pasteboard.data(forType: .png) != nil)
                #expect(pasteboard.data(forType: .tiff) != nil)
                #expect(pasteboard.changeCount == before + 1)
            }
        }
    }

    /// The promised rendition holds the clip's bytes, up to the ten
    /// megabytes an image may weigh. It must last as long as the promise
    /// and no longer.
    @Test func theRenditionIsHeldOnlyWhileItIsStillPromised() throws {
        try withPrivatePasteboard { pasteboard in
            let png = try Fixture.png(width: 5, height: 3)

            Paster.writeImage(png, to: pasteboard)
            #expect(Paster.holdsRenditionForTesting)
            _ = pasteboard.data(forType: .tiff)
            #expect(!Paster.holdsRenditionForTesting)

            // Never read: the next write takes the pasteboard over, which
            // ends the promise just the same.
            Paster.writeImage(png, to: pasteboard)
            #expect(Paster.holdsRenditionForTesting)
            Paster.write("text", html: nil, rtf: nil, to: pasteboard)
            #expect(!Paster.holdsRenditionForTesting)
        }
    }
}
