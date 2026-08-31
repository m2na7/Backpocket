// Sandbox feasibility probe. Not part of the app; built and run by
// scripts/sandbox-probe.sh to find out which of Backpocket's capabilities
// actually survive the App Sandbox. Prints one PASS/FAIL line per capability.
//
// It deliberately calls the SAME APIs the app calls, so a result here is
// evidence about the app, not about a toy.

import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement

// --out=<path> redirects stdout, so the probe can be launched with `open` —
// a terminal-launched process inherits the terminal's TCC standing, which
// would make the accessibility answer meaningless.
if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--out=") }) {
    freopen(String(arg.dropFirst("--out=".count)), "w", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
}

func report(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")\t\(name)\t\(detail)")
}

// Where does this sandboxed process think Application Support is?
let appSupport = URL.applicationSupportDirectory.path
print("INFO\tapplicationSupportDirectory\t\(appSupport)")
print("INFO\thomeDirectory\t\(NSHomeDirectory())")

// --- (b) Carbon global hotkey -------------------------------------------
var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: 0x42_4B_50_54, id: 1)
let hotKeyStatus = RegisterEventHotKey(
    UInt32(kVK_ANSI_B),
    UInt32(cmdKey | shiftKey | optionKey | controlKey),
    hotKeyID,
    GetApplicationEventTarget(),
    0,
    &hotKeyRef
)
report(
    "carbon-hotkey", hotKeyStatus == noErr,
    "RegisterEventHotKey status=\(hotKeyStatus) ref=\(hotKeyRef == nil ? "nil" : "non-nil")")
if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }

// --- (c) Pasteboard read -------------------------------------------------
let pb = NSPasteboard.general
print("INFO\tpasteboard-changeCount\t\(pb.changeCount)")
let types = pb.types?.map(\.rawValue).joined(separator: ",") ?? "<nil>"
report("pasteboard-types", pb.types != nil, "types=[\(types)]")

let str = pb.string(forType: .string)
report(
    "pasteboard-string", str != nil,
    str.map { "read \($0.utf8.count) bytes" } ?? "string(forType:.string) returned nil")

// Image flavors, exactly as ClipboardWatcher asks for them.
let png = pb.data(forType: .png)
let tiff = pb.data(forType: .tiff)
print(
    "INFO\tpasteboard-image\tpng=\(png?.count.description ?? "nil") tiff=\(tiff?.count.description ?? "nil")"
)

// File-URL flavor, the type ClipboardWatcher keys the file-copy path on.
let hasFileURLType = pb.types?.contains(.fileURL) ?? false
print("INFO\tpasteboard-fileURL-type-present\t\(hasFileURLType)")
if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
    print("INFO\tpasteboard-fileURLs\t\(urls.map(\.path).joined(separator: "|"))")
} else {
    print("INFO\tpasteboard-fileURLs\t<none>")
}

// --- (d) Reading a file the user copied in Finder ------------------------
// Item.fileURLs gates every path on FileManager.fileExists, then the receiving
// app must actually read the bytes. Probe both against a path handed in.
if CommandLine.arguments.count > 1 {
    let probePath = CommandLine.arguments[1]
    let exists = FileManager.default.fileExists(atPath: probePath)
    report("file-exists-outside-container", exists, "fileExists(\(probePath)) = \(exists)")
    let readable = FileManager.default.isReadableFile(atPath: probePath)
    report("file-readable-outside-container", readable, "isReadableFile = \(readable)")
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: probePath))
        report("file-read-outside-container", true, "read \(data.count) bytes")
    } catch {
        report("file-read-outside-container", false, "\(error)")
    }
}

// --- (d2) Security-scoped bookmarks --------------------------------------
// The proposed fix for file copies: mint a bookmark while the pasteboard
// extension is still live, resolve it in a later launch. Both halves are
// probed as separate processes so "later launch" is real, not simulated.
let bookmarkStore = URL(fileURLWithPath: NSHomeDirectory())
    .appending(path: "bookmark.data")

if CommandLine.arguments.contains("--make-bookmark") {
    // Take the URL from the pasteboard, exactly as the app would at capture.
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
        let url = urls.first
    {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            try data.write(to: bookmarkStore)
            report(
                "bookmark-create", true,
                "\(data.count) bytes for \(url.path) -> \(bookmarkStore.path)")
        } catch {
            report("bookmark-create", false, "\(error)")
        }
    } else {
        report("bookmark-create", false, "no file URL on the pasteboard")
    }
}

if CommandLine.arguments.contains("--resolve-bookmark") {
    do {
        let data = try Data(contentsOf: bookmarkStore)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try Data(contentsOf: url)
            report(
                "bookmark-resolve-read", true,
                "resolved \(url.path), stale=\(stale), startAccessing=\(started), read \(bytes.count) bytes"
            )
        } catch {
            report(
                "bookmark-resolve-read", false,
                "resolved \(url.path), stale=\(stale), startAccessing=\(started), read failed: \(error)"
            )
        }
    } catch {
        report("bookmark-resolve-read", false, "\(error)")
    }
}

// The other half of the round trip: a sandboxed app whose only access to the
// file is a bookmark writes the URL back to the pasteboard. Whether the
// RECEIVING app can then read the bytes is what "paste a file" means.
if CommandLine.arguments.contains("--write-from-bookmark") {
    do {
        let data = try Data(contentsOf: bookmarkStore)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        pb.clearContents()
        let wrote = pb.writeObjects([url as NSURL])
        pb.setString(url.path, forType: .string)
        report(
            "pasteboard-write-from-bookmark", wrote,
            "wrote \(url.path) startAccessing=\(started) changeCount=\(pb.changeCount)")
        // Access is held open deliberately: released immediately, the write
        // would be indistinguishable from writing a path with no access.
    } catch {
        report("pasteboard-write-from-bookmark", false, "\(error)")
    }
}

// What Backpocket does TODAY: rebuild a URL from a stored path string and
// write it, holding no access to the file at all. Paster.pasteFiles verbatim.
if let i = CommandLine.arguments.firstIndex(of: "--write-stored-path"),
    i + 1 < CommandLine.arguments.count
{
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    pb.clearContents()
    let wrote = pb.writeObjects([url as NSURL])
    pb.setString(url.path, forType: .string)
    report(
        "pasteboard-write-stored-path", wrote,
        "wrote \(url.path) with no access held, changeCount=\(pb.changeCount)")
}

// Reads whatever file URL is on the pasteboard and tries the bytes — this is
// what a sandboxed RECEIVING app does after ⌘V.
if CommandLine.arguments.contains("--read-pasteboard-file") {
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
        let url = urls.first
    {
        do {
            let bytes = try Data(contentsOf: url)
            report("receiver-reads-pasted-file", true, "read \(bytes.count) bytes from \(url.path)")
        } catch {
            report("receiver-reads-pasted-file", false, "\(url.path): \(error)")
        }
    } else {
        report("receiver-reads-pasted-file", false, "no file URL on the pasteboard")
    }
}

// --- (e) Accessibility trust (auto-paste) --------------------------------
// Only the trust check — never the prompt, which needs a human.
report(
    "accessibility-trust", AXIsProcessTrusted(),
    "AXIsProcessTrusted() = \(AXIsProcessTrusted()) (grant is per-signature; this probe was never granted)"
)

// CGEvent creation is the other half; posting is what TCC gates.
let source = CGEventSource(stateID: .combinedSessionState)
let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
report(
    "cgevent-create", down != nil,
    "CGEventSource=\(source == nil ? "nil" : "ok") CGEvent=\(down == nil ? "nil" : "ok")")

// --- (f) Login item ------------------------------------------------------
let status = SMAppService.mainApp.status
print("INFO\tSMAppService.mainApp.status\t\(status.rawValue) (\(status))")
if CommandLine.arguments.contains("--try-login-item") {
    do {
        try SMAppService.mainApp.register()
        let after = SMAppService.mainApp.status
        report("login-item-register", after == .enabled, "status after register = \(after)")
        try? SMAppService.mainApp.unregister()
        print("INFO\tlogin-item-after-unregister\t\(SMAppService.mainApp.status)")
    } catch {
        report("login-item-register", false, "\(error)")
    }
}

// --- (g) Network client --------------------------------------------------
if CommandLine.arguments.contains("--try-network") {
    let semaphore = DispatchSemaphore(value: 0)
    // One benign host, HTTPS, HEAD-shaped GET — same shape as Favicons.
    var request = URLRequest(url: URL(string: "https://example.com/favicon.ico")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
        if let error {
            report("network-client", false, "\(error)")
        } else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            report("network-client", true, "HTTP \(code), \(data?.count ?? 0) bytes")
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
}

print("INFO\tdone")
