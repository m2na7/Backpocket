import AppKit
import SwiftData
import SwiftUI

// MARK: - Notes rows

/// A display bucket of the notes list; rows carry their preformatted time
/// label so the row body never touches a DateFormatter.
struct NoteSection: Identifiable, Equatable {
    let group: NoteGroup
    var rows: [NoteRowData]

    var id: String { group.id }
}

struct NoteRowData: Equatable {
    let item: Item
    let timeLabel: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item === rhs.item && lhs.timeLabel == rhs.timeLabel
    }
}

/// One notes row, Equatable-gated like ItemRow.
struct NoteRow: View, @MainActor Equatable {
    let item: Item
    /// The change stamp — edits bump usedAt, so content changes compare
    /// unequal without comparing the content.
    let usedAt: Date
    /// Its own stamp: pinning deliberately leaves usedAt alone, and reading
    /// the flag off the shared item would compare a value against itself.
    let isPinned: Bool
    let timeLabel: String
    let shortcut: Int?
    /// 1-based position in the paste stack, nil when not collected.
    let stackNumber: Int?
    /// A stack is being collected somewhere — the trailing column shows pick
    /// numbers instead of timestamps until it is pasted or dropped.
    let stacking: Bool
    let query: String
    let highlighted: Bool
    /// The pointer is on this row — gates the inline row actions. Parent-
    /// owned like the highlight, for the same reason.
    let pointerHovering: Bool

    let onHover: () -> Void
    let onExit: () -> Void
    let onActivate: () -> Void
    let onToggleStack: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item === rhs.item
            && lhs.usedAt == rhs.usedAt
            && lhs.isPinned == rhs.isPinned
            && lhs.timeLabel == rhs.timeLabel
            && lhs.shortcut == rhs.shortcut
            && lhs.stackNumber == rhs.stackNumber
            && lhs.stacking == rhs.stacking
            && lhs.query == rhs.query
            && lhs.highlighted == rhs.highlighted
            && lhs.pointerHovering == rhs.pointerHovering
    }

    var body: some View {
        HStack(spacing: 9) {
            if let shortcut {
                ShortcutChip(label: "\(shortcut)")
            }

            // One uniform line — reading in full is the hover card's job,
            // and a notes column needs no per-row "this is a note" glyph.
            preview
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // The trailing slot, in priority order: the pick number while a
            // handful is being collected (collecting is a mode — row actions
            // must not sit under the pointer that is ⌘-clicking), then row
            // actions on hover, then the timestamp.
            if let stackNumber {
                StackBadge(number: stackNumber)
            } else if stacking {
                EmptyView()
            } else if pointerHovering {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("ctx.edit")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("ctx.delete")
                }
            } else {
                Text(timeLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .animation(nil, value: highlighted)
        .contentShape(Rectangle())
        .draggable(item.content)
        .contextMenu {
            Button("ctx.paste", action: onActivate)
            Button("ctx.edit", action: onEdit)
            // ⌘-click and ⌘D already collect notes; the menu is the mouse
            // mirror of the shortcuts and had drifted out of sync.
            Button(stackNumber == nil ? "ctx.stackAdd" : "ctx.stackRemove", action: onToggleStack)
            Button(isPinned ? "ctx.unstar" : "ctx.star", action: onTogglePin)
            Divider()
            Button("ctx.delete", role: .destructive, action: onDelete)
        }
        // Exit reported like ItemRow's, for the same reason.
        .onHover { inside in
            if inside {
                onHover()
            } else {
                onExit()
            }
        }
        .onTapGesture {
            // A plain click opens the editor — the mouse mirror of a note's
            // native ↩ action; ⌘-click collects for the stack, the same
            // gesture as every other list.
            if clickHasCommand() {
                onToggleStack()
            } else {
                onEdit()
            }
        }
        .modifier(
            RowSpeech(
                voice: voice,
                selected: highlighted,
                hint: "a11y.hint.edit",
                activate: onEdit
            )
        )
        // Edit and delete are drawn only under the pointer, so without these
        // two the notes column would offer a screen reader no way to reach
        // either one. Paste is here because ⌘↩ is a note's non-native action
        // and nothing on the row shows it.
        .accessibilityActions {
            Button("ctx.paste", action: onActivate)
            Button("ctx.edit", action: onEdit)
            Button(stackNumber == nil ? "ctx.stackAdd" : "ctx.stackRemove", action: onToggleStack)
            Button(isPinned ? "ctx.unstar" : "ctx.star", action: onTogglePin)
            Button("ctx.delete", action: onDelete)
        }
    }

    private var preview: Text {
        emphasized(item.preview, matching: query)
    }

    private var voice: RowVoice {
        RowVoice(note: item, isPinned: isPinned, stackNumber: stackNumber)
    }
}
