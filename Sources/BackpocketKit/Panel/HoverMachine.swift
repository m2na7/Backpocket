import Foundation
import SwiftData

/// Arbitration between the pointer and the keyboard for the one highlight the
/// panel shows.
///
/// Keystrokes re-lay the lists out under a stationary pointer, and the
/// tracking areas then re-fire entry for whatever row slid underneath — so
/// once the keyboard takes the highlight, hover entries are held rather than
/// honored. Judging "did the mouse move" from the entry events themselves is
/// defeated by trackpad jitter; only real hardware travel, which layout can
/// never synthesize, lifts the hold.
///
/// A value type with no SwiftUI and no store: these are the panel's trickiest
/// rules and the view they used to live in could not be tested at all.
struct HoverMachine: Equatable {
    /// Far enough to outrun trackpad palm jitter while typing.
    static let releaseDistance: CGFloat = 12

    /// The row under the pointer, or nil while the keyboard holds it.
    private(set) var hovered: PersistentIdentifier?
    /// Where the pointer sat when the keyboard took over.
    private(set) var anchor: NSPoint?
    /// An entry that arrived while the hold was on, replayed when it lifts:
    /// the pointer may already be resting on that row, in which case no
    /// further entry event would ever arrive.
    ///
    /// Carries the pane because the id alone stopped identifying a row: with
    /// links shown in both lists the same item is two rows, and a replay has
    /// to land on the one the pointer is actually over.
    private(set) var pending: Entry?

    /// A row, as the pointer names it: which item, in which list.
    struct Entry: Equatable {
        var id: PersistentIdentifier
        var pane: Pane
    }

    /// Whether pointer entries count right now.
    var accepts: Bool { anchor == nil }

    /// The keyboard took over: drop the highlight and start holding entries.
    /// A pending entry survives — the pointer has not moved, so whatever it
    /// was resting on is still under it.
    mutating func suppress(at point: NSPoint) {
        hovered = nil
        anchor = point
    }

    /// The lists changed under the pointer. The highlight and any pending
    /// entry named rows from a layout that no longer exists; the hold itself
    /// is a separate question and is left alone.
    mutating func dropHighlight() {
        hovered = nil
        pending = nil
    }

    /// Forgets the pointer entirely, hold included — for a panel being
    /// reopened somewhere the pointer has never been. The monitor that feeds
    /// this machine outlives a hide, so an anchor left from the previous
    /// session is trivially far from the new position and the first pointer
    /// move would replay a hover onto a row the pointer is nowhere near.
    mutating func reset() {
        hovered = nil
        anchor = nil
        pending = nil
    }

    /// A click is unambiguous mouse intent, even if the pointer never moved.
    mutating func release() {
        anchor = nil
    }

    /// A row reports the pointer entering it. Returns whether the entry was
    /// honored, so the caller can skip the focus and selection work it drives.
    @discardableResult
    mutating func enter(_ id: PersistentIdentifier, in pane: Pane) -> Bool {
        guard accepts else {
            pending = Entry(id: id, pane: pane)
            return false
        }
        pending = nil
        hovered = id
        return true
    }

    /// Only the row that still holds the highlight may clear it: exits and
    /// entries race when the pointer crosses between adjacent rows, and a
    /// blind clear would blink the row the pointer just arrived on.
    mutating func exit(_ id: PersistentIdentifier) {
        guard hovered == id else { return }
        hovered = nil
        pending = nil
    }

    /// Hardware pointer travel — the one legitimate lifter of the hold.
    /// Returns the entry to replay when it lifts, if one was held.
    mutating func pointerMoved(to point: NSPoint) -> Entry? {
        guard let anchor else { return nil }
        guard
            abs(point.x - anchor.x) > Self.releaseDistance
                || abs(point.y - anchor.y) > Self.releaseDistance
        else { return nil }

        self.anchor = nil
        return pending
    }
}
