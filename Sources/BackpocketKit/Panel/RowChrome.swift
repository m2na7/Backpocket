import AppKit
import SwiftUI

/// The click's OWN modifier state. The class-level NSEvent flags read the
/// keyboard as of right now — a ⌘ released between mouse-up and gesture
/// delivery (the tail click of a rapid multi-select) would read as a plain
/// click, which on a note opens the editor mid-collection.
@MainActor
func clickHasCommand() -> Bool {
    (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
}

/// The pick number a row wears while a handful is being collected.
struct StackBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Color.accentColor))
    }
}

/// The ⌘-slot chip that takes the row icon's place while Command is held.
/// Sizes to its label so the links section's "⇧3" fits the same shape.
struct ShortcutChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(minWidth: 17, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.primary.opacity(0.06)))
    }
}

/// While searching, only the matched part goes bold. No color.
func emphasized(_ preview: String, matching query: String) -> Text {
    // No reason to build an AttributedString when not searching — the cost
    // is paid per row on every render.
    guard !query.isEmpty else { return Text(preview) }

    var attributed = AttributedString(preview)
    if let range = attributed.range(of: query, options: [.caseInsensitive]) {
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
    }
    return Text(attributed)
}
