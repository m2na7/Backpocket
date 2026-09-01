import AppKit
import SwiftData
import SwiftUI

/// Resolving a file copy touches the filesystem, which a row body must
/// never do per render. Keyed by content, which is only sound because
/// everything that is not a genuine file copy is rejected before the lookup:
/// a file deleted mid-session is caught by the paste path's own check.
@MainActor
enum FileClip {
    private static var cache = BoundedCache<String, [URL]>(limit: 256)

    static func urls(for item: Item) -> [URL] {
        // The full guard from fileURLs, not just the cheap half. Content
        // alone does not decide this: the TEXT `/Users/you/.ssh/id_rsa` and a
        // copy of that FILE are the same string, and `Store.add` reuses the
        // existing row for repeated content and assigns `isFileCopy` in
        // place. Testing only the path prefix here let a real file copy prime
        // the entry and the typed text then hit it, drawing a file icon and
        // filename for a plain piece of text — the one confusion the capture
        // path exists to prevent. Everything rejected below returns without
        // touching the disk, so it needs no cache entry of its own.
        guard item.isFileCopy, !item.isNote, !item.isImage,
            item.content.hasPrefix("/"), item.content.utf8.count <= 8_192
        else { return [] }
        if let cached = cache[item.content] { return cached }

        let urls = item.fileURLs
        cache.insert(urls, for: item.content)
        return urls
    }

    /// "photo.png", or "photo.png +2" for a multi-file copy.
    static func label(for urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        return urls.count > 1
            ? "\(first.lastPathComponent) +\(urls.count - 1)"
            : first.lastPathComponent
    }
}

/// PNG decoding is too slow to repeat on every row render. Keyed by the
/// persistent identity: thumbnails are written once at record time and never
/// change, so entries never go stale.
@MainActor
enum Thumbnail {
    private static var cache = BoundedCache<PersistentIdentifier, NSImage?>(limit: 256)

    static func image(for item: Item) -> NSImage? {
        // Bounded because the panel outlives every item: entries re-decode
        // lazily from the small stored PNGs, so losing them costs little.
        if let cached = cache[item.id] { return cached }

        let image = item.thumbnailData.flatMap { NSImage(data: $0) }
        cache.insert(image, for: item.id)
        return image
    }
}

// MARK: - Row

/// One list row, isolated behind Equatable so SwiftUI can skip it.
///
/// Hover drives selection, so every pointer move invalidates the parent view.
/// Re-evaluating every visible row on each of those passes — context menu
/// included — is what made hover tracking and scrolling lag. With this
/// equality check, only the rows whose highlight actually changed re-render.
struct ItemRow: View, @MainActor Equatable {
    let item: Item
    /// Captured separately as the change stamp: edits bump `usedAt`, so a row
    /// whose content changed compares unequal without comparing the content.
    let usedAt: Date
    /// Captured too, for the same reason: pinning deliberately leaves `usedAt`
    /// alone, and reading the flag off the shared item would compare a value
    /// against itself — the top row would keep its old glyph.
    let isPinned: Bool
    /// The ⌘-slot badge ("3", or "⇧3" for the links section) while Command
    /// is held; takes the icon's place, Raycast-style.
    let shortcut: String?
    /// 1-based position in the paste stack, nil when not collected.
    let stackNumber: Int?
    /// A stack is being collected somewhere — the trailing column shows pick
    /// numbers instead of timestamps until it is pasted or dropped.
    let stacking: Bool
    let query: String
    let highlighted: Bool
    /// True in the links section: the row leads with a globe and renders the
    /// URL as domain + path instead of the raw content string.
    let asLink: Bool

    let onHover: () -> Void
    let onExit: () -> Void
    let onActivate: () -> Void
    let onToggleStack: () -> Void
    let onConvert: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onPasteMarkdown: () -> Void
    let onOpenLink: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item === rhs.item
            && lhs.usedAt == rhs.usedAt
            && lhs.isPinned == rhs.isPinned
            && lhs.shortcut == rhs.shortcut
            && lhs.stackNumber == rhs.stackNumber
            && lhs.stacking == rhs.stacking
            && lhs.query == rhs.query
            && lhs.highlighted == rhs.highlighted
            && lhs.asLink == rhs.asLink
    }

    var body: some View {
        draggableRow
            .contextMenu { menu }
            // Exit is reported, not inferred from the next row's entry: a
            // pointer can leave a row for a header, the empty space under the
            // list, or the window itself. The parent drops the exit unless
            // this row is still the hovered one, so the two events racing
            // between adjacent rows cannot blink the highlight.
            .onHover { inside in
                if inside {
                    onHover()
                } else {
                    onExit()
                }
            }
            .onTapGesture {
                // ⌘-click collects for the stack — the mouse mirror of ⌘D.
                if clickHasCommand() {
                    onToggleStack()
                } else {
                    onActivate()
                }
            }
            .modifier(
                RowSpeech(
                    voice: voice,
                    selected: highlighted,
                    hint: "a11y.hint.paste",
                    activate: onActivate
                )
            )
            // Everything the row can do, since none of it is reachable
            // otherwise: the pin and the pick badge are read-only glyphs and
            // the rest lives in a right-click menu.
            .accessibilityActions {
                if item.isLink {
                    Button("ctx.openLink", action: onOpenLink)
                }
                if !item.isImage {
                    Button(
                        stackNumber == nil ? "ctx.stackAdd" : "ctx.stackRemove",
                        action: onToggleStack
                    )
                    Button("ctx.toNote", action: onConvert)
                }
                Button(isPinned ? "ctx.unstar" : "ctx.star", action: onTogglePin)
                Button("ctx.delete", action: onDelete)
            }
    }

    /// The row as a sentence. Built per render like the rest of the body, and
    /// cheap for the same reason it is: every lookup behind it is cached.
    private var voice: RowVoice {
        RowVoice(clip: item, isPinned: isPinned, stackNumber: stackNumber)
    }

    /// Dropping onto the notes pane turns a clip into a note. Dragging out to
    /// other apps comes along for free. Image rows are not drag sources: their
    /// content is a placeholder string, and delivering "Image 640×400" as text
    /// anywhere would be nonsense.
    @ViewBuilder
    private var draggableRow: some View {
        if item.isImage {
            row
        } else {
            row.draggable(item.content)
        }
    }

    private var row: some View {
        HStack(spacing: 9) {
            leading

            if item.isImage {
                imagePreview
            } else {
                preview
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            // While a stack is being collected, the trailing column belongs
            // to the pick numbers: badges land exactly where the timestamps
            // were, and un-picked rows go blank instead of ragged.
            if let stackNumber {
                StackBadge(number: stackNumber)
            } else if !stacking {
                Text(usedAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        // The highlight must snap, not fade — a fade reads as lag.
        .animation(nil, value: highlighted)
        .contentShape(Rectangle())
    }

    /// The row's identity at a glance: the source app's icon for clips, a
    /// pencil for notes. While Command is held the Cmd+1..9 slot shows instead.
    @ViewBuilder
    private var leading: some View {
        if let shortcut {
            ShortcutChip(label: shortcut)
        } else if asLink, let url = item.linkURL {
            FaviconView(url: url)
        } else if let file = FileClip.urls(for: item).first {
            Image(nsImage: AppIcon.icon(forFile: file.path))
                .resizable()
                .frame(width: 17, height: 17)
        } else if let icon = AppIcon.icon(for: item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 17, height: 17)
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 17, height: 17)
        }
    }

    /// The pixels identify an image at a glance; the content string is only a
    /// placeholder. Decoding is cached — the body must never decode Data.
    @ViewBuilder
    private var imagePreview: some View {
        if let thumbnail = Thumbnail.image(for: item) {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(imageDimensions(of: item.content))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            // Thumbnail bytes can be missing or undecodable; the localized
            // kind reads better than the stored English placeholder.
            Text("kind.image")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// While searching, only the matched part goes bold. No color.
    private var preview: Text {
        // A file copy reads as its name; the path is plumbing.
        let files = FileClip.urls(for: item)
        if !files.isEmpty {
            return Text(FileClip.label(for: files))
        }

        // Scanning a list of links is scanning domains, so the host is
        // emphasized IN PLACE and the rest recedes — never a rebuilt string,
        // which would drop the scheme, port, and fragment and make distinct
        // links (localhost:3000 vs :8080, #-routed pages) render identically.
        // While searching, the plain match-bolding branch takes over.
        if asLink, query.isEmpty, item.linkURL != nil {
            let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            var line = AttributedString(trimmed)
            // percentEncoded: false, so an IDN host matches its verbatim text.
            // The rest dims only when the host is found — a miss must render
            // like any ordinary row, not as a wholly dimmed one.
            if let host = item.linkURL?.host(percentEncoded: false),
                let range = line.range(of: host)
            {
                line.foregroundColor = .secondary
                line[range].foregroundColor = .primary
                line[range].inlinePresentationIntent = .stronglyEmphasized
            }
            return Text(line)
        }

        return emphasized(item.preview, matching: query)
    }

    /// Right-click menu for mouse users — carries only the same actions the
    /// keyboard shortcuts offer.
    @ViewBuilder
    private var menu: some View {
        Button("ctx.paste", action: onActivate)

        if !item.isImage {
            Button(
                stackNumber == nil ? "ctx.stackAdd" : "ctx.stackRemove",
                action: onToggleStack
            )
        }

        if item.isLink {
            Button("ctx.openLink", action: onOpenLink)
        }

        // Markdown and note conversion are text transformations — an image
        // has no text to transform, so both entries would be dead actions.
        if !item.isImage {
            if item.contentHTML != nil {
                Button("ctx.pasteMarkdown", action: onPasteMarkdown)
            }

            Button("ctx.toNote", action: onConvert)
        }

        Button(isPinned ? "ctx.unstar" : "ctx.star", action: onTogglePin)

        Divider()

        Button("ctx.delete", role: .destructive, action: onDelete)
    }
}
