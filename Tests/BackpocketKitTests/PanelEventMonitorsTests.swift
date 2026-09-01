import AppKit
import Foundation
import Testing

@testable import BackpocketKit

/// The panel's two `NSEvent` monitors. Everything here is about pairing:
/// a monitor added twice handles every event twice, one never removed outlives
/// the view that closed over it, and one that swallowed its event would strand
/// ⌘ for the rest of the app. None of the three is visible where it is caused,
/// and none of them was reachable while registration lived in `@State`.
@MainActor
@Suite("PanelEventMonitors")
struct PanelEventMonitorsTests {
    /// Stands in for AppKit's registration. Tokens are identities and nothing
    /// more, which is exactly what `removeMonitor` treats them as.
    @MainActor
    private final class FakeRegistrar {
        struct Monitor {
            var mask: NSEvent.EventTypeMask
            var token: UUID
            var handler: @MainActor (NSEvent) -> NSEvent?
        }

        private(set) var monitors: [Monitor] = []
        private(set) var removed: [UUID] = []
        /// Registration failing is AppKit's answer when it cannot install a
        /// monitor at all, and the caller only ever sees a nil token.
        var refuses = false

        var registrar: PanelEventMonitors.Registrar {
            PanelEventMonitors.Registrar(
                add: { mask, handler in
                    guard !self.refuses else { return nil }
                    let token = UUID()
                    self.monitors.append(Monitor(mask: mask, token: token, handler: handler))
                    return token
                },
                remove: { token in
                    guard let token = token as? UUID else { return }
                    self.removed.append(token)
                }
            )
        }

        var tokens: [UUID] { monitors.map(\.token) }

        /// Hands an event to every monitor that asked for its type, and gives
        /// back what each returned — nil being the answer that swallows it.
        @discardableResult
        func deliver(_ event: NSEvent) -> [NSEvent?] {
            monitors
                .filter { $0.mask.contains(NSEvent.EventTypeMask(type: event.type) ?? []) }
                .map { $0.handler(event) }
        }
    }

    private func flagsEvent(command: Bool) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: command ? [.command] : [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 55))
    }

    private func pointerEvent(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0))
    }

    @Test func installingTwiceLeavesOnePairOfMonitors() throws {
        let fake = FakeRegistrar()
        let monitors = PanelEventMonitors(registrar: fake.registrar)
        var held: [Bool] = []

        monitors.install(commandHeld: { held.append($0) }, pointerMoved: { _ in })
        // The view's onAppear re-fires when the onboarding branch swaps back
        // in, and a second pair would report every ⌘ twice — which is a paste
        // of the collected handful twice over.
        monitors.install(commandHeld: { held.append($0) }, pointerMoved: { _ in })

        #expect(fake.monitors.count == 2)
        fake.deliver(try flagsEvent(command: true))
        #expect(held == [true])
    }

    @Test func tearingDownRemovesExactlyWhatWasInstalled() throws {
        let fake = FakeRegistrar()
        let monitors = PanelEventMonitors(registrar: fake.registrar)

        monitors.install(commandHeld: { _ in }, pointerMoved: { _ in })
        let installed = fake.tokens
        #expect(monitors.isInstalled)

        monitors.teardown()

        #expect(fake.removed == installed)
        #expect(!monitors.isInstalled)

        // The view is torn down on paths that never installed, and rebuilt on
        // paths that did: neither may leave a monitor behind or remove one
        // twice.
        monitors.teardown()
        #expect(fake.removed == installed)

        monitors.install(commandHeld: { _ in }, pointerMoved: { _ in })
        #expect(fake.monitors.count == 4)
        #expect(monitors.isInstalled)
    }

    @Test func registrationThatFailedIsNotRememberedAsAMonitor() {
        let fake = FakeRegistrar()
        fake.refuses = true
        let monitors = PanelEventMonitors(registrar: fake.registrar)

        monitors.install(commandHeld: { _ in }, pointerMoved: { _ in })

        // Nothing is running, so nothing is left to remove — and the next
        // install is free to try again rather than guarding against a pair
        // that was never there.
        #expect(!monitors.isInstalled)
        monitors.teardown()
        #expect(fake.removed.isEmpty)
    }

    @Test func theCommandWatchReportsWhetherTheKeyIsDown() throws {
        let fake = FakeRegistrar()
        let monitors = PanelEventMonitors(registrar: fake.registrar)
        var held: [Bool] = []

        monitors.install(commandHeld: { held.append($0) }, pointerMoved: { _ in })
        fake.deliver(try flagsEvent(command: true))
        fake.deliver(try flagsEvent(command: false))

        // Down lights the ⌘1..9 numbers; up is what commits a collected
        // handful, so the release has to arrive as its own report.
        #expect(held == [true, false])
    }

    @Test func everyWatchedEventIsPassedOnUntouched() throws {
        let fake = FakeRegistrar()
        let monitors = PanelEventMonitors(registrar: fake.registrar)

        monitors.install(commandHeld: { _ in }, pointerMoved: { _ in })

        // A local monitor returning nil eats the event. The panel is watching
        // these, not claiming them: swallowing ⌘ would take every other
        // shortcut in the app down with it.
        let flags = try flagsEvent(command: true)
        #expect(fake.deliver(flags) == [flags])
        let moved = try pointerEvent(.mouseMoved, at: NSPoint(x: 1, y: 2))
        #expect(fake.deliver(moved) == [moved])
    }

    @Test func thePointerWatchReportsTheScreenPositionNotTheEventsOwn() throws {
        let fake = FakeRegistrar()
        let onScreen = NSPoint(x: 640, y: 480)
        let monitors = PanelEventMonitors(registrar: fake.registrar, pointerLocation: { onScreen })
        var travel: [NSPoint] = []

        monitors.install(commandHeld: { _ in }, pointerMoved: { travel.append($0) })
        // A dragged event carries a window-relative location, and the hold is
        // judged against an anchor in screen coordinates: mixing the two
        // measures the travel from the wrong origin and lifts the hold on a
        // pointer that never moved.
        fake.deliver(try pointerEvent(.mouseMoved, at: NSPoint(x: 12, y: 12)))
        // Dragging counts as travel too — a drag is the pointer moving with a
        // button down, and the highlight has to follow it.
        fake.deliver(try pointerEvent(.leftMouseDragged, at: NSPoint(x: 90, y: 90)))

        #expect(travel == [onScreen, onScreen])
    }

    @Test func theTwoWatchesDoNotHearEachOthersEvents() throws {
        let fake = FakeRegistrar()
        let monitors = PanelEventMonitors(registrar: fake.registrar)
        var held: [Bool] = []
        var travel: [NSPoint] = []

        monitors.install(commandHeld: { held.append($0) }, pointerMoved: { travel.append($0) })
        fake.deliver(try flagsEvent(command: true))

        #expect(held.count == 1)
        #expect(travel.isEmpty)
    }
}
