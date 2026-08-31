import SwiftUI
import Testing

@testable import BackpocketKit

/// The editor's write path. Everything here is about a save the store turned
/// down — because the item went away underneath the editor, or because the
/// store cannot write at all — and each rule used to be a closure in the
/// composition root with nothing asserting on it.
@MainActor
@Suite("EditorActions")
struct EditorActionsTests {
    /// Records what the editor asked for, standing in for a store and a
    /// pasteboard.
    private final class Recorder {
        var saved: [String] = []
        var pastes = 0
        var saveSucceeds = true
        var storageIsBroken = false

        var actions: EditorActions {
            EditorActions(
                save: { text in
                    self.saved.append(text)
                    return self.saveSucceeds
                },
                paste: { self.pastes += 1 },
                hasStorageFailure: { self.storageIsBroken }
            )
        }
    }

    @Test func aRefusedSaveIsNotPasted() {
        // The item was trimmed, expired, or deleted elsewhere while the
        // editor was open. Pasting anyway inserts the text the store still
        // holds while the editor reports the new text as saved.
        let recorder = Recorder()
        recorder.saveSucceeds = false

        #expect(recorder.actions.saveAndPaste("edited") == false)

        #expect(recorder.saved == ["edited"])
        #expect(recorder.pastes == 0)
    }

    @Test func asaveThatLandedIsPastedOnce() {
        let recorder = Recorder()

        #expect(recorder.actions.saveAndPaste("edited"))

        #expect(recorder.saved == ["edited"])
        #expect(recorder.pastes == 1)
    }

    @Test func theRefusalSaysWhichRefusalItWas() {
        // One outcome, two causes, and the editor cannot tell them apart.
        // Telling someone their note is gone when the disk is what failed
        // sends them looking for the wrong thing.
        let recorder = Recorder()

        #expect(recorder.actions.failureMessage() == LocalizedStringKey("edit.gone"))

        recorder.storageIsBroken = true
        #expect(recorder.actions.failureMessage() == LocalizedStringKey("edit.storageFailed"))
    }
}
