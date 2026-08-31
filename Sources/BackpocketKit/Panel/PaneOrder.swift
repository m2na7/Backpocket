/// Which panes are on screen, and where Tab goes next.
///
/// Both sections are optional — links only when the collect-links preference
/// asks for them, notes only when the notes column is on — so this is the one
/// place that knows what "the next pane" means. Focusing a pane the user
/// cannot see advertises actions against invisible rows, which is what makes
/// this worth stating once rather than at each caller.
enum PaneOrder {
    /// Tab order. Clips always exist: with both other sections off, the panel
    /// is a single list and Tab has nowhere else to go.
    static func visible(showsLinks: Bool, showsNotes: Bool) -> [Pane] {
        var panes: [Pane] = [.clips]
        if showsLinks { panes.append(.links) }
        if showsNotes { panes.append(.notes) }
        return panes
    }

    /// The next visible pane, wrapping around. A pane that is no longer
    /// visible — the preference was turned off while it held focus — falls
    /// back to clips rather than stranding the focus off screen.
    static func next(after pane: Pane, showsLinks: Bool, showsNotes: Bool) -> Pane {
        let panes = visible(showsLinks: showsLinks, showsNotes: showsNotes)
        guard let index = panes.firstIndex(of: pane) else { return .clips }
        return panes[(index + 1) % panes.count]
    }
}
