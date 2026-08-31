import AppKit
import Carbon.HIToolbox

/// Puts text on the pasteboard and, when enabled, synthesizes Cmd+V into the
/// frontmost app. Automatic pasting requires Accessibility (TCC) trust.
enum Paster {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        // Spelled out rather than read from kAXTrustedCheckOptionPrompt: the
        // imported constant is a global var, which no context may read safely.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Call only after the panel has closed and the previous app is active
    /// again. With automatic pasting off, this just sets the clipboard — no
    /// Accessibility permission needed.
    static func paste(_ text: String, html: String? = nil, rtf: Data? = nil) {
        write(text, html: html, rtf: rtf, to: .general)
        sendCommandVIfAutomatic()
    }

    /// Split from `paste` for the reason `writeImage` was: a test routed
    /// through `paste` would post a synthetic Cmd+V into whatever window is
    /// frontmost, so the flavor rules could not be checked at all.
    static func write(_ text: String, html: String?, rtf: Data?, to pasteboard: NSPasteboard) {
        // clearContents is what retires the previous item's flavors. Without
        // it a file URL written a moment ago would still be on the pasteboard
        // and a receiver would attach a file the user did not paste.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Restoring the rich flavors keeps rich copies rich when pasted back.
        if let html {
            pasteboard.setString(html, forType: .html)
        }
        if let rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Same contract as `paste(_:html:rtf:)`, for image clips.
    static func pasteImage(_ data: Data) {
        writeImage(data, to: .general)
        sendCommandVIfAutomatic()
    }

    /// Split from pasteImage so the flavor rules can be tested: routing a
    /// test through pasteImage would post a synthetic ⌘V into whatever window
    /// is frontmost.
    static func writeImage(_ data: Data, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        // The stored bytes keep whatever container they arrived in; labeling
        // TIFF bytes as public.png feeds strict PNG consumers a corrupt file.
        let isPNG = data.starts(with: pngSignature)
        pasteboard.setData(data, forType: isPNG ? .png : .tiff)
        // The other container is offered as a rendition so both PNG-only and
        // TIFF-only readers can paste.
        if let rep = NSBitmapImageRep(data: data) {
            if isPNG, let tiff = rep.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            } else if !isPNG, let png = rep.representation(using: .png, properties: [:]) {
                pasteboard.setData(png, forType: .png)
            }
        }
    }

    /// Same contract again, for file copies. Writing the URLs as objects
    /// reproduces a Finder copy: the receiver attaches or copies the file
    /// itself, and apps that only take text still get the paths.
    static func pasteFiles(_ urls: [URL]) {
        writeFiles(urls, to: .general)
        sendCommandVIfAutomatic()
    }

    /// Split from `pasteFiles` for the same reason as `write`.
    static func writeFiles(_ urls: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    private static func sendCommandVIfAutomatic() {
        guard PasteBehavior.isAutomatic else { return }

        // The previous app needs a beat to become active again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCommandV()
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
