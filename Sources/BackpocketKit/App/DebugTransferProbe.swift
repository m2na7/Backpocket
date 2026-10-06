#if DEBUG
import AppKit
import Foundation
import SwiftData

/// A real app process with the production transfer panels and storage code.
/// The runner gives the bundles separate identities; every run uses a UUID
/// beneath a dedicated probe directory, never the user's Backpocket store.
@MainActor
enum DebugTransferProbe {
    static func run(stage: String) async {
        guard let run = DebugLaunch.transferRun, UUID(uuidString: run) != nil else {
            NSApp.terminate(nil)
            return
        }
        let directory = URL.applicationSupportDirectory
            .appending(path: "BackpocketTransferProbe/\(run)", directoryHint: .isDirectory)
        var report: [String: Any] = [
            "stage": stage,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "home": NSHomeDirectory(),
            "hasUpdater": Updater.isAvailable,
        ]
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(
                for: Item.self,
                configurations: ModelConfiguration(url: directory.appending(path: "Probe.store")))
            let context = ModelContext(container)
            let store = Store(context: context, disposableLimit: { 0 })
            if stage == "export", store.items.isEmpty {
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                let longNote =
                    "한글 메모\n😀 \"quoted\"\n"
                    + String(repeating: "긴", count: 200_100) + "\nEND-OF-LONG-NOTE"
                for text in [longNote, "identical", "identical"] {
                    let note = Item(content: text, isNote: true)
                    note.createdAt = date
                    note.usedAt = date.addingTimeInterval(60)
                    note.isPinned = text != "identical"
                    context.insert(note)
                }
                context.insert(Item(content: "clipboard-only"))
                try context.save()
                store.reload()
            }
            if stage == "import", store.items.isEmpty {
                store.addNote("already in the App Store version")
            }
            // Checking the actual read, before a file panel grants access,
            // catches a probe accidentally running without a sandbox.
            if stage == "import", let path = DebugLaunch.transferFile {
                do {
                    _ = try Data(contentsOf: URL(fileURLWithPath: path))
                    report["externalReadDenied"] = false
                } catch {
                    let failure = error as NSError
                    report["externalReadDenied"] =
                        failure.domain == NSCocoaErrorDomain
                        && failure.code == CocoaError.fileReadNoPermission.rawValue
                    report["externalReadError"] = failure.code
                }
            }
            NSApp.setActivationPolicy(.regular)
            // A normal host window mirrors Settings. A menu-bar process
            // with only the Powerbox panel has no stable AX focus owner.
            let host = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 420, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            host.title = "Backpocket transfer integration"
            host.isReleasedWhenClosed = false
            host.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { host.close() }
            let initialDirectory = DebugLaunch.transferFile.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
            }
            switch stage {
            case "export", "export-sandbox":
                report["exported"] = try NoteTransfer.exportNotes(
                    from: store, initialDirectory: initialDirectory)
            case "import", "repeat", "invalid", "cancel":
                do {
                    if let result = try await NoteTransfer.importNotes(
                        into: store, initialDirectory: initialDirectory)
                    {
                        report["imported"] = result.imported
                        report["skipped"] = result.skipped
                    } else {
                        report["cancelled"] = true
                    }
                } catch NoteTransferError.invalidFile {
                    report["invalidFileRejected"] = true
                }
            case "reopen", "source-reopen": break
            default: throw CocoaError(.validationMissingMandatoryProperty)
            }
            // Refetch from a new context so the report cannot confuse the
            // view's published values with data that actually reached disk.
            let saved = try ModelContext(container).fetch(FetchDescriptor<Item>())
            report["snapshot"] = try JSONSerialization.jsonObject(
                with: NoteExport(items: saved, exportedAt: Date(timeIntervalSince1970: 0)).encoded()
            )
            report["itemCount"] = saved.count
            report["ok"] = true
        } catch {
            report["ok"] = false
            report["error"] = String(describing: error)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: directory.appending(path: "\(stage).json"), options: .atomic)
        } catch {
            // The runner times out and fails if a report cannot be written.
            FileHandle.standardError.write(Data("probe report failed: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }
}
#endif
