/// The panel's focus targets: clipboard history, notes, and — when the
/// collect-links preference is on — the links section below the clips.
enum Pane {
    case clips
    case links
    case notes
}

/// What pressing ↩ does.
///
/// The two panes are kept symmetric — ↩ performs the pane's native action,
/// ⌘↩ performs the inverse. Clips exist to be used, so ↩ pastes; notes exist
/// to be revised, so ↩ edits.
enum EnterAction: Equatable {
    case saveNote
    case paste
    case edit
    case none

    static func resolve(
        command: Bool,
        pane: Pane,
        hasText: Bool,
        hasMatches: Bool,
        hasSelection: Bool
    ) -> EnterAction {
        // A new sentence that matches no search result becomes a new note,
        // in either pane.
        if hasText, !hasMatches {
            return .saveNote
        }

        switch pane {
        // A link is a clip, so the links section keeps clip semantics.
        case .clips, .links:
            if command {
                // Only what was typed. Converting the selected clip lived here
                // too and was dropped: dragging it onto the notes column says
                // the same thing and is the gesture people reach for.
                return hasText ? .saveNote : .none
            }
            return hasSelection ? .paste : .none

        case .notes:
            if command {
                return hasSelection ? .paste : .none
            }
            return hasSelection ? .edit : .none
        }
    }
}
