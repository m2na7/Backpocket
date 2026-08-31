import SwiftUI

/// What the editor's buttons do, and in what order.
///
/// Three rules live here, all of them about a write that may be refused. The
/// store turns an edit down when the item is gone from under it — trimming,
/// expiry, or a delete elsewhere — or when it cannot write at all, and the
/// editor's job is to stay up with the user's text still in it rather than
/// close as if it had saved.
///
/// Split out of the composition root because they are rules and the root is
/// wiring: as three closures handed to `EditPanel.show` they could paste a
/// save that never landed, or blame the user's missing item for a broken
/// disk, and nothing would have failed.
struct EditorActions {
    /// Writes the text, and reports whether the write landed.
    let save: (String) -> Bool
    /// Puts the item on the pasteboard and into the frontmost app.
    let paste: () -> Void
    /// Whether the store is refusing every write, rather than this one item
    /// having gone missing.
    let hasStorageFailure: () -> Bool

    /// Save first; paste only what actually got written. Pasting a refused
    /// save would insert the old text while the editor claims the new text
    /// is stored.
    func saveAndPaste(_ text: String) -> Bool {
        guard save(text) else { return false }
        paste()
        return true
    }

    /// The same refusal has two causes and the editor cannot tell them apart,
    /// so the store is asked which one it was. Telling a user their note is
    /// gone when the disk is full sends them looking for the wrong thing.
    func failureMessage() -> LocalizedStringKey {
        hasStorageFailure() ? "edit.storageFailed" : "edit.gone"
    }
}
