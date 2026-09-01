/// A key press reduced to the things the panel actually decides on.
///
/// `shortcut` arrives already matched rather than as a key name: resolving a
/// rebindable shortcut has to consult the live NSEvent for the physical key,
/// because under a Korean layout ⌘O arrives as "ㅐ". That lookup is the one
/// part of dispatch that cannot be pure, so it happens at the edge and its
/// answer is handed in here.
struct PanelKeyPress: Equatable {
    /// The keys the panel gives its own meaning. Everything else — the
    /// letters the user is typing into the field — is a `character`.
    enum Key: Equatable {
        case upArrow
        case downArrow
        case tab
        case escape
        case `return`
        case character(Character)
    }

    var key: Key
    /// The key is being held down. Only the arrows may fire again: a repeated
    /// ↩ or ⌘E would run the same action several times off one press.
    var isRepeat: Bool
    var command: Bool
    var shift: Bool
    var shortcut: PanelShortcut?
}

/// Everything the panel's state needs to say before a key means anything.
///
/// Deliberately flat scalars rather than the store, the lists and the
/// selection: the whole point is that the decision below can be exercised for
/// every key and modifier combination without a view, a container or a mouse.
struct PanelKeyContext: Equatable {
    var pane: Pane = .clips
    /// The field holds something other than whitespace.
    var hasQuery = false
    /// The focused pane's history has results. Clips and links count as one
    /// history: see `ContentView.hasMatches`.
    var hasMatches = false
    var hasSelection = false
    /// The notes column is on screen. With it hidden there is nowhere for a
    /// note to land.
    var showsNotes = true
    var stackIsEmpty = true
    /// Whether `Store` is still holding a delete that ⌘Z could put
    /// back. The panel claims that key only while this is true.
    var canUndoDelete = false
    /// Whether the delete shortcut is still bound to ⌘⌫, which is also how
    /// a text field clears the line it is on. Rebound to anything else, the
    /// collision below disappears and the row is always the target.
    var deleteIsCommandBackspace = true
}

/// What a key press does to the panel.
///
/// One case per outcome, so the dispatcher can be read as a table. Cases the
/// view has to resolve against the store — which row `openLink` opens, which
/// row `togglePin` pins — carry no payload: the row an action aims at is
/// `PanelTargeting`'s question, not this one's.
enum PanelCommand: Equatable {
    case move(Int)
    case switchPane
    case focusClips
    case close
    case openSettings
    case clearStack
    case pasteStack
    case deleteStack
    case toggleStack
    case pasteSelection
    case pasteSlot(Int)
    case deleteSelection
    /// Puts back what the last ⌘⌫ took, while `Store` still has it.
    case undoDelete
    case saveNote
    case edit
    case togglePin
    case openLink
    /// The panel owns this key but has nothing to do with it. Distinct from
    /// `unhandled`: swallowing ⌘↩ with an empty panel is correct, letting the
    /// text field see it is not.
    case consumed
    /// Not the panel's key — the text field gets it.
    case unhandled
}

/// The panel's keyboard, as a decision table.
///
/// This used to be seventy lines inside `ContentView.handle`, where the
/// combination that goes wrong — ⌘1 after a filter, ⌫ picking the next
/// selection, ⇥ into a pane the preferences turned off — could not be
/// exercised at all. `EnterAction` is the precedent; this composes it rather
/// than absorbing it, because what ↩ resolves to is a question the footer
/// hints ask too, and only the dispatcher cares about the rest of the keys.
enum PanelKeyboard {
    static func command(for press: PanelKeyPress, in context: PanelKeyContext) -> PanelCommand {
        // Ahead of the repeat guard: holding an arrow is how the list is meant
        // to be walked.
        switch press.key {
        case .upArrow: return .move(-1)
        case .downArrow: return .move(1)
        default: break
        }
        guard !press.isRepeat else { return .unhandled }

        switch press.key {
        case .tab:
            return .switchPane

        case .escape:
            // Escape peels one layer at a time: the collected handful first,
            // then back out to the clips pane, and only then closes.
            if !context.stackIsEmpty { return .clearStack }
            return context.pane == .clips ? .close : .focusClips

        case .return:
            // Shift-Return is not intercepted — the field inserts a newline.
            if press.shift { return .unhandled }
            return returnCommand(command: press.command, in: context)

        default:
            break
        }

        // Ahead of ⌘1–9 and ⌘, — those are reserved against rebinding
        // (`PanelShortcut.isReserved`), so the order cannot actually shadow
        // anything, but a shortcut carrying an extra modifier still gets
        // first refusal.
        if let shortcut = press.shortcut {
            switch shortcut {
            case .edit: return .edit
            case .pin: return .togglePin
            case .delete:
                // A collected handful is a transient mode and owns the key
                // while it exists.
                guard context.stackIsEmpty else { return .deleteStack }
                // Otherwise ⌘⌫ is the field's: it is how macOS clears the
                // line you are typing on, this field is always focused, and
                // Escape closes the panel rather than emptying it — so
                // claiming the key leaves a typed query with no way out but
                // holding backspace, and destroys a clip on the way.
                if context.hasQuery, context.deleteIsCommandBackspace {
                    return .unhandled
                }
                return .deleteSelection
            case .stack: return .toggleStack
            case .openLink: return .openLink
            }
        }

        if press.command, case .character(let character) = press.key {
            // Slots are positions in the focused pane, so they follow the
            // filter: ⌘1 pastes the first row the user can see, not the first
            // row of the unfiltered history.
            if let slot = character.wholeNumberValue, (1...9).contains(slot) {
                return .pasteSlot(slot - 1)
            }
            if character == "," { return .openSettings }
            // ⌘Z stays the text field's key except in the one moment it
            // has nothing to answer with: the field is empty and a
            // delete is still restorable. An empty field is not enough
            // on its own — clearing what you typed leaves it empty too,
            // and that undo belongs to the field.
            if character == "z", !context.hasQuery, context.canUndoDelete {
                return .undoDelete
            }
        }

        return .unhandled
    }

    /// What ↩ (or ⌘↩) resolves to right now.
    ///
    /// The footer hints call this too, so a chip cannot promise an action the
    /// key will not perform. With the notes column hidden there is nowhere
    /// for a note to land, so saving one is off rather than silent.
    static func resolvedAction(command: Bool, in context: PanelKeyContext) -> EnterAction {
        let action = EnterAction.resolve(
            command: command,
            pane: context.pane,
            hasText: context.hasQuery,
            hasMatches: context.hasMatches,
            hasSelection: context.hasSelection
        )
        return action == .saveNote && !context.showsNotes ? .none : action
    }

    private static func returnCommand(command: Bool, in context: PanelKeyContext)
        -> PanelCommand
    {
        // A collected handful owns plain ↩ — the footer chip advertises it,
        // and both read the same emptiness check so the promise stays honest.
        if !command, !context.stackIsEmpty { return .pasteStack }

        switch resolvedAction(command: command, in: context) {
        case .saveNote: return .saveNote
        case .paste: return .pasteSelection
        case .edit: return .edit
        case .none: return .consumed
        }
    }
}
