import AppKit
import Carbon.HIToolbox
import os

/// Puts text on the pasteboard and, when enabled, synthesizes Cmd+V into the
/// frontmost app. Automatic pasting requires Accessibility (TCC) trust.
enum Paster {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Whether this build may ask macOS for the Accessibility permission.
    ///
    /// The App Store build never asks. Guideline 2.4.5 reserves Accessibility
    /// for apps that exist to help people with disabilities, and pasting for
    /// you is not that — so the store copy leaves the decision entirely to the
    /// user, who turns automatic pasting on in Settings and adds the app in
    /// System Settings by hand. The direct download, which Apple does not
    /// review, keeps the prompt.
    static var mayPrompt: Bool {
        #if BACKPOCKET_MAS
        false
        #else
        true
        #endif
    }

    /// Asks macOS to prompt for Accessibility trust. Does nothing in the App
    /// Store build, which may not ask; callers read `isTrusted` for the answer.
    static func requestAccessibility() {
        guard mayPrompt else { return }
        // Spelled out rather than read from kAXTrustedCheckOptionPrompt: the
        // imported constant is a global var, which no context may read safely.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
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
        let item = NSPasteboardItem()
        item.setData(data, forType: isPNG ? .png : .tiff)
        // The other container is offered as a rendition so both PNG-only and
        // TIFF-only readers can paste. It is promised rather than written:
        // building it is a full decode and re-encode, on the main thread and
        // ahead of the ⌘V, and a TIFF holds the raw pixels (24 MB for a
        // Retina screenshot). Now only a reader that asks for it pays that.
        let rendition = ImageRendition(of: data)
        item.setDataProvider(rendition, forTypes: [isPNG ? .tiff : .png])
        pendingRendition.withLock { $0 = rendition }
        // Still one change, made by clearContents: the one
        // ClipboardWatcher.suppressingOwnWrite skips. Keeping the promise
        // later, whenever a reader asks, does not make another.
        pasteboard.writeObjects([item])
    }

    /// The rendition the last image write promised. AppKit keeps a data
    /// provider alive until it is finished with it, in practice, but nothing
    /// documents that, and one freed early would leave the promised flavor
    /// empty for whoever pastes it. Replaced by the next image write, and
    /// dropped as soon as AppKit reports it is finished. Behind a lock
    /// because Paster belongs to no actor, and AppKit calls the provider back
    /// on whichever thread the read came from.
    fileprivate static let pendingRendition = OSAllocatedUnfairLock<ImageRendition?>(
        initialState: nil)

    #if DEBUG
    /// Whether a promised rendition is still held, so the tests can see it
    /// released once AppKit is done with it rather than kept for good.
    /// Debug-only because nothing in a shipping build has a use for it.
    static var holdsRenditionForTesting: Bool {
        pendingRendition.withLock { $0 != nil }
    }
    #endif

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

/// Builds the image container a clip was not stored in, once a reader asks
/// for it. See `Paster.writeImage`.
private final class ImageRendition: NSObject, NSPasteboardItemDataProvider, Sendable {
    /// The clip's own bytes, in the container they were stored in.
    private let source: Data

    init(of source: Data) {
        self.source = source
    }

    /// Runs on the thread the read came from: the main thread when another
    /// app pastes, since AppKit serves those requests from the main run loop.
    /// On a normal quit AppKit calls it for any promise still open, so the
    /// flavor outlives the app as it did when it was written up front.
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let rep = NSBitmapImageRep(data: source) else { return }
        let rendition: Data? =
            switch type {
            case .png: rep.representation(using: .png, properties: [:])
            case .tiff: rep.tiffRepresentation
            default: nil
            }
        if let rendition {
            item.setData(rendition, forType: type)
        }
    }

    /// Called once the promise is kept, or once the pasteboard has moved on
    /// to someone else's copy. Only this rendition is dropped: a later write
    /// may already have replaced it.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Paster.pendingRendition.withLock { pending in
            if pending === self {
                pending = nil
            }
        }
    }
}
