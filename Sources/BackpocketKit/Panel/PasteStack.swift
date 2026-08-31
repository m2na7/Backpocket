import Foundation
import SwiftData

/// Clips collected with ⌘D (or ⌘-click), in pick order; releasing ⌘ pastes them
/// joined by newlines. Ordered, so an Array — not a Set.
///
/// Whether the handful would insert anything is tracked as it is built rather
/// than asked at render time: the footer chip needs it on every pass, and
/// resolving each id against the store there was O(stack × items) inside a
/// view body.
struct PasteStack: Equatable {
    private(set) var ids: [PersistentIdentifier] = []
    /// The picks that are not images. An all-image handful has nothing to
    /// join, so plain Enter must not advertise a paste it cannot perform.
    private var textIDs: Set<PersistentIdentifier> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    var hasText: Bool { !textIDs.isEmpty }

    /// The badge a row shows, or nil when it is not in the handful.
    func number(of id: PersistentIdentifier) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    mutating func toggle(_ id: PersistentIdentifier, isText: Bool) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            textIDs.remove(id)
        } else {
            ids.append(id)
            if isText { textIDs.insert(id) }
        }
    }

    mutating func clear() {
        ids = []
        textIDs = []
    }

    /// Rows deleted elsewhere (row actions, expiry) must not leave gaps in the
    /// badge numbering. Runs on every store mutation and every keystroke, so
    /// it costs nothing when nothing is collected — which is the usual case.
    mutating func prune(keeping isLive: (PersistentIdentifier) -> Bool) {
        guard !ids.isEmpty else { return }
        ids.removeAll { !isLive($0) }
        textIDs.formIntersection(ids)
    }

    /// What one Enter on a collected handful inserts, and which picks that
    /// counts as using — nil when there is nothing to insert at all.
    ///
    /// Images ride the stack so a handful can be deleted in one go, but their
    /// content is a derived placeholder, so pasting joins only the text picks.
    /// An all-image handful therefore has nothing to paste, and must not
    /// promote its picks or dismiss the panel on the way to doing nothing.
    ///
    /// Here rather than in the app delegate because it is the rule, not the
    /// wiring: the delegate's copy could join image placeholders or paste an
    /// empty string and no test would have noticed.
    static func insertion(for items: [Item]) -> (used: [Item], text: String)? {
        let pasteable = items.filter { !$0.isImage }
        guard !pasteable.isEmpty else { return nil }
        // Plain text only, in pick order: rich flavors cannot merge across
        // items.
        return (pasteable, pasteable.map(\.content).joined(separator: "\n"))
    }

    #if DEBUG
    /// Stages a handful for a screenshot: the shell cannot ⌘-click rows in a
    /// non-activating panel. Callers pass only non-image clips.
    mutating func seed(text ids: [PersistentIdentifier]) {
        self.ids = ids
        textIDs = Set(ids)
    }
    #endif
}
