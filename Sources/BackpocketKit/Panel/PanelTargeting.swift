/// Which row an action aims at, and which row may grow a preview card.
///
/// Two rules that read as one-liners and are not: both used to sit in
/// `ContentView` as computed properties, and both have been the cause of an
/// action landing on the wrong row. Generic over the row so they can be
/// stated without a store — the caller has already resolved the ids it holds
/// into whatever it wants back.
enum PanelTargeting {
    /// The row the user SEES highlighted wins: a hovered row lights up in any
    /// pane, so ⌘⌫, ⌘D and open must hit exactly that one — not the focused
    /// pane's remembered selection sitting behind the pointer.
    static func actionTarget<Row>(hovered: Row?, selected: Row?) -> Row? {
        hovered ?? selected
    }

    /// The hovered row wins; otherwise the keyboard selection, but only one
    /// the user actually navigated to. A selection that merely followed
    /// typing, or the panel opening, is automatic — and an automatic
    /// selection must never grow a preview card over a list the user is still
    /// reading.
    static func dwellTarget<Row>(
        hovered: Row?,
        selected: Row?,
        selectionIsAutomatic: Bool
    ) -> Row? {
        if let hovered { return hovered }
        return selectionIsAutomatic ? nil : selected
    }
}
