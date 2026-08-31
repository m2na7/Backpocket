import AppKit

/// The monochrome counterpart of the full-color Backpocket app icon.
enum MenuBarIcon {
    static let image: NSImage = {
        let bundled = Bundle.main.url(
            forResource: "MenuBarIconTemplate@2x",
            withExtension: "png"
        )
        .flatMap(NSImage.init(contentsOf:))

        let image =
            bundled
            ?? NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Backpocket")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Backpocket"
        return image
    }()
}
