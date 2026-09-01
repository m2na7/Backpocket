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
            // The number is spoken as part of the row's own sentence, where
            // it can say what it counts; alone it is a bare digit.
            .accessibilityHidden(true)
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
            // Only on screen while ⌘ is held, which is a pointer-and-modifier
            // gesture; VoiceOver reaches every row without it.
            .accessibilityHidden(true)
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

/// The stored content of an image clip is the placeholder "Image {W}×{H}",
/// so only the tail carries information — beside the thumbnail, and in a
/// spoken label where there is no thumbnail to carry the rest.
func imageDimensions(of content: String) -> String {
    content.split(separator: " ").last.map(String.init) ?? content
}

// MARK: - Spoken rows

/// Collapses a row into the one element VoiceOver stops on: a single
/// sentence, the hint that says what ↩ does, and the selected state that the
/// highlight is the sighted half of.
///
/// `children: .ignore` rather than `.combine` because the parts do not read
/// as a list — an app icon, a bolded search match and a relative timestamp
/// concatenate into noise, and the sentence `RowVoice` composes says the same
/// thing in the order a row is scanned.
struct RowSpeech: ViewModifier {
    let voice: RowVoice
    let selected: Bool
    let hint: LocalizedStringKey
    /// What ↩ does. Spelled out rather than left to the row's tap gesture:
    /// that gesture reads the ⌘ key, which is not part of activating a row
    /// from the keyboard.
    let activate: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(voice.label())
            .accessibilityHint(hint)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, activate)
    }
}

/// What a row is, reduced to the facts a screen reader has to be told.
///
/// A row says most of it in icons, glyphs and position — the source app's
/// icon, a pin, a pick badge, which column it sits in — and VoiceOver reads
/// none of that. The sentence that stands in for it is composed from plain
/// values here rather than in the view, so its wording and its order can be
/// checked without laying anything out.
struct RowVoice: Equatable {
    enum Kind: Equatable {
        case clip
        case note
        case link
        case image(dimensions: String)
        case file(name: String)
    }

    var kind: Kind
    /// The row's visible line, left empty where the kind already carries it:
    /// an image's stored content is a placeholder and a file copy's is its
    /// path, and speaking either adds nothing the kind has not said.
    var preview = ""
    var isPinned = false
    /// Clips only. A note was written here, not copied from anywhere.
    var sourceApp: String?
    /// 1-based position in the paste stack, nil when not collected.
    var stackNumber: Int?
}

extension RowVoice {
    /// Reads a clips or links row the way `ItemRow` draws one: the same three
    /// branches in the same order, so what is spoken and what is drawn cannot
    /// disagree about what the row holds.
    @MainActor
    init(clip item: Item, isPinned: Bool, stackNumber: Int?) {
        let files = FileClip.urls(for: item)
        if item.isImage {
            kind = .image(dimensions: imageDimensions(of: item.content))
        } else if !files.isEmpty {
            kind = .file(name: FileClip.label(for: files))
        } else {
            // Asked of the item, not of the column: under
            // `LinkCollection.both` one link is two rows, and calling the one
            // in the clips list a plain clip would describe the same thing
            // two different ways depending on where the cursor reached it.
            kind = item.isLink ? .link : .clip
            preview = item.preview
        }
        self.isPinned = isPinned
        sourceApp = item.sourceApp
        self.stackNumber = stackNumber
    }

    @MainActor
    init(note item: Item, isPinned: Bool, stackNumber: Int?) {
        kind = .note
        preview = item.preview
        self.isPinned = isPinned
        self.stackNumber = stackNumber
    }

    /// The spoken sentence, in the order the eye takes the row: what it is,
    /// what it holds, then the state the trailing column shows.
    ///
    /// The lookup is a parameter because the four `.lproj` bundles ship inside
    /// the built app and a test process has none of them: asserting against
    /// the raw keys `String(localized:)` hands back would assert nothing about
    /// the wording or the order.
    func label(_ localize: (String) -> String = RowVoice.localized) -> String {
        var parts: [String] = []

        switch kind {
        case .clip:
            parts.append(localize("a11y.kind.clip"))
        case .note:
            parts.append(localize("a11y.kind.note"))
        case .link:
            parts.append(localize("kind.link"))
        case .image(let dimensions):
            parts.append(localize("kind.image"))
            parts.append(dimensions)
        case .file(let name):
            parts.append(localize("a11y.kind.file"))
            parts.append(name)
        }

        if !preview.isEmpty {
            parts.append(preview)
        }
        if isPinned {
            parts.append(localize("group.pinned"))
        }
        if let sourceApp, !sourceApp.isEmpty {
            parts.append(String(format: localize("a11y.from %@"), sourceApp))
        }
        if let stackNumber {
            parts.append(String(format: localize("a11y.stack %lld"), stackNumber))
        }

        // A comma is where VoiceOver pauses, which is what keeps a handful of
        // facts a sentence rather than one run-on word.
        return parts.joined(separator: ", ")
    }

    /// The shipping lookup. Takes a runtime key because `label` above is what
    /// chooses between them; nothing in this repo extracts strings from
    /// source, so spelling them as literals would buy nothing.
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(stringLiteral: key))
    }
}
