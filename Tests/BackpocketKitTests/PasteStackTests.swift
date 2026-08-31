import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// The ⌘D handful. Its badge numbering is what the user reads back to check
/// what they collected, so the ordering and the pruning are the whole contract.
@MainActor
@Suite("PasteStack")
struct PasteStackTests {
    private let container: ModelContainer
    private let ids: [PersistentIdentifier]

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        let context = ModelContext(container)
        ids = (0..<4).map { index in
            let item = Item(content: "row \(index)")
            context.insert(item)
            return item.persistentModelID
        }
    }

    @Test func picksAreBadgedInPickOrderNotListOrder() {
        var stack = PasteStack()
        stack.toggle(ids[2], isText: true)
        stack.toggle(ids[0], isText: true)

        // The badge is the promise about what one Enter will paste, and the
        // paste joins them in pick order — hence an Array and not a Set.
        #expect(stack.number(of: ids[2]) == 1)
        #expect(stack.number(of: ids[0]) == 2)
        #expect(stack.number(of: ids[1]) == nil)
    }

    @Test func togglingAPickOffRenumbersTheOnesBehindIt() {
        var stack = PasteStack()
        for id in ids.prefix(3) { stack.toggle(id, isText: true) }

        stack.toggle(ids[0], isText: true)

        // A gap in the numbering reads as a pick that silently vanished.
        #expect(stack.number(of: ids[1]) == 1)
        #expect(stack.number(of: ids[2]) == 2)
        #expect(stack.count == 2)
    }

    @Test func aHandfulOfImagesAloneHasNothingToPaste() {
        var stack = PasteStack()
        stack.toggle(ids[0], isText: false)
        stack.toggle(ids[1], isText: false)

        // Plain Enter belongs to the handful once it is non-empty, so the
        // footer must not advertise a paste that would insert nothing.
        #expect(!stack.isEmpty)
        #expect(!stack.hasText)

        stack.toggle(ids[2], isText: true)
        #expect(stack.hasText)
    }

    @Test func removingTheOnlyTextPickTakesThePasteHintWithIt() {
        var stack = PasteStack()
        stack.toggle(ids[0], isText: false)
        stack.toggle(ids[1], isText: true)

        stack.toggle(ids[1], isText: true)

        // The hint is derived as picks are made rather than recomputed in the
        // view body; a stale "yes" here would promise an empty paste.
        #expect(!stack.hasText)
        #expect(!stack.isEmpty)
    }

    @Test func pruningDropsPicksWhoseRowsAreGoneAndClosesTheGap() {
        var stack = PasteStack()
        for id in ids.prefix(3) { stack.toggle(id, isText: true) }

        stack.prune { $0 != ids[0] }

        // Rows deleted elsewhere — a row action, expiry — must not leave gaps
        // in the badge numbering.
        #expect(stack.count == 2)
        #expect(stack.number(of: ids[1]) == 1)
        #expect(stack.number(of: ids[2]) == 2)
    }

    @Test func pruningAwayTheLastTextPickClearsThePasteHint() {
        var stack = PasteStack()
        stack.toggle(ids[0], isText: true)
        stack.toggle(ids[1], isText: false)

        stack.prune { $0 != ids[0] }

        // The derived hint has to follow deletions too, not only toggles.
        #expect(!stack.hasText)
        #expect(stack.count == 1)
    }

    @Test func pruningAnEmptyHandfulNeverConsultsTheStore() {
        var stack = PasteStack()
        var asked = 0

        stack.prune { _ in
            asked += 1
            return true
        }

        // This runs on every keystroke and every store mutation; the common
        // case is an empty handful, and it has to stay free.
        #expect(asked == 0)
    }

    @Test func clearingForgetsThePicksAndTheHintTogether() {
        var stack = PasteStack()
        stack.toggle(ids[0], isText: true)

        stack.clear()

        // Escape and a fresh panel show both land here. A hint outliving the
        // picks would offer to paste a handful that no longer exists.
        #expect(stack.isEmpty)
        #expect(!stack.hasText)
        #expect(stack == PasteStack())
    }

    @Test func onePasteJoinsTheTextPicksInPickOrder() throws {
        let insertion = try #require(
            PasteStack.insertion(for: [
                Item(content: "first"),
                Item(content: "second"),
            ]))

        #expect(insertion.text == "first\nsecond")
        // Everything that goes in counts as used, so the whole handful is
        // promoted rather than only the last one pasted.
        #expect(insertion.used.count == 2)
    }

    @Test func imagesRideTheHandfulWithoutBeingPasted() throws {
        // Images are collected so a handful can be deleted in one go, but
        // their content is a derived placeholder — joining it would paste the
        // words the row displays instead of the picture.
        let insertion = try #require(
            PasteStack.insertion(for: [
                Item(content: "text"),
                Item(content: "Image 2×2", imageHash: "deadbeef"),
            ]))

        #expect(insertion.text == "text")
        #expect(insertion.used.map(\.content) == ["text"])
    }

    @Test func anAllImageHandfulPastesNothingAtAll() {
        // Not an empty paste: nothing at all. Returning an empty string here
        // would promote the picks and dismiss the panel on the way to
        // inserting nothing, and clear the user's clipboard target for it.
        #expect(PasteStack.insertion(for: [Item(content: "Image", imageHash: "beef")]) == nil)
        #expect(PasteStack.insertion(for: []) == nil)
    }
}
