import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BackpocketKit

/// Image measurement and thumbnailing. Both run inside the clipboard poll on
/// every image copy, so they are on the app's hottest path and had no test.
@Suite struct ImageInfoTests {
    /// A real encoded image, because both functions go through ImageIO and a
    /// handful of invented bytes would fail for the wrong reason.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func pixelSizeReadsTheHeader() throws {
        let size = try #require(ImageInfo.pixelSize(of: png(width: 40, height: 25)))
        #expect(size.width == 40)
        #expect(size.height == 25)
    }

    @Test func pixelSizeRejectsBytesThatAreNotAnImage() {
        #expect(ImageInfo.pixelSize(of: Data("not an image".utf8)) == nil)
        #expect(ImageInfo.pixelSize(of: Data()) == nil)
    }

    @Test func theThumbnailIsAPNGCappedOnItsLongestSide() throws {
        let thumbnail = try #require(ImageInfo.thumbnailPNG(from: png(width: 900, height: 300)))

        // PNG magic: the row view hands these bytes straight to an image
        // decoder, so the container has to be what it claims.
        #expect(thumbnail.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let size = try #require(ImageInfo.pixelSize(of: thumbnail))
        #expect(max(size.width, size.height) <= ImageInfo.thumbnailMaxPixels)
        // Aspect ratio survives: a stretched thumbnail in the row would be
        // more obviously wrong than a small one.
        #expect(size.width > size.height)
    }

    @Test func aSmallImageIsNotUpscaled() throws {
        let thumbnail = try #require(ImageInfo.thumbnailPNG(from: png(width: 12, height: 8)))
        let size = try #require(ImageInfo.pixelSize(of: thumbnail))
        #expect(size.width == 12)
        #expect(size.height == 8)
    }

    @Test func thumbnailingRejectsBytesThatAreNotAnImage() {
        #expect(ImageInfo.thumbnailPNG(from: Data("not an image".utf8)) == nil)
        #expect(ImageInfo.thumbnailPNG(from: Data()) == nil)
    }
}
