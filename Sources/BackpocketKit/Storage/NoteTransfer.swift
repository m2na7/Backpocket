import AppKit
import UniformTypeIdentifiers

/// The file panels and transfer operations shared by Settings and the
/// sandbox integration probe. Tests must exercise the same permission path.
@MainActor
enum NoteTransfer {
    static func exportNotes(from store: Store, initialDirectory: URL? = nil) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Backpocket-notes.json"
        panel.canCreateDirectories = true
        if let initialDirectory { panel.directoryURL = initialDirectory }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = try NoteExport(items: store.items).encoded()
        try data.write(to: url, options: .atomic)
        return true
    }

    static func importNotes(
        into store: Store, initialDirectory: URL? = nil
    ) async throws
        -> NoteImportResult?
    {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let initialDirectory { panel.directoryURL = initialDirectory }
        // A sheet keeps the picker attached to Settings and leaves the
        // main actor available while the user chooses a file.
        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let archive = try await Task.detached(priority: .userInitiated) {
            try NoteExport.read(from: url)
        }.value
        return try store.importNotes(archive)
    }
}
