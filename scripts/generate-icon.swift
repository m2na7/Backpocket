// Packages Resources/AppIcon-master.png into the macOS .icns roster and
// writes a compact README preview. Run from anywhere:
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
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")
let previewURL = root.appendingPathComponent("docs/app-icon.png")

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("could not read \(masterURL.path)") }

let fileManager = FileManager.default
let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("BackpocketIcon-\(UUID().uuidString)")
let iconsetURL = temporaryRoot.appendingPathComponent("AppIcon.iconset")

do {
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    fail("could not create temporary iconset: \(error.localizedDescription)")
}
defer { try? fileManager.removeItem(at: temporaryRoot) }

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    writePNG(render(master, pixels: pixels), to: iconsetURL.appendingPathComponent("\(name).png"))
}
writePNG(renderPreview(master, pixels: 320), to: previewURL)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]

do {
    try iconutil.run()
    iconutil.waitUntilExit()
} catch {
    fail("could not launch iconutil: \(error.localizedDescription)")
}
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited with status \(iconutil.terminationStatus)")
}

print("wrote \(icnsURL.path)")
print("wrote \(previewURL.path)")
