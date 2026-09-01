import AppKit
import SwiftData
import SwiftUI

/// Application entry point. The executable target calls `BackpocketApp.main()`;
/// everything else lives in BackpocketKit so it can be tested.
public struct BackpocketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Owned by the scene rather than the delegate so the menu item can
    /// disable itself while a check is already running.
    @StateObject private var updater = Updater()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            Button("menu.open") {
                AppDelegate.shared?.togglePanel()
            }
            Button("menu.settings") {
                AppDelegate.shared?.openSettings()
            }
            // Absent in the App Store build, where Apple ships the updates.
            if Updater.isAvailable {
                Button("menu.checkForUpdates") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheck)
            }
            Divider()
            Button("menu.quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Backpocket")
        }
    }
}

/// Composition root. Owns the store, the clipboard watcher, and every window,
/// and wires them together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private let watcher = ClipboardWatcher()
    private let settingsWindow = SettingsWindow()
    private let detailPanel = DetailPanel()
    private lazy var editPanel = EditPanel()
    private var store: Store?
    private var panel: BackpocketPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Not `mainContext`: its main-actor assertion traps when first touched
        // from `applicationDidFinishLaunching`. A context made by hand works,
        // and Store is @MainActor so access stays single-threaded anyway.
        // Read before anything can rewrite it: the bundle's localization is
        // fixed by now, and Settings compares against this to decide whether
        // a relaunch is actually pending.
        _ = AppLanguage.atLaunch

        let store = Store(context: ModelContext(Persistence.makeContainer()))
        store.purgeExpired(days: ExpiryOption.current)
        self.store = store

        watcher.onCopy = { content, source in
            switch content {
            case .text(let string, let html, let rtf):
                store.add(string, source: source, html: html, rtf: rtf)
            case .image(let data):
                store.addImage(data, source: source)
            }
        }
        watcher.start()

        panel = BackpocketPanel(
            rootView: ContentView(
                store: store,
                onPaste: { [weak self] item in self?.paste(item) },
                onClose: { [weak self] in self?.panel?.hide() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onDetail: { [weak self] item, anchored in
                    self?.showDetail(item, anchored: anchored)
                },
                onEdit: { [weak self] item in self?.edit(item) },
                onPasteMarkdown: { [weak self] item in self?.pasteMarkdown(item) },
                onOpenLink: { [weak self] item in self?.openLink(item) },
                onPasteStack: { [weak self] items in self?.pasteStack(items) }
            )
        )
        panel?.onDismissDetail = { [weak self] in
            self?.detailPanel.hide()
        }

        applyHotKey()

        if PasteBehavior.isAutomatic, !Paster.isTrusted {
            Paster.requestAccessibility()
        }

        #if DEBUG
        Task { await applyDebugLaunchOptions() }
        #endif
    }

    /// False when Carbon refused the persisted combination. An app with no
    /// global shortcut looks exactly like one whose shortcut works, so
    /// Settings reads this to say otherwise.
    private(set) var isHotKeyActive = false

    @discardableResult
    func applyHotKey() -> Bool {
        let binding = HotKeyBinding.current
        isHotKeyActive = HotKey.register(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers
        ) { [weak self] in
            self?.togglePanel()
        }
        return isHotKeyActive
    }

    /// Carbon consumes the registered combination before any local monitor
    /// sees it, so the recorder in Settings has to tear the shortcut down for
    /// the duration — otherwise the current hotkey is the one combination
    /// that can never be re-recorded.
    func suspendHotKey() {
        HotKey.unregister()
        isHotKeyActive = false
    }

    /// The hotkey operations handed to Settings, so no view in there has to
    /// know this class exists. Weakly captured — the delegate outlives the
    /// window it opens, and if that ever stopped being true a Settings window
    /// with nothing behind it should report the shortcut as fine rather than
    /// blame the user's combination for an app that is gone.
    private var hotKeyControl: HotKeyControl {
        HotKeyControl(
            isActive: { [weak self] in self?.isHotKeyActive ?? true },
            suspend: { [weak self] in self?.suspendHotKey() },
            apply: { [weak self] in self?.applyHotKey() ?? false }
        )
    }

    func togglePanel() {
        // A menu-bar app can run for weeks, so neither expiry nor the history
        // cap can rely on launch alone.
        store?.purgeExpired(days: ExpiryOption.current)
        store?.trimOverflow()
        panel?.toggle()
    }

    func openSettings() {
        guard let store else { return }
        panel?.hide()
        settingsWindow.show(store: store, hotKeyControl: hotKeyControl)
    }

    private func edit(_ item: Item) {
        // Images cannot be edited — their content is a derived placeholder.
        guard let panel, !item.isImage else { return }

        detailPanel.hide()
        // The editor takes key focus, which would make the main panel close
        // itself. Suspend auto-hide until editing ends — and stop the panel
        // behind from reacting to the pointer: rows kept hovering (and
        // spawning preview cards) underneath the editor.
        panel.autoHidesOnResignKey = false
        panel.ignoresMouseEvents = true

        editPanel.onDismiss = { [weak self] reason in
            guard let self, let panel = self.panel else { return }
            panel.autoHidesOnResignKey = true
            panel.ignoresMouseEvents = false
            guard panel.isVisible else { return }

            switch reason {
            case .explicit:
                panel.makeKeyAndOrderFront(nil)
            case .focusLost:
                // Focus went somewhere on its own: to the main panel (the
                // user clicked it — it becomes key by itself) or to another
                // app. Re-keying here would shove the panel over whatever
                // the user just switched to; key status settles a beat later.
                DispatchQueue.main.async {
                    if NSApp.keyWindow !== panel {
                        panel.hide()
                    }
                }
            }
        }

        // What these do with a refused write is decided by EditorActions, where
        // it can be tested; this only says which collaborator is which.
        let actions = EditorActions(
            save: { [weak self] text in self?.store?.update(item, content: text) ?? false },
            paste: { [weak self] in self?.paste(item) },
            hasStorageFailure: { [weak self] in self?.store?.hasStorageFailure == true }
        )

        editPanel.show(
            item: item,
            over: panel,
            onSave: actions.save,
            onSaveAndPaste: actions.saveAndPaste,
            onDelete: { [weak self] in
                self?.store?.delete(item)
            },
            failureMessage: actions.failureMessage
        )
    }

    private func showDetail(_ item: Item?, anchored: Bool) {
        // While the editor is up the card stays down — a dwell task racing
        // the editor's appearance could otherwise pop one over it.
        guard !editPanel.isVisible else {
            detailPanel.hide()
            return
        }
        guard let item, let panel, panel.isVisible else {
            // The pointer may be traveling toward the card; decide by position.
            detailPanel.hideUnlessPointerInside()
            return
        }
        detailPanel.show(item: item, near: panel, anchored: anchored)
    }

    /// Converts the stored HTML flavor on demand; falls back to the plain
    /// text when there is none or the fragment does not parse.
    private func pasteMarkdown(_ item: Item) {
        guard
            let html = item.contentHTML,
            let markdown = HTMLToMarkdown.convert(html)
        else {
            paste(item)
            return
        }

        store?.markUsed(item)
        panel?.hide()
        watcher.suppressingOwnWrite {
            Paster.paste(markdown)
        }
    }

    /// Opening counts as using: the item is promoted like a paste, but the
    /// pasteboard is untouched — the URL goes to the default browser instead.
    private func openLink(_ item: Item) {
        guard let url = item.linkURL else { return }
        store?.markUsed(item)
        panel?.hide()
        NSWorkspace.shared.open(url)
    }

    /// Pastes a ⌘D-collected handful as one insertion. What goes in and what
    /// counts as used is decided by `PasteStack.insertion`, where it can be
    /// tested; this carries out the answer.
    private func pasteStack(_ items: [Item]) {
        guard let insertion = PasteStack.insertion(for: items) else { return }
        insertion.used.forEach { store?.markUsed($0) }
        panel?.hide()
        watcher.suppressingOwnWrite {
            Paster.paste(insertion.text)
        }
    }

    private func paste(_ item: Item) {
        store?.markUsed(item)
        // Order matters: the panel must close first so the previous app is
        // frontmost again and receives the paste.
        panel?.hide()
        watcher.suppressingOwnWrite {
            // Which representation leaves the app is decided by PasteFlavor,
            // where it can be tested; this switch only carries out the answer.
            switch PasteFlavor.flavor(for: item) {
            case .image(let data):
                Paster.pasteImage(data)
            case .files(let urls):
                Paster.pasteFiles(urls)
            case .text(let text, let html, let rtf):
                Paster.paste(text, html: html, rtf: rtf)
            }
        }
    }

    #if DEBUG
    /// Drives the UI into a known state for screenshot-based verification.
    /// Synthetic keyboard input needs accessibility permission; launch
    /// arguments do not.
    private func applyDebugLaunchOptions() async {
        // Seeded before the panel opens so the first render — and any
        // snapshot taken of it — already shows the content. Awaited for the
        // same reason: image capture completes off the main actor, and
        // opening the panel first would race the row into view.
        if DebugLaunch.seedDemo, let store, store.items.isEmpty {
            await seedDemo(into: store)
        }

        // --snapshot= implies a panel to capture. Without this it fell under
        // the guard and the process sat there forever, having written no PNG
        // and reported nothing — and CONTRIBUTING lists the two flags as
        // independent, so passing --snapshot= alone is the documented usage.
        guard DebugLaunch.openPanel || DebugLaunch.snapshotPath != nil else { return }

        panel?.autoHidesOnResignKey = false
        togglePanel()

        // Pin to the top-left corner so a capture of that region never
        // includes anything else on screen.
        if let screen = NSScreen.main {
            panel?.setFrameTopLeftPoint(NSPoint(x: 40, y: screen.frame.maxY - 40))
        }
        if DebugLaunch.openEditor, let first = store?.items.first(where: \.isNote) {
            edit(first)
        }
        if DebugLaunch.openSettings {
            openSettings()
        }
        if let path = DebugLaunch.snapshotPath {
            snapshotPanel(to: path)
        }
    }

    /// Fills an empty store with content that shows the product off: real
    /// source apps so icons resolve, varied content kinds, one pin, one image.
    private func seedDemo(into store: Store) async {
        let chrome = CopySource(name: "Google Chrome", bundleID: "com.google.Chrome")
        let cursor = CopySource(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        let code = CopySource(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        let terminal = CopySource(name: "Terminal", bundleID: "com.apple.Terminal")
        let slack = CopySource(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let figma = CopySource(name: "Figma", bundleID: "com.figma.Desktop")
        let notion = CopySource(name: "Notion", bundleID: "notion.id")

        // Oldest first: every add lands at the front, so the last call ends
        // up at the top of the list.
        store.addNote("First sketch — clipboard history and notes in one panel")
        store.addNote("Design review Thu 2pm — bring the empty-state options")
        store.add("https://react.dev/reference/react/useSyncExternalStore", source: chrome)
        store.add("#2F81F7", source: figma)
        store.add(
            """
            type Result<T, E = Error> =
              | { ok: true; value: T }
              | { ok: false; error: E }
            """,
            source: cursor
        )
        store.add("https://www.typescriptlang.org/docs/handbook/2/generics.html", source: chrome)
        store.addNote("Standup 10:30 — demo the panel, collect feedback")
        store.add("pnpm dlx shadcn@latest add dialog", source: terminal)
        store.add(
            """
            export function useDebounced<T>(value: T, delay = 300): T {
              const [debounced, setDebounced] = useState(value)
              useEffect(() => {
                const id = setTimeout(() => setDebounced(value), delay)
                return () => clearTimeout(id)
              }, [value, delay])
              return debounced
            }
            """,
            source: cursor
        )
        store.add("https://github.com/m2na7/Backpocket/pull/12", source: chrome)
        store.add(
            "{\"name\": \"backpocket\", \"version\": \"1.4.0\", \"channels\": [\"beta\", \"stable\"]}",
            source: code
        )
        store.addNote("Ask design about the empty state — it reads too quiet")
        store.add("git rebase -i origin/main --autosquash", source: terminal)
        store.add(
            "Can you take the flaky test in CI? It fails ~1 in 5 on the runner.",
            source: slack
        )
        store.add("https://news.ycombinator.com/item?id=41802570", source: chrome)
        store.add(
            """
            const Panel = forwardRef<HTMLDivElement, PanelProps>(
              ({ items, onSelect }, ref) => (
                <div ref={ref} role="listbox">
                  {items.map((item) => (
                    <Row key={item.id} item={item} onSelect={onSelect} />
                  ))}
                </div>
              )
            )
            """,
            source: cursor
        )
        store.addNote("Release notes draft: image clips, faster search, new hotkey")
        store.add("https://vercel.com/docs/functions/streaming", source: chrome)
        store.add(
            """
            ## Panel keyboard
            - `Enter` pastes the selected clip
            - `Cmd+Enter` pastes a note
            """,
            source: notion
        )
        store.add("npm error ERESOLVE could not resolve peer react@^19.0.0", source: terminal)
        store.addNote("Ship 0.2 before the conference — cut scope if it slips")
        store.add(
            "The best interface is the one you never notice — it simply keeps up.",
            source: chrome
        )
        if let png = Self.demoGradientPNG() {
            store.addImage(png, source: figma)
            // Image capture hashes and thumbnails off the main actor, so the
            // row is not in `items` yet. Without this wait the spread below
            // skips it and the demo image alone reads "now" — which makes the
            // screenshots this flag exists for unreproducible.
            await store.imageCapturesDidFinish()
        }

        for prefix in ["git rebase", "#2F81F7"] {
            if let pinned = store.items.first(where: { $0.content.hasPrefix(prefix) }) {
                store.togglePin(pinned)
            }
        }

        // Every add stamped usedAt with "now". Clips and notes are spread
        // differently on purpose: clips expire (default seven days) and would
        // be purged out of the demo before it could be filmed, while notes
        // never expire and are what the notes column groups into Today, Last
        // 7 Days, months and years. So the deep past belongs to the notes and
        // the clips stay inside the retention window.
        //
        // Store keeps `items` sorted by usedAt descending, so both passes
        // assign strictly descending dates within their own kind.
        var clipDate = Date().addingTimeInterval(-120)
        var clipGap: TimeInterval = 900
        var noteAge: [TimeInterval] = [
            60 * 30,
            3600 * 26,
            86400 * 4,
            86400 * 26,
            86400 * 200,
            86400 * 400,
        ]
        for item in store.items {
            if item.isNote {
                let age = noteAge.isEmpty ? 86400 * 500 : noteAge.removeFirst()
                item.usedAt = Date().addingTimeInterval(-age)
            } else {
                item.usedAt = clipDate
                clipDate -= clipGap
                // Widening, but capped well inside the seven-day default so
                // nothing in the demo is eligible for expiry.
                clipGap = min(clipGap * 1.6, 86400 * 0.9)
            }
            item.createdAt = item.usedAt
        }
        store.persistDemoSeed()
    }

    /// 640×400 gradient rendered with CoreGraphics — generated at runtime so
    /// no image asset ships in the bundle for a debug-only feature.
    private static func demoGradientPNG() -> Data? {
        let width = 640, height = 400
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(red: 0.30, green: 0.41, blue: 0.95, alpha: 1),
                    CGColor(red: 0.89, green: 0.37, blue: 0.62, alpha: 1),
                ] as CFArray,
                locations: nil
            )
        else { return nil }

        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: []
        )

        return context.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        }
    }

    /// Whichever window the other debug flags opened.
    ///
    /// `--edit` and `--settings` open windows of their own, and capturing the
    /// main panel regardless made both produce a byte-identical PNG of the
    /// panel — while CONTRIBUTING and the PR template ask for exactly those
    /// two captures. A contributor changing the editor or Settings attached a
    /// picture of the thing they had not changed, and neither they nor the
    /// reviewer could tell.
    private var snapshotTarget: NSView? {
        // Settings first: it is the only window here that activates, so when
        // both flags are set it is the one on screen.
        if DebugLaunch.openSettings {
            let settings = NSApplication.shared.windows.first {
                $0.contentViewController is NSTabViewController
            }
            // The frame view, not the content view: Settings puts its tab
            // strip in the toolbar, so a capture of the content alone cannot
            // tell a reviewer which pane they are looking at.
            if let view = settings?.contentView?.superview ?? settings?.contentView {
                return view
            }
        }
        // Found among the app's windows rather than through `editPanel`,
        // which is presented as a child window: how it was attached should
        // not decide whether a capture can find it.
        if DebugLaunch.openEditor {
            let editor = NSApplication.shared.windows.first { $0 is EditPanel }
            if let view = editor?.contentView { return view }
        }
        return panel?.contentView
    }

    /// Draws the target window's view hierarchy into a PNG via `cacheDisplay`,
    /// which renders offscreen — screenshots work even with the lid closed.
    private func snapshotPanel(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            defer { NSApplication.shared.terminate(nil) }
            guard
                let view = self?.snapshotTarget,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }

            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}
