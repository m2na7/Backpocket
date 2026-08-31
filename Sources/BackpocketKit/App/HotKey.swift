import AppKit
import Carbon.HIToolbox
import OSLog

/// Wrapper around Carbon's RegisterEventHotKey.
/// An NSEvent global monitor cannot consume events, so the shortcut would
/// leak through to the frontmost app.
///
/// Main-actor isolated: every entry point is called from the app delegate or
/// Settings, and the registration state below is plain mutable statics that
/// would otherwise be shared mutable global state.
@MainActor
enum HotKey {
    /// nonisolated: the Carbon callback is a C function pointer and reads
    /// this to tell our hotkey from any other app's.
    private nonisolated static let signature: OSType = 0x42_4B_50_54  // 'BKPT'
    private static let logger = Logger(subsystem: "dev.m2na.backpocket", category: "hotkey")
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    /// False when Carbon refused the combination — the caller must roll back
    /// to a working shortcut, or the app is left with none.
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        self.action = action
        unregister()
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: signature, id: 1)
        // Carbon fails silently when another app already owns the combination,
        // so without checking the status a conflicting shortcut leaves the app
        // with no hotkey and no trace of why.
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            ref = nil
            logger.error(
                "registration failed (status \(status)): keyCode \(keyCode), modifiers \(modifiers)"
            )
            return false
        }
        return true
    }

    static func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
    }

    /// The handler is installed exactly once — reinstalling on every
    /// registration makes the callback fire multiple times.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                if id.signature == HotKey.signature {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { HotKey.action?() }
                    }
                }
                return noErr
            },
            1, &spec, nil, nil
        )
    }
}
