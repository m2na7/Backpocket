import Foundation

/// Which representation of a stored item leaves the app.
///
/// This is the narrowest and most consequential decision Backpocket makes.
/// Everything upstream exists to get it right: the watcher refuses to let a
/// copied piece of TEXT escalate into a file copy, `isFileCopy` is stored
/// rather than derived because `/Users/you/.ssh/id_rsa` reads identically
/// either way, and the migration refuses to guess the flag for rows written
/// before it existed. All of that converges here.
///
/// Kept as a value rather than as branches inside the app delegate so the
/// convergence point can be tested. Reordering the cases below, or letting a
/// regression make `fileURLs` non-empty for typed text, pastes a private key
/// where the user expected the text of its path — and nothing else in the app
/// would notice.
enum PasteFlavor: Equatable {
    case image(Data)
    case files([URL])
    case text(String, html: String?, rtf: Data?)

    /// Order is load-bearing, not stylistic.
    ///
    /// Images first: an image item's `content` is only a placeholder such as
    /// "Image 4×3", so any other branch winning would paste that string
    /// instead of the user's screenshot.
    ///
    /// Files second, and only through `fileURLs`, which re-checks the stored
    /// flag and the file's existence on every read — a stale flag never
    /// outlives the file it referred to.
    ///
    /// Text last, as the answer that is always safe to give.
    @MainActor
    static func flavor(for item: Item) -> PasteFlavor {
        if let imageData = item.imageData {
            return .image(imageData)
        }
        let files = item.fileURLs
        if !files.isEmpty {
            return .files(files)
        }
        return .text(item.content, html: item.contentHTML, rtf: item.contentRTF)
    }
}
