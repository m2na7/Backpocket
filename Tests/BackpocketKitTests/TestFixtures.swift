import AppKit
import Foundation
import Testing

/// Real encoded images, one builder for every suite that needs one. The
/// store's digest, the favicon sanitizer and the detail card read dimensions
/// from the bytes or decode them, so a stub blob would be rejected as
/// undecodable and a test would pass for the wrong reason; the watcher hands
/// the bytes through verbatim, so its tests compare against exactly these.
///
/// Nonisolated, unlike `ViewFixture`: suites that are not on the main actor
/// build images too.
enum Fixture {
    /// An RGBA bitmap, zeroed unless `fill` says otherwise. Zeroed is fully
    /// transparent, which is fine wherever only the bytes matter and wrong
    /// wherever something has to be seen drawn.
    static func bitmap(width: Int, height: Int, fill: UInt8? = nil) throws -> NSBitmapImageRep {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let fill {
            // One call rather than a loop over every byte. Tests build
            // unoptimized, where the loop costs about 100 ms for a 640×400
            // image and this well under one.
            let plane = try #require(bitmap.bitmapData)
            plane.update(repeating: fill, count: bitmap.bytesPerRow * height)
        }
        return bitmap
    }

    static func png(width: Int, height: Int, fill: UInt8? = nil) throws -> Data {
        try #require(
            bitmap(width: width, height: height, fill: fill)
                .representation(using: .png, properties: [:]))
    }
}
