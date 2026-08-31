import AppKit
import SwiftUI

/// Dedicated window for editing a note.
/// Like the main panel it must be nonactivating — activating would lose the
/// app we paste into.
@MainActor
final class EditPanel: NSPanel {
    private static let size = NSSize(width: 520, height: 320)

    /// How the editor went away — the parent panel reacts differently to an
    /// explicit action (return focus to it) than to focus wandering off
    /// (get out of the way).
    enum DismissReason {
        case explicit
        case focusLost
    }

    var onDismiss: ((DismissReason) -> Void)?

    /// Kept so a focus-loss dismissal can commit what was typed. Losing key
    /// focus is incidental — clicking another app to check a fact must not
    /// discard three paragraphs; Esc stays the one explicit discard.
    private var latestText = ""
    private var originalText = ""
    private var saveHandler: ((String) -> Bool)?
    /// A refusal has two causes that need different words: the item was
    /// removed from under the editor, or the store cannot write at all.
    /// Only the caller can tell them apart.
    private var failureMessage: (() -> LocalizedStringKey)?
    private var state: EditState?
    /// orderOut on the key window posts didResignKey synchronously, which
    /// leads straight back in here with a second, contradicting reason.
    private var dismissing = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            // queue: .main delivers on the main thread, but the closure type
            // itself is nonisolated.
            MainActor.assumeIsolated {
                self?.dismiss(.focusLost)
            }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(
        item: Item,
        over parent: NSWindow,
        onSave: @escaping (String) -> Bool,
        onSaveAndPaste: @escaping (String) -> Bool,
        onDelete: @escaping () -> Void,
        failureMessage: @escaping () -> LocalizedStringKey
    ) {
        originalText = item.content
        latestText = item.content
        saveHandler = onSave
        self.failureMessage = failureMessage

        let state = EditState()
        self.state = state

        let view = EditView(
            // A value snapshot, not the model: the item can be trimmed or
            // purged while the editor is up, and the header would otherwise
            // read a deleted SwiftData object on every keystroke.
            subject: EditSubject(item: item),
            text: item.content,
            state: state,
            onTextChange: { [weak self] text in
                self?.latestText = text
            },
            onSave: { [weak self] text in
                guard onSave(text) else {
                    self?.noteRefusal()
                    return
                }
                self?.dismiss(.explicit)
            },
            onSaveAndPaste: { [weak self] text in
                guard onSaveAndPaste(text) else {
                    self?.noteRefusal()
                    return
                }
                self?.dismiss(.explicit)
            },
            onDelete: { [weak self] in
                onDelete()
                self?.dismiss(.explicit)
            },
            onCancel: { [weak self] in
                self?.dismiss(.explicit)
            }
        )

        contentView = NSHostingView(rootView: view)

        setContentSize(Self.size)
        center(over: parent)
        makeKeyAndOrderFront(nil)
    }

    func dismiss(_ reason: DismissReason = .explicit) {
        guard isVisible, !dismissing else { return }
        dismissing = true
        defer { dismissing = false }

        // Incidental focus loss commits the edit; emptied text is left alone
        // (an accidental blur must never act like delete).
        if reason == .focusLost, latestText != originalText,
            !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // A refused commit means this window holds the only copy of what
            // was typed — stay up and say so rather than close over it.
            guard saveHandler?(latestText) != false else {
                noteRefusal()
                return
            }
        }
        orderOut(nil)
        onDismiss?(reason)
    }

    private func noteRefusal() {
        state?.message = failureMessage?() ?? "edit.gone"
        state?.refused = true
    }

    /// Centered on the parent, then pulled back onto the screen it landed on:
    /// with the panel near an edge the editor would otherwise open partly
    /// offscreen, and its chrome is hidden, so there is nothing to drag it
    /// back by.
    private func center(over parent: NSWindow) {
        let parentFrame = parent.frame
        var origin = NSPoint(
            x: parentFrame.midX - Self.size.width / 2,
            y: parentFrame.midY - Self.size.height / 2
        )

        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - Self.size.height)
        }

        setFrameOrigin(origin)
    }
}

/// The header's fields, copied out of the model when the editor opens.
private struct EditSubject {
    var title: String
    var createdAt: Date

    @MainActor
    init(item: Item) {
        title = item.isNote ? String(localized: "notes.title") : (item.sourceApp ?? "—")
        createdAt = item.createdAt
    }
}

/// Failure raised outside the view — the focus-loss commit — reaching the
/// view that has to show it.
@MainActor
private final class EditState: ObservableObject {
    @Published var refused = false
    @Published var message: LocalizedStringKey = "edit.gone"
}

// MARK: View

/// The edit form: text editor between a metadata header and an action-button
/// footer.
private struct EditView: View {
    let subject: EditSubject
    @ObservedObject var state: EditState

    var onTextChange: (String) -> Void
    var onSave: (String) -> Void
    var onSaveAndPaste: (String) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        subject: EditSubject,
        text: String,
        state: EditState,
        onTextChange: @escaping (String) -> Void,
        onSave: @escaping (String) -> Void,
        onSaveAndPaste: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.subject = subject
        self.state = state
        self.onTextChange = onTextChange
        self.onSave = onSave
        self.onSaveAndPaste = onSaveAndPaste
        self.onDelete = onDelete
        self.onCancel = onCancel
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onKeyPress(phases: .down) { handle($0) }
                // Mirrored out so the panel can commit on focus loss.
                .onChange(of: text) { onTextChange(text) }

            Divider()
            footer
        }
        .background(.ultraThinMaterial)
        // Even with the title bar hidden, its safe area remains and leaves an
        // empty strip at the top.
        .ignoresSafeArea()
        .task {
            focused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(subject.title)
            Text("·")
            Text(subject.createdAt, format: .relative(presentation: .named))
            Spacer(minLength: 0)
            Text("\(text.count)")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.refused {
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(role: .destructive, action: onDelete) {
                buttonLabel("edit.delete", key: "⌘⌫")
            }

            Spacer(minLength: 0)

            Button(action: onCancel) {
                buttonLabel("edit.cancel", key: "esc")
            }
            Button {
                commit(paste: true)
            } label: {
                buttonLabel("edit.saveAndPaste", key: "⌘⇧↩")
            }
            Button {
                commit(paste: false)
            } label: {
                buttonLabel("edit.save", key: "⌘↩", prominent: true)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }

    /// Title plus its shortcut, right in the button — a tooltip nobody
    /// hovers is not discoverability.
    private func buttonLabel(
        _ title: LocalizedStringKey, key: String, prominent: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    prominent ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary)
                )
        }
    }

    /// One path for buttons and keys alike: an emptied note commits as a
    /// deletion, never as an empty save. A refused save leaves the editor
    /// open — the text is nowhere else — and nothing is pasted, since what
    /// would go out is the version before the edit.
    private func commit(paste: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onDelete()
        } else if paste {
            onSaveAndPaste(text)
        } else {
            onSave(text)
        }
    }

    /// Plain Return is not intercepted — in a multiline editor a newline is
    /// the expected behavior.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        let shift = press.modifiers.contains(.shift)

        if press.key == .escape {
            onCancel()
            return .handled
        }
        if command, press.key == .return {
            commit(paste: shift)
            return .handled
        }
        if command, press.key == .delete {
            onDelete()
            return .handled
        }
        return .ignored
    }
}

#if DEBUG
extension EditPanel {
    /// The editor's view, assembled the way `show` assembles it, so the render
    /// smoke tests can lay it out offscreen. The view stays private: the panel
    /// is its only caller in a shipping build, and the only other way to reach
    /// it from a test is to open a real key window.
    static func viewForTesting(item: Item, refused: Bool = false) -> some View {
        let state = EditState()
        state.refused = refused
        return EditView(
            subject: EditSubject(item: item),
            text: item.content,
            state: state,
            onTextChange: { _ in },
            onSave: { _ in },
            onSaveAndPaste: { _ in },
            onDelete: {},
            onCancel: {}
        )
    }
}
#endif
