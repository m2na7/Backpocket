import AppKit
import SwiftUI

/// System Settings-style preferences: toolbar tabs, and the window animates
/// to each pane's natural size. NSTabViewController's `.toolbar` style
/// provides the whole pattern natively.
///
/// Unlike the panels, this is a real window that must activate normally —
/// in a menu-bar-only app (LSUIElement) it would otherwise open behind
/// other windows or never receive focus.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    func show(store: Store, hotKeyControl: HotKeyControl) {
        if let window {
            bringToFront(window)
            return
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        tabs.addTabViewItem(
            pane(
                "settings.tab.general", symbol: "gearshape", view: GeneralPane()
            ))
        tabs.addTabViewItem(
            pane(
                "settings.tab.history", symbol: "doc.on.clipboard", view: HistoryPane()
            ))
        tabs.addTabViewItem(
            pane(
                "settings.tab.shortcuts", symbol: "keyboard",
                view: ShortcutsPane(hotKeyControl: hotKeyControl)
            ))
        tabs.addTabViewItem(
            pane(
                "settings.tab.ignore", symbol: "hand.raised", view: IgnorePane()
            ))
        tabs.addTabViewItem(
            pane(
                "settings.section.data", symbol: "externaldrive",
                view: DataPane(store: store, hotKeyControl: hotKeyControl)
            ))

        let created = NSWindow(contentViewController: tabs)
        created.styleMask = [.titled, .closable]
        created.title = String(localized: "settings.title")
        created.isReleasedWhenClosed = false
        created.center()
        // Rebuilding on every open would otherwise forget where the window was.
        created.setFrameAutosaveName("SettingsWindow")

        // Each pane snapshots preferences when it mounts, and a cached window
        // never remounts them: reopening Settings after "Reset everything"
        // would list the wiped apps and the pre-reset shortcuts, and writing
        // one of those rows back would undo the reset. Letting the window go
        // on close is what makes reopening a fresh read.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: created,
            queue: .main
        ) { [weak self] _ in
            // queue: .main delivers on the main thread, but the closure type
            // itself is nonisolated.
            MainActor.assumeIsolated { self?.forget() }
        }

        #if DEBUG
        // Screenshot verification only — an ordinary window falls behind
        // other windows when the app is driven from a shell.
        if DebugLaunch.openSettings {
            created.level = .floating
        }
        if let tab = DebugLaunch.settingsTab, tabs.tabViewItems.indices.contains(tab) {
            // The toolbar restores its own last selection when it attaches,
            // so the debug override has to land after that.
            DispatchQueue.main.async {
                tabs.selectedTabViewItemIndex = tab
            }
        }
        #endif

        window = created
        bringToFront(created)
    }

    private func forget() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }

    private func pane(
        _ titleKey: String.LocalizationValue,
        symbol: String,
        view: some View
    ) -> NSTabViewItem {
        let title = String(localized: titleKey)

        let host = NSHostingController(rootView: view)
        // Lets the tab controller animate the window to each pane's size.
        host.sizingOptions = .preferredContentSize
        // The tab controller propagates this as the window title on selection.
        host.title = title

        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func bringToFront(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
