import AppKit
import SwiftUI

/// The main popup panel; never steals focus from the frontmost app.
/// If the active app changed we would lose the paste target, so this must be
/// a nonactivating NSPanel rather than a regular NSWindow.
final class BackpocketPanel: NSPanel {
    /// The panel the SwiftUI body talks back to. There is exactly one, built
    /// at launch; the view hierarchy is handed no other handle on it.
    static weak var frontmost: BackpocketPanel?

    /// Set by the split divider's own hover tracking. Hold-to-move must not
    /// arm there — see handleHoldToMove.
    var pointerOnDivider = false

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Off deliberately: AppKit's background drag claims the mouse before
        // SwiftUI sees it, which swallowed the split divider's own drag. The
        // hold-to-move below covers moving the window, from anywhere.
        isMovableByWindowBackground = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // The content view's mouse-move monitor is what releases the
        // keyboard's hold on hover; without this the window never routes
        // mouse-moved events and the hold could not be lifted.
        acceptsMouseMovedEvents = true

        // Dragging an edge is the whole point of .resizable; the floors keep
        // the two columns and the footer from being crushed into nothing.
        minSize = NSSize(width: PanelSize.minWidth, height: PanelSize.minHeight)
        contentView = NSHostingView(rootView: rootView)
        Self.frontmost = self

        NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismissDetail?() }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Stored at the end of the drag, not per frame: this is what
                // every later open restores, and the row-count default only
                // applies until the user first resizes.
                PanelSize.store(self.frame.size)
            }
        }

        // Close when focus moves to another app. hidesOnDeactivate does not
        // work here because our app never becomes active in the first place.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            // queue: .main delivers on the main thread, but the closure type
            // itself is nonisolated.
            MainActor.assumeIsolated {
                guard self?.autoHidesOnResignKey == true else { return }
                self?.hide()
            }
        }

        holdMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handleHoldToMove(event)
        }
    }

    // MARK: Hold to move

    /// Holding anywhere for a beat starts a window drag; a press that moves
    /// right away stays a content drag, a text selection, or the divider's
    /// own resize.
    ///
    /// The drag goes through performDrag rather than manual tracking: the
    /// text field runs its own mouse-tracking loop that local monitors never
    /// see, so a timer handing off to the window server is the only path
    /// that also covers the field.
    private static let holdDelay: TimeInterval = 0.35
    private static let holdSlop: CGFloat = 4

    private var holdMonitor: Any?
    private var holdTimer: Timer?
    private var pendingDrag: NSEvent?
    private var swallowMouseUp = false

    private func handleHoldToMove(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // performDrag consumes its own mouse-up, so the flag it armed is
            // still set on the next press; clearing it before any early
            // return keeps it from eating an unrelated release later.
            swallowMouseUp = false

            // The outer band is the resize handle now that the panel is
            // .resizable, and this monitor sees the press before AppKit's
            // resize loop does — arming the hold there would slide the window
            // instead of resizing it, mid-drag.
            let point = event.locationInWindow
            let edge: CGFloat = 6
            guard
                point.x > edge, point.x < frame.width - edge,
                point.y > edge, point.y < frame.height - edge
            else { return event }

            // The split divider sits mid-window, so the edge guard above lets
            // it through — and aiming at a line that thin naturally takes a
            // beat, which is exactly what would fire the drag and slide the
            // window mid-resize. Same conflict that took
            // isMovableByWindowBackground out.
            guard !pointerOnDivider else { return event }

            let pressed = NSEvent.mouseLocation
            // Held on the panel rather than captured: the timer's closure is
            // @Sendable and NSEvent is not, and performDrag needs the event
            // itself, not a copy of its fields.
            pendingDrag = event

            holdTimer?.invalidate()
            let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    let mouse = NSEvent.mouseLocation
                    guard
                        let self,
                        let pending = self.pendingDrag,
                        NSEvent.pressedMouseButtons & 1 == 1,
                        abs(mouse.x - pressed.x) <= Self.holdSlop,
                        abs(mouse.y - pressed.y) <= Self.holdSlop
                    else { return }
                    self.swallowMouseUp = true
                    self.onDismissDetail?()
                    self.performDrag(with: pending)
                }
            }
            // .common, or the field's tracking loop starves the timer.
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            return event

        case .leftMouseUp:
            holdTimer?.invalidate()
            pendingDrag = nil
            defer { swallowMouseUp = false }
            // Swallow the release after a move so it cannot land as a click.
            return swallowMouseUp ? nil : event

        default:
            return event
        }
    }

    // Without this, text fields inside the panel cannot receive keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Bumped on every open. Regaining key focus is not opening — the view
    /// watches this to tell a fresh show from the editor handing focus back.
    private(set) var showCount = 0

    func show() {
        showCount += 1

        // The user's own frame wins once they have dragged an edge; until
        // then the height follows the row counts picked in Settings. Sized
        // before positioning so the edge clamping uses the real frame.
        var size =
            PanelSize.stored
            ?? NSSize(
                width: 680,
                height: PanelMetrics.panelHeight(showsLinks: LinkCollection.showsLinks)
            )
        if let visible = targetScreen?.visibleFrame {
            size.width = min(size.width, visible.width - 16)
            size.height = min(size.height, visible.height - 16)
        }
        if frame.size != size {
            setContentSize(size)
        }

        switch PopupPosition.current {
        case .mouse: positionAtCursor()
        case .center: positionAtScreenCenter()
        }
        // Never use NSApp.activate here — it would deactivate the frontmost app.
        makeKeyAndOrderFront(nil)
    }

    /// Tears down the attached detail card. Called whenever the panel moves
    /// out from under it — hiding, resizing, or being dragged — since the
    /// card is placed against a frame that is about to stop being true.
    var onDismissDetail: (() -> Void)?

    /// Disabled only when verifying the panel via screen capture.
    var autoHidesOnResignKey = true

    func hide() {
        // Hiding out from under the pointer skips the divider's exit event,
        // which would otherwise leave hold-to-move disarmed for good.
        pointerOnDivider = false
        orderOut(nil)
        onDismissDetail?()
    }

    /// With multiple displays, everything here follows the screen the user is
    /// currently looking at, not the primary one.
    private var targetScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func positionAtScreenCenter() {
        guard let visible = targetScreen?.visibleFrame else { return }

        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
        )
    }

    /// Places the panel just below the pointer, on the screen the pointer is
    /// on, clamped at the edges so it never lands off-screen.
    private func positionAtCursor() {
        let mouse = NSEvent.mouseLocation
        guard let visible = targetScreen?.visibleFrame else { return }

        let margin: CGFloat = 8
        // Screen coordinates have a bottom-left origin, so aligning the
        // panel's top edge to the pointer means subtracting the height.
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - frame.height + 20)
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - frame.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - frame.height - margin)

        setFrameOrigin(origin)
    }
}
