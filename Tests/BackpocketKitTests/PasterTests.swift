import AppKit
import Testing

@testable import BackpocketKit

/// The flavor rules only — never the paste itself: pasteImage posts a
/// synthetic ⌘V into whatever window is frontmost.
@Suite struct PasterTests {
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("backpocket-paster-" + UUID().uuidString))
    }

    private func bitmap(side: Int = 4) throws -> NSBitmapImageRep {
        try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
    }

    @Test func tiffBytesAreNeverLabelledPNG() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let tiff = try #require(bitmap().tiffRepresentation)
        Paster.writeImage(tiff, to: pasteboard)

        // The stored bytes keep their own container; the other one is offered
        // as a rendition, so a PNG-only reader still gets something valid.
        #expect(pasteboard.data(forType: .tiff) == tiff)
        let png = try #require(pasteboard.data(forType: .png))
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test func pngBytesRideAsPNGWithATIFFRendition() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let png = try #require(bitmap().representation(using: .png, properties: [:]))
        Paster.writeImage(png, to: pasteboard)

        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.data(forType: .tiff) != nil)
    }
}
