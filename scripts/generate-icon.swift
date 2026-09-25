// Renders Resources/AppIcon-master.png into the App Store asset catalog's icon
// roster and writes a compact README preview. build.sh packs the same roster
// into the direct download's AppIcon.icns, so there is no .icns to regenerate
// here. Run from anywhere:
//
//   swift scripts/generate-icon.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

func render(_ source: CGImage, pixels: Int) -> CGImage {
    // An opaque master renders into an opaque context. An alpha-capable one
    // would store an alpha channel that is 255 on every pixel, which iconutil
    // keeps: about 400 KB of the direct download for nothing visible. The App
    // Store build gains nothing either way, since actool re-encodes every
    // rendition itself. ImageIO reads an RGB PNG as noneSkipLast, not none.
    let alphaInfo: CGImageAlphaInfo
    switch source.alphaInfo {
    case .none, .noneSkipLast, .noneSkipFirst:
        alphaInfo = .noneSkipLast
    default:
        alphaInfo = .premultipliedLast
    }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: alphaInfo.rawValue
          )
    else { fail("could not create \(pixels)px context") }

    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { fail("could not render \(pixels)px image") }
    return image
}

func renderPreview(_ source: CGImage, pixels: Int) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { fail("could not create README preview context") }

    let inset = CGFloat(pixels) * 0.035
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let bounds = canvas.insetBy(dx: inset, dy: inset)
    context.addPath(CGPath(
        roundedRect: bounds,
        cornerWidth: CGFloat(pixels) * 0.19,
        cornerHeight: CGFloat(pixels) * 0.19,
        transform: nil
    ))
    context.clip()
    context.interpolationQuality = .high
    context.draw(source, in: canvas)
    guard let image = context.makeImage() else { fail("could not render README preview") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { fail("could not open \(url.path)") }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let masterURL = root.appendingPathComponent("Resources/AppIcon-master.png")
let appIconSetURL = root.appendingPathComponent("packaging/Assets.xcassets/AppIcon.appiconset")
let previewURL = root.appendingPathComponent("docs/app-icon-v3.png")

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("could not read \(masterURL.path)") }

// The names are the ones Contents.json lists and the ones iconutil expects in
// an .iconset, which is what lets build.sh copy the folder's PNGs as they are.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    let url = appIconSetURL.appendingPathComponent("\(name).png")
    writePNG(render(master, pixels: pixels), to: url)
}
writePNG(renderPreview(master, pixels: 320), to: previewURL)

print("wrote \(appIconSetURL.path)")
print("wrote \(previewURL.path)")
