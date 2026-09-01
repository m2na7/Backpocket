import AppKit
import SwiftData
import SwiftUI

/// The panel's main view: a single text field that serves as both search
/// and note entry, with clipboard history on the left and notes on the right.
struct ContentView: View {
    @ObservedObject var store: Store

    var onPaste: (Item) -> Void
    var onClose: () -> Void
    var onOpenSettings: () -> Void
    var onDetail: (Item?, Bool) -> Void
    var onEdit: (Item) -> Void
    var onPasteMarkdown: (Item) -> Void
    var onOpenLink: (Item) -> Void
    var onPasteStack: ([Item]) -> Void

    @State private var text = ""
    /// Which row is lit, in which pane, and whether the user aimed at it.
    @State private var selection = PanelSelection()
    /// Snapshotted on every panel show, in `reset()`; flipping either
    /// preference mid-session takes effect the next time the panel opens,
    /// not mid-keystroke.
    ///
    /// The rule for every preference this view reads: one that decides which
    /// PANES EXIST is snapshotted at open, everything else is read live at
    /// its point of use. The focus and the selection live in a pane, so
    /// re-deciding the set of panes under a keystroke moves both out from
    /// under the user; a preference that only changes how a pane looks —
    /// `LinkRows` sizing the links section, `LinkClickAction` deciding what
    /// activating a row does — has nothing to move and applies at once.
    /// The accessibility gate in `body` is not a pane preference: it reads
    /// `PasteBehavior` live because it is paired with `trusted`, which has to
    /// stay live so granting the permission lifts onboarding on the spot.
    ///
    /// The difference is not observable today — both routes into Settings
    /// hide the panel before it opens, and re-summoning it runs `reset()` —
    /// so this states the rule for the next preference rather than papering
    /// over something the user can see.
    @State private var linkCollection = LinkCollection.current
    @State private var showsNotes = NotesVisibility.isEnabled
    @State private var hoverState = HoverMachine()
    @State private var dropTargeted = false
    @State private var showsShortcuts = false
    /// The ⌘ and pointer-travel watches, which own their own registration.
    @State private var monitors = PanelEventMonitors()
    @State private var trusted = Paster.isTrusted
    /// Bumped on every panel show so both lists rewind to the top.
    @State private var openTick = 0
    /// How much of the width the notes column takes, and the divider drag.
    @State private var split = SplitDrag(fraction: NotesFraction.current)
    /// The panel's show counter as of the last reset, so regaining key focus
    /// can be told apart from a fresh open.
    @State private var lastShowCount = 0
    @State private var stack = PasteStack()
    @FocusState private var fieldFocused: Bool

    #if DEBUG
    /// Pre-fills the field for screenshot-based verification — the shell
    /// cannot type into a non-activating panel.
    private static let debugQuery = DebugLaunch.query ?? ""
    /// --demo exists to screenshot the list, but the accessibility gate would
    /// replace it with onboarding on any machine that never granted the
    /// permission — and ad-hoc rebuilds reset the grant on every build.
    private static let bypassesOnboarding = DebugLaunch.seedDemo
    #else
    private static let debugQuery = ""
    private static let bypassesOnboarding = false
    #endif

    /// The row the pointer is on, resolved against the store — `hovered` is
    /// only an id, and the row it named can have been filtered out or deleted.
    private var hoveredItem: Item? {
        guard let hovered = hoverState.hovered else { return nil }
        return store.items.first { $0.id == hovered }
    }

    /// The row every action aims at.
    private var actionTarget: Item? {
        PanelTargeting.actionTarget(hovered: hoveredItem, selected: selectedItem)
    }

    /// The row a pause over may grow a preview card against.
    private var dwellTarget: Item? {
        PanelTargeting.dwellTarget(
            hovered: hoveredItem,
            selected: selectedItem,
            selectionIsAutomatic: selection.isAutomatic
        )
    }

    // MARK: Derived state

    /// Serves both search and note entry — the search text IS the note text.
    private var query: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Several places read the lists within one render pass, so computed
    // properties would re-run the same filter every time. Filter once, only
    // when the source or the query changes.
    @State private var contents = PanelContents()

    /// Hands the highlight to the keyboard: clears any hover and ignores
    /// hover entries until the pointer genuinely moves (see hoverAnchor).
    private func suppressHover() {
        hoverState.suppress(at: NSEvent.mouseLocation)
    }

    /// Clears the hover machine outright, anchor and pending entry included.
    /// The mouse monitor lives on the hosting view, which survives hide and
    /// show: an anchor left over from the previous session is trivially far
    /// from wherever the panel is re-summoned, so the first pointer move
    /// would replay a hover onto a row the pointer is nowhere near.
    private func resetHover() {
        hoverState.reset()
    }

    /// Tears down the detail card, which is placed against a row in a layout
    /// that is about to stop being true.
    private func dismissDetail() {
        onDetail(nil, false)
    }

    /// Rebuilds the three lists from the store and the query. Data only:
    /// dropping the hover highlight and dismissing the detail card used to
    /// ride along here, so recomputing the lists also closed a card the user
    /// might be reading, and a `keyboardDriven:` flag picked which of two
    /// hover behaviours the caller inherited. Both are now stated by the
    /// caller, which is the only place that knows what changed underneath.
    private func recomputeLists() {
        contents = PanelContents.make(items: store.items, query: query, links: linkCollection)

        // Every store mutation lands here via store.revision, so this is where
        // a handful notices that one of its picks is gone.
        stack.prune { id in store.items.contains { $0.id == id } }
    }

    /// The panes actually on screen, in Tab order. Everything that moves the
    /// focus reads this: focusing a pane the user cannot see advertises
    /// actions against invisible rows.
    private var visiblePanes: [Pane] {
        PaneOrder.visible(showsLinks: linkCollection.showsLinks, showsNotes: showsNotes)
    }

    /// Where Tab goes from here: the next visible pane, wrapping around.
    private var nextPane: Pane {
        PaneOrder.next(
            after: selection.pane, showsLinks: linkCollection.showsLinks, showsNotes: showsNotes)
    }

    private var focusedItems: [Item] {
        contents[selection.pane]
    }

    private var selectedItem: Item? {
        focusedItems.first { $0.id == selection.selected }
    }

    /// Whether the focused pane has results — see `PanelContents`, which owns
    /// what counts as one.
    private var hasMatches: Bool {
        contents.hasMatches(in: selection.pane)
    }

    /// Everything the dispatcher and the footer hints need to know about the
    /// panel's state, with the store, the lists and the view left out.
    private var keyContext: PanelKeyContext {
        let selected = selectedItem
        return PanelKeyContext(
            pane: selection.pane,
            hasQuery: !query.isEmpty,
            hasMatches: hasMatches,
            hasSelection: selected != nil,
            showsNotes: showsNotes,
            stackIsEmpty: stack.isEmpty,
            canUndoDelete: store.canUndoDelete
        )
    }

    /// What pressing Return (and Cmd-Return) would do right now. Both go
    /// through the same resolver as the actual key handling, so the footer
    /// hints cannot lie.
    private var primaryAction: EnterAction {
        PanelKeyboard.resolvedAction(command: false, in: keyContext)
    }

    private var inverseAction: EnterAction {
        PanelKeyboard.resolvedAction(command: true, in: keyContext)
    }

    private func label(for action: EnterAction) -> LocalizedStringKey? {
        switch action {
        case .paste: "ctx.paste"
        // The same resolver case is two different promises: typed text is
        // saved as a new note, an empty field converts the selected clip.
        case .saveNote: query.isEmpty ? "ctx.toNote" : "action.saveNote"
        case .edit: "ctx.edit"
        case .none: nil
        }
    }

    /// Cmd+Enter with an empty field converts the selected clip to a note,
    /// which no-ops for images — the chip must not advertise a dead action.
    private var inverseHintHidden: Bool {
        inverseAction == .saveNote && query.isEmpty && selectedItem?.isImage == true
    }

    // MARK: Body

    var body: some View {
        Group {
            // With automatic paste off no permission is needed, so don't block with onboarding.
            if trusted || !PasteBehavior.isAutomatic || Self.bypassesOnboarding {
                main
            } else {
                Onboarding(tick: openTick) { trusted = Paster.isTrusted }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        // Hiding the title bar still leaves the safe area, which shows as an empty strip on top.
        .ignoresSafeArea()
        // The first show right after launch happens before this view subscribes
        // to notifications, so onAppear has to catch it too.
        .onAppear { reset() }
        // Recompute on the revision counter, not on `items`: in-place changes
        // (converting the item that is already first) leave the array
        // reference-equal, and membership still moved between sections.
        .onChange(of: store.revision) {
            // The store moved under the pointer, not the keyboard: the
            // highlight names a row from a layout that no longer exists, but
            // the pointer keeps its claim — it is still resting on a row.
            hoverState.dropHighlight()
            dismissDetail()
            recomputeLists()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { note in
            // Only the main panel resets the search — the editor and the
            // settings window becoming key must not wipe the user's place.
            guard let panel = note.object as? BackpocketPanel else { return }
            trusted = Paster.isTrusted

            // Becoming key again is not the same as opening. The editor hands
            // focus back this way, and resetting there threw away the pane,
            // the selection and the collected handful — the notes column
            // visibly collapsed and sprang back as `pane` bounced to clips.
            guard panel.showCount != lastShowCount else {
                fieldFocused = true
                return
            }
            lastShowCount = panel.showCount
            reset()
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            field
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    leftColumn(height: geometry.size.height)
                    if showsNotes {
                        splitHandle(in: geometry.size.width)
                        notesColumn(width: split.width(in: geometry.size.width))
                    }
                }
            }
            Divider()
            footer
        }
        .onAppear {
            monitors.install(
                commandHeld: { held in
                    showsShortcuts = held
                    // Collecting is one ⌘-held gesture, so letting go ends it;
                    // asking for Return after that commits the same intent
                    // twice. Asking the app which window is key, rather than
                    // the event which may carry none, is what keeps a hidden
                    // panel's leftover handful from pasting into Settings.
                    if !held, NSApp.keyWindow is BackpocketPanel, stack.hasText {
                        pasteStack()
                    }
                },
                // The one legitimate lifter of the keyboard's hover hold: real
                // hardware pointer travel, which layout can never synthesize.
                // The 12pt distance filters out trackpad palm jitter.
                pointerMoved: { location in
                    if let replay = hoverState.pointerMoved(to: location),
                        let item = store.items.first(where: { $0.id == replay.id })
                    {
                        hover(item, in: replay.pane)
                    }
                }
            )
        }
        .onDisappear { monitors.teardown() }
        // Dwelling on the same item for a moment shows the detail panel.
        // A changed id cancels the pending task automatically.
        .task(id: dwellTarget?.id) {
            dismissDetail()
            guard PreviewBehavior.isEnabled, let target = dwellTarget else { return }

            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }

            onDetail(target, hoverState.hovered != nil)
        }
    }

    // MARK: The one field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField("field.placeholder", text: $text, axis: .vertical)
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($fieldFocused)
                .onKeyPress(phases: [.down, .repeat]) { handle($0) }
                .onChange(of: text) {
                    // Typing hands the highlight to the keyboard: the re-layout
                    // would otherwise re-fire hover for whatever row lands
                    // under the stationary pointer, and a remembered hover
                    // would keep the card — and ⌘O — on a filtered-out row.
                    suppressHover()
                    dismissDetail()
                    recomputeLists()
                    selection.queryChanged(
                        to: contents.rows, hasQuery: !query.isEmpty, visiblePanes: visiblePanes)
                }

        }
        // Keeps the field's icon on the same vertical line as the row icons below.
        .padding(.leading, PanelMetrics.textLeading)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
    }

    // MARK: Footer — Raycast-style action bar

    private var footer: some View {
        HStack(spacing: 12) {
            Text("footer.items \(store.items.count)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            // The stack chip and the ⌘-release commit share the same emptiness
            // check, so this promise stays as honest as the resolver-driven
            // ones.
            if !stack.isEmpty {
                if stack.hasText {
                    hint("⌘", "hint.pasteStack \(stack.count)")
                }
                hint(PanelShortcut.delete.current.label, "hint.deleteStack \(stack.count)")
            } else if let label = label(for: primaryAction) {
                hint("↩", label)
            }
            if let label = label(for: inverseAction), inverseAction != primaryAction,
                !inverseHintHidden
            {
                hint("⌘↩", label)
            }
            if selectedItem?.isLink == true {
                hint(PanelShortcut.openLink.current.label, "action.open")
            } else if selection.pane == .clips, stack.isEmpty,
                let selected = selectedItem, !selected.isImage, !selected.isNote
            {
                hint(PanelShortcut.stack.current.label, "hint.stack")
            }
            hint("⇥", tabHintLabel)
            hint("⌘,", "hint.settings")
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.footer)
    }

    /// Names the pane Tab moves to next. Read from the same rule Tab itself
    /// follows, so the hint cannot promise a pane the key will not go to.
    private var tabHintLabel: LocalizedStringKey {
        switch nextPane {
        case .clips: "hint.toClips"
        case .links: "hint.toLinks"
        case .notes: "hint.toNotes"
        }
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4.5)
                        .fill(Color.primary.opacity(0.06))
                )
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    // MARK: Left — clipboard history, with the links section below when split

    private func leftColumn(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            column(
                items: contents.clips,
                pane: .clips,
                // Driven by the same resolver as the footer chip and the key
                // handler, so this text can never promise the wrong Enter.
                emptyKey: primaryAction == .saveNote ? "empty.willSaveNote" : "empty.none",
                // Headerless when it is the whole column — today's look; the
                // header only appears once the links section shares the space.
                header: linkCollection.showsLinks ? "clips.title" : nil
            )
            if linkCollection.showsLinks {
                Divider()
                column(
                    items: contents.links,
                    pane: .links,
                    emptyKey: "links.empty",
                    header: "links.title",
                    asLinks: true
                )
                // Sized to its content up to the configured row count; the
                // clipboard list absorbs whatever the links don't use. Empty,
                // the section collapses to its header and hint line. Capped by
                // the height that actually exists: the frame is rigid, so at a
                // short panel it would otherwise run past the footer and leave
                // the clipboard list with no room at all.
                .frame(height: linksSectionHeight(in: height))
            }
        }
    }

    /// Never more than the reader's height less a header and one clip row —
    /// the clipboard list must always keep a row.
    ///
    /// `LinkRows` is read live on every layout pass, not snapshotted: it only
    /// sizes this section, so nothing the user is aiming at moves.
    private func linksSectionHeight(in available: CGFloat) -> CGFloat {
        let desired =
            contents.links.isEmpty
            ? PanelMetrics.emptyLinksHeight
            : PanelMetrics.linksSectionHeight(rows: min(contents.links.count, LinkRows.current))
        let ceiling = max(
            available - PanelMetrics.sectionHeader - PanelMetrics.rowPitch - 1,
            PanelMetrics.rowPitch
        )
        return min(desired, ceiling)
    }

    // MARK: Right — notes, time-grouped

    /// The draggable divider. A 1pt line reads as the boundary; the hit area
    /// around it is what makes the drag findable.
    private func splitHandle(in total: CGFloat) -> some View {
        Divider()
            .padding(.horizontal, 3)
            .background(Color.primary.opacity(0.001))
            .contentShape(Rectangle())
            // set(), not push()/pop(): a missed exit — the panel hiding under
            // the pointer, say — would leave a pushed cursor stuck for every
            // app. The worst this can do is show the resize cursor a moment
            // too long, and the next tracking area corrects it.
            .onHover { inside in
                // Hold-to-move reads this: the divider sits mid-window, past
                // the panel's own resize-edge guard, so pausing a beat to aim
                // at a 7pt target would otherwise slide the whole window
                // instead of resizing the split.
                BackpocketPanel.frontmost?.pointerOnDivider = inside
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        split.drag(translation: value.translation.width, in: total)
                    }
                    .onEnded { _ in
                        if let dragged = split.end() {
                            // Stored on release, not per frame: the preference
                            // clamps, so the settled value comes back from it.
                            NotesFraction.store(dragged)
                            split.settle(at: NotesFraction.current)
                        }
                    }
            )
    }

    private func notesColumn(width: CGFloat) -> some View {
        notesContent
            .frame(width: width)
            .opacity(selection.pane == .notes ? 1 : 0.55)
            .dropDestination(for: String.self) { dropped, _ in
                convertToNotes(dropped)
            } isTargeted: {
                dropTargeted = $0
            }
            .background(dropTargeted ? Color.secondary.opacity(0.12) : .clear)
    }

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "notes.title", count: contents.notes.count)

            if contents.notes.isEmpty {
                EmptyLine(text: "notes.empty")
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(contents.noteSections) { section in
                            groupHeader(section.group, count: section.rows.count)
                                .listRowSeparator(.hidden)
                                .listRowInsets(PanelMetrics.rowInsets)

                            ForEach(section.rows, id: \.item.id) { row in
                                NoteRow(
                                    item: row.item,
                                    usedAt: row.item.usedAt,
                                    isPinned: row.item.isPinned,
                                    timeLabel: row.timeLabel,
                                    shortcut: noteShortcut(for: row.item),
                                    stackNumber: stack.number(of: row.item.id),
                                    stacking: !stack.isEmpty,
                                    query: query,
                                    highlighted: hoverState.hovered == row.item.id
                                        || (selection.pane == .notes
                                            && selection[.notes] == row.item.id),
                                    pointerHovering: hoverState.hovered == row.item.id,
                                    onHover: { hover(row.item, in: .notes) },
                                    onExit: { unhover(row.item) },
                                    onActivate: { activate(row.item, in: .notes) },
                                    onToggleStack: { toggleStack(row.item) },
                                    onEdit: {
                                        hoverState.dropHighlight()
                                        onEdit(row.item)
                                    },
                                    onTogglePin: { store.togglePin(row.item) },
                                    onDelete: { store.delete(row.item) }
                                )
                                .equatable()
                                .id(row.item.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(PanelMetrics.rowInsets)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection.scrollTarget) {
                        guard let target = selection.scrollTarget else { return }
                        proxy.scrollTo(target)
                    }
                    .onChange(of: contents.notes.first?.id) {
                        if let first = contents.notes.first?.id { proxy.scrollTo(first) }
                    }
                    .onChange(of: openTick) {
                        if let first = contents.notes.first?.id { proxy.scrollTo(first) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Widening already signals attention, so the dim lifts with it.
    }

    /// Cmd+1..9 slots act on the focused pane; the numbers must appear there.
    private func noteShortcut(for item: Item) -> Int? {
        guard selection.pane == .notes, showsShortcuts,
            let index = contents.notes.prefix(9).firstIndex(where: { $0.id == item.id })
        else { return nil }
        return index + 1
    }

    private func groupHeader(_ group: NoteGroup, count: Int) -> some View {
        return HStack(spacing: 6) {
            if group == .pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
            Group {
                switch group {
                case .pinned: Text("group.pinned")
                case .today: Text("group.today")
                case .last7Days: Text("group.last7")
                case .last30Days: Text("group.last30")
                case .month(let label): Text(label)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        // A band, not a floating label: the strip is what makes the group
        // legible at a glance; the pin glyph alone marks the pinned block.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.035))
        )
        .padding(.top, 7)
    }

    /// One list, told which pane it IS rather than left to work it out from
    /// the rows it was handed. Under `LinkCollection.both` a link is a row in
    /// this column and a row in the other one, so anything derived from the
    /// item — which pane it belongs to, whether it is the hovered one — would
    /// answer for both copies and light the row the pointer is not on.
    private func column(
        items: [Item],
        pane: Pane,
        emptyKey: LocalizedStringKey,
        header: LocalizedStringKey?,
        asLinks: Bool = false
    ) -> some View {
        let active = selection.pane == pane
        let selected = selection[pane]
        // ⌘1..9 act on the focused pane, so the numbers belong to it too.
        let numbered = active

        return VStack(alignment: .leading, spacing: 0) {
            if let header {
                SectionTitle(title: header, count: items.count)
            }

            if items.isEmpty {
                EmptyLine(text: emptyKey)
            } else {
                ScrollViewReader { proxy in
                    // No List selection binding on purpose: the system style
                    // draws a heavy "clicked" bar and keeps it in the unfocused
                    // pane. One quiet highlight serves hover and keyboard both.
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            usedAt: item.usedAt,
                            isPinned: item.isPinned,
                            shortcut: numbered && showsShortcuts && index < 9
                                ? String(index + 1) : nil,
                            stackNumber: stack.number(of: item.id),
                            stacking: !stack.isEmpty,
                            query: query,
                            // Both halves are scoped to the focused pane. The
                            // hover half can be: hovering focuses the pane it
                            // is in, and anything that moves the focus without
                            // the pointer suppresses the hover first — so a
                            // hovered row is always in the active pane, and a
                            // link's other copy stays dark.
                            highlighted: active
                                && (hoverState.hovered == item.id || selected == item.id),
                            asLink: asLinks,
                            onHover: { hover(item, in: pane) },
                            onExit: { unhover(item) },
                            onActivate: { activate(item, in: pane) },
                            onToggleStack: { toggleStack(item) },
                            onConvert: { store.convertToNote(item) },
                            onTogglePin: { store.togglePin(item) },
                            onDelete: { store.delete(item) },
                            onPasteMarkdown: { onPasteMarkdown(item) },
                            onOpenLink: { onOpenLink(item) }
                        )
                        .equatable()
                        .id(item.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(PanelMetrics.rowInsets)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Keyboard moves scroll; hover must not yank the list around.
                    .onChange(of: selection.scrollTarget) {
                        guard let target = selection.scrollTarget else { return }
                        proxy.scrollTo(target)
                    }
                    // Insertions at the top keep the old offset, sliding rows
                    // under the header; pin back to the top instead.
                    .onChange(of: items.first?.id) {
                        if let first = items.first?.id { proxy.scrollTo(first) }
                    }
                    .onChange(of: openTick) {
                        if let first = items.first?.id { proxy.scrollTo(first) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Dims the unfocused pane so its selection highlight stands out less.
        .opacity(active ? 1 : 0.55)
    }

    /// Hovering IS selecting — and focusing. The pane follows the pointer,
    /// so exactly one row is ever lit and every action (Enter, ⌘O, ⌘⌫, the
    /// footer chips) targets that visible row. Selection without focus left
    /// the previous pane's selection glowing as a second highlight.
    private func hover(_ item: Item, in pane: Pane) {
        // While the keyboard holds the highlight, entry events are dropped
        // outright: every keystroke re-lays the list out and the tracking
        // areas re-fire entries under a stationary pointer, and judging
        // "did the mouse move" here is defeated by trackpad jitter. Only
        // the mouse-move monitor — fed by real hardware events that layout
        // can never synthesize — lifts the hold.
        // Held entries are remembered rather than discarded: the pointer may
        // already be resting on this row when the hold lifts, and no further
        // entry event would arrive.
        guard hoverState.enter(item.id, in: pane) else { return }

        selection.select(item.id, in: pane, origin: .user)
    }

    /// Only the row that still holds the highlight may clear it: exits and
    /// entries race when the pointer crosses between adjacent rows, and a
    /// blind clear would blink the row the pointer just arrived on.
    private func unhover(_ item: Item) {
        guard hoverState.hovered == item.id else { return }
        hoverState.exit(item.id)
        // hover() also selects the row, so the dwell target would fall back
        // to it and the card would never be dismissed. Only the hover-derived
        // claim is dropped; arrow keys re-assert it themselves.
        selection.markAutomatic()
    }

    private func activate(_ item: Item, in pane: Pane) {
        // A click is unambiguous mouse intent — it releases the keyboard's
        // hold even if the pointer never traveled.
        hoverState.release()
        selection.select(item.id, in: pane, origin: .user)
        paste()
    }

    // MARK: Key handling

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // The shortcut is matched here rather than inside the dispatcher
        // because matching consults the live NSEvent for the physical key,
        // which is the one part of dispatch that cannot be pure.
        let reduced = PanelKeyPress(
            key: press.key,
            isRepeat: press.phase != .down,
            modifiers: press.modifiers,
            matchingShortcut: { PanelShortcut.match(press) }
        )
        return perform(PanelKeyboard.command(for: reduced, in: keyContext))
    }

    /// Carries out the dispatcher's decision. Nothing is decided here: the
    /// guards that remain are about the store, which the dispatcher cannot
    /// see.
    private func perform(_ command: PanelCommand) -> KeyPress.Result {
        switch command {
        case .move(let delta): move(delta)
        case .switchPane: switchPane()
        case .focusClips: focus(.clips)
        case .close: onClose()
        case .openSettings:
            onClose()
            onOpenSettings()
        case .clearStack: stack.clear()
        case .pasteStack: pasteStack()
        case .deleteStack: deleteStack()
        case .toggleStack: toggleStack()
        case .pasteSelection: paste()
        case .pasteSlot(let index): paste(at: index)
        case .deleteSelection: deleteSelected()
        case .undoDelete: undoDelete()
        case .saveNote: saveNote()
        case .edit: startEdit()
        case .togglePin: togglePin()
        case .openLink:
            // Pointing at a link and pressing open must open THAT link, card
            // or no card; the keyboard selection is the fallback.
            if let target = actionTarget, target.isLink {
                onOpenLink(target)
            }
        case .consumed: break
        case .unhandled: return .ignored
        }
        return .handled
    }

    // MARK: Actions

    private func switchPane() {
        focus(nextPane)
    }

    private func focus(_ target: Pane) {
        // Switching sections is a keyboard gesture; a hover highlight left
        // behind in the previous section would show two active rows at once.
        suppressHover()
        selection.focus(target, in: contents.rows, origin: .user)
    }

    private func move(_ delta: Int) {
        // The mouse is not moving; its highlight yields to the keyboard —
        // including the re-entry the scroll is about to fire underneath it.
        // Only once there is somewhere to move: an arrow press in an empty
        // pane must leave the pointer's own highlight alone.
        if selection.move(delta, in: contents.rows) {
            suppressHover()
        }
    }

    private func paste() {
        guard let selectedItem else { return }
        activateItem(selectedItem)
        text = ""
    }

    /// Activating a link honors its configured default action; everything
    /// else pastes. Click, ⌘1..9 and ⌘⇧1..9 all come through here, so a link
    /// never behaves one way under the mouse and another under the keyboard.
    private func activateItem(_ item: Item) {
        if item.isLink, LinkClickAction.current == .open {
            onOpenLink(item)
        } else {
            onPaste(item)
        }
    }

    private func paste(at index: Int) {
        let items = focusedItems
        guard items.indices.contains(index) else { return }
        activateItem(items[index])
        text = ""
    }

    private func toggleStack() {
        guard let target = actionTarget else { return }
        toggleStack(target)
    }

    private func toggleStack(_ item: Item) {
        stack.toggle(item.id, isText: !item.isImage)
    }

    private func pasteStack() {
        let picked = stack.ids.compactMap { id in store.items.first { $0.id == id } }
        stack.clear()
        guard !picked.isEmpty else { return }
        onPasteStack(picked)
        text = ""
    }

    /// Converts the clips matching the dropped content into notes.
    /// Text dragged in from other apps is accepted too.
    private func convertToNotes(_ dropped: [String]) -> Bool {
        var converted = false

        for content in dropped {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            store.adoptAsNote(content)
            converted = true
        }

        if converted {
            // The drop already mutated the store; without this the selection
            // below is taken from the pre-drop snapshots and the clips pane
            // keeps pointing at an item that is now a note. Mouse-driven like
            // every other row action, so hover stays alive: pinning the
            // keyboard's anchor here would leave the column the pointer is
            // resting on unable to highlight anything.
            hoverState.dropHighlight()
            dismissDetail()
            recomputeLists()
            selection.selectTopRows(in: contents.rows)
        }
        return converted
    }

    private func saveNote() {
        guard !query.isEmpty else { return }
        store.addNote(query)
        // Stay open on the fresh initial screen: the new note landing at the
        // top of the notes column is the save confirmation, and the next
        // capture can start without re-summoning the panel.
        text = ""
        fieldFocused = true
    }

    private func startEdit() {
        hoverState.dropHighlight()
        // The editor writes back into content, which for an image is a
        // derived placeholder — the context menu hides Edit for them, and
        // the Cmd+E path must refuse the same way.
        guard let selectedItem, !selectedItem.isImage else { return }
        onEdit(selectedItem)
    }

    private func togglePin() {
        guard let selectedItem else { return }
        store.togglePin(selectedItem)
    }

    /// Deletes the whole ⌘-collected handful in one write.
    private func deleteStack() {
        let doomed = stack.ids.compactMap { id in store.items.first { $0.id == id } }
        store.delete(doomed)
        stack.clear()
    }

    /// Restores the last delete, if `Store` is still holding it. Nothing
    /// happens once its window has passed — the key is silent rather than
    /// wrong, because an alert about a delete the user has stopped thinking
    /// about is worse than no answer.
    private func undoDelete() {
        guard store.undoDelete() else { return }
        hoverState.dropHighlight()
    }

    private func deleteSelected() {
        guard let target = actionTarget else { return }

        // Read the neighbour off the rows as they still stand: the delete
        // below is what makes "the one under it" unanswerable. The focused
        // pane is where the target is by construction — hover focuses what it
        // lights, and the keyboard selection is the focused pane's own.
        selection.deleteAdjusting(target.id, in: selection.pane, rows: contents.rows)

        store.delete(target)
        hoverState.dropHighlight()
    }

    private func reset() {
        linkCollection = LinkCollection.current
        showsNotes = NotesVisibility.isEnabled
        split.settle(at: NotesFraction.current)
        text = Self.debugQuery
        // No hover arbitration here: resetHover() below forgets the pointer
        // outright, anchor and pending entry included, which is strictly more
        // than either of the two the list callers pick between.
        dismissDetail()
        recomputeLists()
        openTick += 1
        resetHover()
        showsShortcuts = false
        stack.clear()
        #if DEBUG
        if let count = DebugLaunch.stackCount {
            stack.seed(text: contents.clips.filter { !$0.isImage }.prefix(count).map(\.id))
        }
        #endif
        selection.reset(to: contents.rows)
        fieldFocused = true
    }
}
