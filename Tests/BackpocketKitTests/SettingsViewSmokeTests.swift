import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import BackpocketKit

/// Smoke tests for the views outside the panel's lists: the preference panes,
/// the note editor, and the onboarding screen. See `ViewSmokeHarness` for what
/// a render here does and does not prove.
@MainActor
@Suite
struct SettingsViewSmokeTests {
    /// The width the Settings window gives every pane. Each pane is free to
    /// ask for whatever height it needs, so only the width is fixed.
    private static let paneWidth: CGFloat = 500

    /// Nothing below activates a control, so the three operations only have to
    /// exist. Registering a real Carbon hotkey from a test would reach outside
    /// the process.
    private var inertHotKeyControl: HotKeyControl {
        HotKeyControl(isActive: { true }, suspend: {}, apply: { true })
    }

    /// Preference reads that reach the process-wide defaults are pointed at a
    /// scratch store; the panes' own `@AppStorage` bindings read
    /// `UserDefaults.standard` directly, which a render only ever reads.
    private func withPaneDefaults(
        discriminator: String = "",
        fileID: String = #fileID,
        line: Int = #line,
        _ body: () throws -> Void
    ) throws {
        try withScratchPreferences(discriminator: discriminator, fileID: fileID, line: line) { _ in
            try body()
        }
    }

    private func renderPane(_ view: some View, named name: String) throws {
        // Height comes from the pane; the window animates to it, so a pane
        // that measured to nothing would open as a sliver.
        let rendered = try OffscreenRender.run(view)
        #expect(rendered.fittingSize.height > 20, "\(name): collapsed to \(rendered.fittingSize)")

        try expectRenders(
            view.frame(width: Self.paneWidth), named: name,
            at: NSSize(width: Self.paneWidth, height: max(rendered.fittingSize.height, 40)))
    }

    @Test func thegeneralPaneRenders() throws {
        try withPaneDefaults {
            try renderPane(GeneralPane(), named: "general pane")
        }
    }

    @Test func thehistoryPaneRenders() throws {
        try withPaneDefaults {
            try renderPane(HistoryPane(), named: "history pane")
        }
    }

    @Test func theshortcutsPaneRenders() throws {
        try withPaneDefaults {
            try renderPane(
                ShortcutsPane(hotKeyControl: inertHotKeyControl), named: "shortcuts pane")
        }
    }

    /// Empty and populated both: the list box draws a placeholder when no app
    /// is ignored, and rows when some are.
    @Test func theignorePaneRenders() throws {
        try withPaneDefaults(discriminator: "empty") {
            try renderPane(IgnorePane(), named: "ignore pane, empty")
        }
        try withPaneDefaults(discriminator: "filled") {
            IgnoredApps.bundleIDs = ["com.apple.Safari", "com.apple.dt.Xcode"]
            try renderPane(IgnorePane(), named: "ignore pane, filled")
        }
    }

    /// The data pane is the one that reads the store, and the one that has
    /// something different to say when the store cannot write.
    @Test func thedataPaneRenders() throws {
        let fixture = try ViewFixture()
        try fixture.fill()
        try withPaneDefaults {
            try renderPane(
                DataPane(store: fixture.store, hotKeyControl: inertHotKeyControl),
                named: "data pane")
        }
    }

    // MARK: The note editor

    /// The editor's frame is fixed by the panel that hosts it.
    private static let editorFrame = NSSize(width: 520, height: 320)

    @Test func thenoteEditorRenders() throws {
        let fixture = try ViewFixture()

        let note = fixture.addNote("a note with a couple of sentences in it. And a second one.")
        try expectRenders(
            EditPanel.viewForTesting(item: note), named: "editing a note",
            at: Self.editorFrame)

        // A clip carries a source app where a note carries its own title, and
        // the header reads whichever it is.
        let clip = fixture.addText("a clipboard capture opened in the editor")
        try expectRenders(
            EditPanel.viewForTesting(item: clip), named: "editing a clip",
            at: Self.editorFrame)

        // The refusal banner is a whole extra row in the footer, and it only
        // ever appears after something has already gone wrong — which is a
        // poor moment for a layout to be untested.
        try expectRenders(
            EditPanel.viewForTesting(item: note, refused: true), named: "editor refusing",
            at: Self.editorFrame)

        let empty = fixture.addNote("")
        try expectRenders(
            EditPanel.viewForTesting(item: empty), named: "editing an empty note",
            at: Self.editorFrame)

        let long = fixture.addNote(String(repeating: "a long paragraph that wraps. ", count: 200))
        try expectRenders(
            EditPanel.viewForTesting(item: long), named: "editing a long note",
            at: Self.editorFrame)
    }

    // MARK: Onboarding

    /// Rendered directly rather than through the panel: which branch the panel
    /// takes depends on whether this machine has granted the accessibility
    /// permission, and a test must not ask that question.
    @Test func theonboardingScreenRenders() throws {
        try expectRenders(
            Onboarding(tick: 0, onRecheck: {}), named: "onboarding",
            at: NSSize(width: 680, height: 360))
    }
}
