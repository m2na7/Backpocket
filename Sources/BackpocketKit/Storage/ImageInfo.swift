import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata and renditions derived from raw image bytes. Everything here is
/// computed once at record time — the list must never pay for decoding a
/// full-size image while scrolling.
enum ImageInfo {
    /// Longest side of the stored thumbnail, in pixels. Rows render far
    /// smaller than this even on Retina, so anything larger is wasted bytes.
    static let thumbnailMaxPixels = 240

    /// Pixel dimensions read from the header via ImageIO — no pixel decode.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(data as CFData, noCache),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        return (width, height)
    }

    /// PNG thumbnail with the longest side capped at `thumbnailMaxPixels`.
    /// ImageIO's thumbnailing decodes at reduced resolution instead of
    /// downscaling a full decode.
    static func thumbnailPNG(from data: Data) -> Data? {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
            ] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }

        return encodePNG(thumbnail)
    }

    /// ImageIO rather than NSBitmapImageRep, so Storage/ imports no UI
    /// framework: this is the model layer, and it also runs off the main
    /// actor, where AppKit drawing is not a documented guarantee.
    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
