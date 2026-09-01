import AppKit

/// The panel's two AppKit event monitors: the ⌘ watch that lights the row
/// numbers and commits a collected handful on release, and the pointer-travel
/// watch that lifts the keyboard's hold on the highlight.
///
/// Both facts have to come from `NSEvent` — SwiftUI's `onModifierKeysChanged`
/// needs macOS 15, which the deployment target does not, and pointer movement
/// with no row underneath it is not something the view hierarchy reports at
/// all. What that leaves is registration, which goes wrong invisibly: a
/// monitor added twice handles every event twice, and one never removed keeps
/// a dead closure on the run loop for the rest of the session. Neither shows
/// up where it was caused. Owning the pair here makes those rules something a
/// test can install, deliver into, and tear down.
@MainActor
final class PanelEventMonitors {
    /// AppKit's monitor registration, injected. A real local monitor needs a
    /// running app, a key window and a pointer that physically moves; the
    /// rules worth checking — install once, remove exactly what was added,
    /// pass every event on — need none of the three.
    struct Registrar {
        var add:
            @MainActor (NSEvent.EventTypeMask, @escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
        var remove: @MainActor (Any) -> Void

        static let appKit = Registrar(
            add: { mask, handler in
                NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
            },
            remove: { NSEvent.removeMonitor($0) }
        )
    }

    private let registrar: Registrar
    private let pointerLocation: @MainActor () -> NSPoint
    /// What `remove` needs back, and the only record that anything is
    /// running: the two monitors are installed and torn down together, so
    /// there is nothing to tell them apart by.
    private var tokens: [Any] = []

    var isInstalled: Bool { !tokens.isEmpty }

    /// The pointer is read from the screen rather than from the event: a
    /// dragged event carries a window-relative location, and the hold is
    /// judged against an anchor in screen coordinates.
    init(
        registrar: Registrar = .appKit,
        pointerLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    ) {
        self.registrar = registrar
        self.pointerLocation = pointerLocation
    }

    /// Starts both monitors, or does nothing when they are already running.
    /// The view's `onAppear` re-fires when the onboarding branch swaps back
    /// in, and a second pair would double-handle every event.
    func install(
        commandHeld: @escaping @MainActor (Bool) -> Void,
        pointerMoved: @escaping @MainActor (NSPoint) -> Void
    ) {
        guard tokens.isEmpty else { return }

        add(.flagsChanged) { event in
            commandHeld(event.modifierFlags.contains(.command))
        }
        // Requires the panel to accept mouse-moved events, which
        // `BackpocketPanel` sets.
        add([.mouseMoved, .leftMouseDragged]) { _ in
            pointerMoved(self.pointerLocation())
        }
    }

    /// Stops both. Safe to call having never installed, and again after: the
    /// view is torn down on paths that never ran `onAppear`.
    func teardown() {
        for token in tokens {
            registrar.remove(token)
        }
        tokens = []
    }

    private func add(
        _ mask: NSEvent.EventTypeMask, _ handle: @escaping @MainActor (NSEvent) -> Void
    ) {
        let token = registrar.add(mask) { event in
            handle(event)
            // The panel watches these events, it does not claim them:
            // returning nil from a local monitor swallows the event, and
            // swallowing ⌘ would strand every other shortcut in the app.
            return event
        }
        guard let token else { return }
        tokens.append(token)
    }
}
