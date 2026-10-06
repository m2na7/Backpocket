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

        #if DEBUG
        if let stage = DebugLaunch.transferProbe {
            guard Self.isTransferBundle(Bundle.main.bundleIdentifier) else {
                NSApp.terminate(nil)
                return
            }
            Task { await DebugTransferProbe.run(stage: stage) }
            return
        }
        #endif

        // Transfer bundles must never fall through to normal startup,
        // including when launched without probe flags or built in release.
        // Otherwise a leftover test app can register the user's shortcut.
        if Self.isTransferBundle(Bundle.main.bundleIdentifier) {
            NSApp.terminate(nil)
            return
        }

        #if DEBUG
        // Before any window exists, so every one of them draws in it.
        if let look = DebugLaunch.appearance {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        #endif

        // Read before anything can rewrite it: the bundle's localization is
        // fixed by now, and Settings compares against this to decide whether
        // a relaunch is actually pending.
        _ = AppLanguage.atLaunch

        // Not `mainContext`: its main-actor assertion traps when first touched
        // from `applicationDidFinishLaunching`. A context made by hand works,
        // and Store is @MainActor so access stays single-threaded anyway.
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
        if !isCaptureRun {
            watcher.start()
        }

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

        if !isCaptureRun {
            applyHotKey()

            if PasteBehavior.isAutomatic, !Paster.isTrusted {
                Paster.requestAccessibility()
            }
        }

        #if DEBUG
        Task { await applyDebugLaunchOptions() }
        #endif
    }

    static func isTransferBundle(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return ["dev.m2na.backpocket.transfer-source", "dev.m2na.backpocket.transfer-sandbox"]
            .contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
    }

    /// See `DebugLaunch.isCapture`. Always false in a release build.
    private var isCaptureRun: Bool {
        #if DEBUG
        DebugLaunch.isCapture
        #else
        false
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
        // Which representation leaves the app is decided by PasteFlavor,
        // where it can be tested; the switch below only carries out the
        // answer. Asked before anything else, so that an image with nothing
        // left to paste leaves the panel as it was instead of closing it over
        // a paste that never comes.
        guard let flavor = PasteFlavor.flavor(for: item) else { return }
        store?.markUsed(item)
        // Order matters: the panel must close first so the previous app is
        // frontmost again and receives the paste.
        panel?.hide()
        watcher.suppressingOwnWrite {
            switch flavor {
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
            await DemoSeed.seed(into: store, language: DebugLaunch.demoLanguage)
        }
        if let note = DebugLaunch.extraNote {
            store?.addNote(note)
        }
        if let text = DebugLaunch.adoptText {
            store?.adoptAsNote(text)
        }

        // --snapshot= implies a panel to capture. Without this it fell under
        // the guard and the process sat there forever, having written no PNG
        // and reported nothing — and CONTRIBUTING lists the two flags as
        // independent, so passing --snapshot= alone is the documented usage.
        guard
            DebugLaunch.openPanel || DebugLaunch.snapshotPath != nil
                || DebugLaunch.snapshotDirectory != nil
        else { return }

        panel?.autoHidesOnResignKey = false
        togglePanel()

        // Pin to the top-left corner so a capture of that region never
        // includes anything else on screen.
        if let screen = NSScreen.main {
            panel?.setFrameTopLeftPoint(NSPoint(x: 40, y: screen.frame.maxY - 40))
        }
        if DebugLaunch.query != nil {
            // Focusing a filled field selects all of it. A capture of typing
            // should show the caret after the text instead, the way it sits
            // while someone is still typing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if let editor = self?.panel?.firstResponder as? NSTextView {
                    let end = (editor.string as NSString).length
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
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
        if let directory = DebugLaunch.snapshotDirectory {
            snapshotWindows(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
    }

    /// Every window the flags opened, each drawn to its own PNG, with the
    /// frames that place them relative to one another in frames.json. A store
    /// picture composes them itself: the detail card and the editor are
    /// windows beside the panel, and one capture of the panel leaves them out.
    /// Later than `snapshotPanel`, so a selected row's card has had its dwell.
    private func snapshotWindows(to directory: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            defer { NSApplication.shared.terminate(nil) }
            guard let self else { return }
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            var frames: [[String: Any]] = []
            for window in NSApplication.shared.windows where window.isVisible {
                let role: String
                if window === panel {
                    role = "panel"
                } else if window is EditPanel {
                    role = "editor"
                } else if window.contentViewController is NSTabViewController {
                    role = "settings"
                } else if window is NSPanel, window.ignoresMouseEvents {
                    role = "detail"
                } else {
                    continue
                }
                guard let view = window.contentView, let bitmap = captureBitmap(of: view)
                else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "\(role).png"))
                frames.append([
                    "role": role,
                    "x": window.frame.minX, "y": window.frame.minY,
                    "width": window.frame.width, "height": window.frame.height,
                    "scale": window.backingScaleFactor,
                ])
            }
            if let json = try? JSONSerialization.data(
                withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
            {
                try? json.write(to: directory.appending(path: "frames.json"))
            }
        }
    }

    /// A bitmap at the window's own scale, or at `--snapshot-scale=` when a
    /// store picture needs the interface larger than a Retina screen draws it.
    private func captureBitmap(of view: NSView) -> NSBitmapImageRep? {
        guard let scale = DebugLaunch.snapshotScale else {
            return view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        bitmap?.size = view.bounds.size
        return bitmap
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
