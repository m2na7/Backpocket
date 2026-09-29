import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import BackpocketKit

/// Where the hover card lands. This was window-and-screen code until it was
/// pulled out as a value, and the cases that mattered — a panel shoved against
/// the edge of a display, a side too cramped to read — were the ones nothing
/// could reach. Each rule is pinned at its boundary rather than sampled.
@MainActor
@Suite("DetailPlacement")
struct DetailPlacementTests {
    /// A 1440-point display with the panel sitting comfortably in the middle,
    /// so both sides have room and the side rule turns on preference alone.
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    private func place(
        panelX: CGFloat, width: CGFloat = 520, note: Bool = false,
        screen: CGRect? = nil
    ) -> DetailPlacement {
        DetailPlacement(
            parent: CGRect(x: panelX, y: 200, width: width, height: 500),
            visible: screen ?? self.screen,
            prefersRight: note
        )
    }

    // MARK: Side

    @Test func clipsTakeTheLeftAndNotesTheRightWhenBothHaveRoom() {
        #expect(place(panelX: 460).side == .left)
        #expect(place(panelX: 460, note: true).side == .right)
    }

    /// The preferred side loses only when it cannot hold a readable card AND
    /// the other side is roomier — both halves of the rule matter.
    @Test func acrampedPreferredSideYieldsToTheRoomierOne() {
        // Panel hard against the left edge: 40 points of left space, minus
        // the double gap, is far under the 260-point minimum.
        let clip = place(panelX: 40)
        #expect(clip.side == .right)

        let note = place(panelX: 880, note: true)
        #expect(note.side == .left)
    }

    /// Cramped on the preferred side but even more cramped on the other: the
    /// card stays where it belongs rather than moving somewhere worse.
    @Test func acrampedPreferredSideIsKeptWhenTheAlternativeIsWorse() {
        // Left space 100, right space 40 — both under the minimum, left wins
        // because it is the roomier of the two and it is also preferred.
        let clip = place(panelX: 116, width: 1_268)
        #expect(clip.side == .left)
    }

    @Test func theSideFlipsExactlyAtTheReadableMinimum() {
        // Left space is minWidth exactly once the double gap is taken off.
        let atMinimum = DetailPlacement.minWidth + DetailPlacement.gap * 2
        #expect(place(panelX: atMinimum).side == .left)
        // One point narrower, and the roomier right side takes it.
        #expect(place(panelX: atMinimum - 1).side == .right)
    }

    // MARK: Limit

    @Test func theLimitIsCappedToTheChosenSidesFreeSpace() {
        // 300 points of left space before the gaps, 284 after.
        let cramped = place(panelX: 300, width: 200)
        #expect(cramped.side == .left)
        #expect(cramped.limit.width == 284)
    }

    @Test func theLimitNeverExceedsTheMaximumHoweverWideTheScreen() {
        let roomy = place(
            panelX: 900, width: 200, screen: CGRect(x: 0, y: 0, width: 5_120, height: 1_440))
        #expect(roomy.limit.width == DetailPlacement.maxWidth)
    }

    /// A card narrower than this is not worth reading, so the limit floors
    /// there even when the side that won has less room than that.
    @Test func theLimitFloorsAtTheReadableMinimum() {
        let squeezed = place(panelX: 0, width: 1_440)
        #expect(squeezed.limit.width == DetailPlacement.minWidth)
    }

    @Test func theLimitMatchesThePanelHeightSoTheCardStaysASidecar() {
        #expect(place(panelX: 460).limit.height == 500)
    }

    @Test func ashortPanelStillGetsAUsableCardHeight() {
        let short = DetailPlacement(
            parent: CGRect(x: 460, y: 200, width: 520, height: 80),
            visible: screen, prefersRight: false)
        #expect(short.limit.height == 240)
    }

    // MARK: Origin

    @Test func anUnanchoredCardSitsAGapAwayAndTopAlignsToThePanel() {
        let clip = place(panelX: 460)
        let origin = clip.origin(size: CGSize(width: 300, height: 200), anchor: nil)

        // Left side: the card's right edge is one gap from the panel's left.
        // 460 - 300 - gap(8).
        #expect(origin.x == 152)
        // Top aligned: panel top is 700, so a 200-tall card starts at 500.
        #expect(origin.y == 500)
    }

    /// The tail bridges most of the gap, so an anchored card sits closer in.
    @Test func ananchoredCardSitsTighterAndCentersOnItsRow() {
        let clip = place(panelX: 460)
        let origin = clip.origin(size: CGSize(width: 300, height: 200), anchor: 600)

        #expect(origin.x == 158)
        #expect(origin.y == 500)
    }

    @Test func acardIsClampedOntoTheScreenRatherThanPushedOffTheLeftEdge() {
        // Panel against the left edge, so the left side has nowhere to go.
        let clip = DetailPlacement(
            parent: CGRect(x: 4, y: 200, width: 520, height: 500),
            visible: screen, prefersRight: false)
        let origin = clip.origin(size: CGSize(width: 300, height: 200), anchor: nil)
        #expect(origin.x >= screen.minX)
    }

    @Test func acardIsClampedOntoTheScreenRatherThanPushedOffTheRightEdge() {
        let note = DetailPlacement(
            parent: CGRect(x: 900, y: 200, width: 520, height: 500),
            visible: screen, prefersRight: true)
        let origin = note.origin(size: CGSize(width: 300, height: 200), anchor: nil)
        #expect(origin.x + 300 <= screen.maxX)
    }

    /// A row near the top or bottom of the screen would otherwise center a
    /// card half off the edge.
    @Test func ananchorNearTheScreenEdgeIsClampedInsteadOfHangingOff() {
        let clip = place(panelX: 460)
        let high = clip.origin(size: CGSize(width: 300, height: 400), anchor: 880)
        #expect(high.y + 400 <= screen.maxY)

        let low = clip.origin(size: CGSize(width: 300, height: 400), anchor: 20)
        #expect(low.y >= screen.minY)
    }

    /// Degenerate, and the clamp must not invert: a card larger than the
    /// screen keeps its top-left corner reachable rather than being pushed
    /// off the opposite edge by a lower bound that outran the upper one.
    @Test func acardLargerThanTheScreenKeepsItsTopLeftOnScreen() {
        let clip = place(panelX: 460)
        let origin = clip.origin(size: CGSize(width: 2_000, height: 1_600), anchor: nil)
        #expect(origin.x == screen.minX)
        #expect(origin.y == screen.minY)
    }

    // MARK: Centered

    @Test func thecenteredLimitLeavesAMarginAndCapsAtTheReadableWidth() {
        #expect(place(panelX: 460).centeredLimit.width == 880)

        let narrow = place(
            panelX: 0, width: 400, screen: CGRect(x: 0, y: 0, width: 900, height: 700))
        #expect(narrow.centeredLimit.width == 780)
    }

    @Test func acenteredCardSitsInTheMiddleOfTheVisibleArea() {
        let origin = place(panelX: 460).centeredOrigin(size: CGSize(width: 800, height: 600))
        #expect(origin.x == 320)
        #expect(origin.y == 150)
    }

    /// The visible frame is not the screen frame — the menu bar and Dock are
    /// already taken off it, and centering must respect that offset.
    @Test func centeringFollowsTheVisibleFrameNotTheScreenOrigin() {
        let offset = DetailPlacement(
            parent: CGRect(x: 500, y: 100, width: 400, height: 400),
            visible: CGRect(x: 0, y: 60, width: 1_440, height: 800),
            prefersRight: false)
        let origin = offset.centeredOrigin(size: CGSize(width: 400, height: 400))
        #expect(origin.y == 260)
    }

    // MARK: Pointer

    /// The panel, and a card sitting immediately to its right.
    private let panelFrame = CGRect(x: 100, y: 200, width: 500, height: 500)
    private let cardFrame = CGRect(x: 620, y: 250, width: 300, height: 400)

    private func onCard(_ mouse: CGPoint, overlapping: Bool = false) -> Bool {
        DetailPlacement.pointerIsOnCard(
            at: mouse, card: cardFrame, parent: panelFrame,
            overlapsParent: overlapping, slack: 20)
    }

    /// The gap between panel and card is a dead zone the pointer crosses on
    /// its way over, and losing the card mid-journey is the failure this
    /// margin exists to prevent — so the margin counts as being on the card,
    /// and a pointer past it does not.
    @Test func theSlackMarginCountsAsBeingOnTheCard() {
        #expect(onCard(CGPoint(x: 700, y: 400)))
        #expect(onCard(CGPoint(x: 605, y: 400)))
        #expect(!onCard(CGPoint(x: 950, y: 400)))
    }

    /// The panel wins the overlap. Once the margin reaches back across the
    /// gap it covers real rows, and a pointer on a row is on a row — reading
    /// it as "still on the card" would keep a card up over the row the user
    /// has already moved on to.
    @Test func amarginReachingOverThePanelStillBelongsToThePanel() {
        let wide = DetailPlacement.pointerIsOnCard(
            at: CGPoint(x: 595, y: 400), card: cardFrame, parent: panelFrame,
            overlapsParent: false, slack: 40)
        #expect(!wide)
    }

    /// A card drawn OVER the panel contains the list itself, so every row is
    /// also "on the card" and nothing could ever retire it. It gets no grace
    /// at all — the regression is a preview that will not go away.
    @Test func acardDrawnOverThePanelGetsNoGrace() {
        #expect(!onCard(CGPoint(x: 700, y: 400), overlapping: true))
    }

    /// Only a hover has a row under the pointer to point a tail at. A
    /// keyboard preview would otherwise aim its tail at wherever the mouse
    /// happens to be resting, which is not the row being previewed.
    @Test func onlyAhoverOverThePanelAnchorsTheTail() {
        let onArow = CGPoint(x: 300, y: 400)
        #expect(DetailPlacement.anchor(at: onArow, in: panelFrame, anchored: true) == 400)
        #expect(DetailPlacement.anchor(at: onArow, in: panelFrame, anchored: false) == nil)

        // Anchored, but the pointer has left the panel — there is no row
        // under it to point at either.
        let away = CGPoint(x: 900, y: 400)
        #expect(DetailPlacement.anchor(at: away, in: panelFrame, anchored: true) == nil)
    }
}

/// The sizing twin. `DetailContent.measured` drops the syntax coloring so the
/// card can be measured in ~5 ms instead of ~185 ms, which is only sound
/// while the coloring moves no glyphs. If a future theme reaches for a
/// different face or a wider weight, these are what fail.
@MainActor
@Suite("DetailContent sizing")
struct DetailContentSizingTests {
    private let container: ModelContainer
    private let item: Item

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        item = Item(content: "sample")
        ModelContext(container).insert(item)
    }

    private func content(_ body: String, _ language: CodeLanguage) -> DetailContent {
        DetailContent(
            text: body,
            highlighted: SyntaxHighlighter.highlight(body, language: language),
            language: language,
            meta: DetailMeta(item)
        )
    }

    /// Every language the highlighter knows, at one line and at the 6,000
    /// character cap the card feeds it.
    @Test(arguments: [
        CodeLanguage.swift, .typescript, .javascript, .json, .markdown, .shell, .generic,
    ])
    func themeasuringTwinIsExactlyTheSizeOfTheColoredCard(language: CodeLanguage) {
        let unit = """
            func hello(name: String) -> Int { let n = name.count; return n * 2 }
            // a comment with "a string" and 42 in it
            if (x === null) { return [1, 2, 3]; }

            """
        for reps in [1, 60] {
            let body = String(String(repeating: unit, count: reps).prefix(6_000))
            let card = content(body, language)

            let colored = NSHostingView(rootView: card).fittingSize
            let measured = NSHostingView(rootView: card.measured).fittingSize

            #expect(colored == measured, "\(language) x\(reps): \(colored) vs \(measured)")
        }
    }

    /// The card is drawn from a decode capped to what the display can show,
    /// not from the full-size bitmap. That must be invisible: the capped
    /// image has to report the same point size, so the card lays out to
    /// exactly the same rectangle as an uncapped decode would.
    ///
    /// The cap is a parameter, so a small image under a smaller cap takes the
    /// same path a retina screenshot does under the real one, without a
    /// 12-megapixel fixture. The image fits inside `imageMax`, so the card
    /// draws it at its own size: a decode whose `size` followed its pixels
    /// would shrink the card, and fail the layout check below as well.
    @Test func acappedDecodeLaysOutToTheSameCardAsTheFullSizeImage() throws {
        let data = try Fixture.png(width: 400, height: 300)
        let imageMax = CGSize(width: 696, height: 840)

        let full = try #require(NSImage(data: data))
        let capped = try #require(DetailPanel.cardImage(from: data, pixels: 100))

        #expect(capped.size == full.size)
        #expect(capped.size == NSSize(width: 400, height: 300))
        // Exactly the cap, which is what the function exists for: returning
        // the full-size image, its own fallback, keeps all 400, and a decode
        // that over-shrank would come in under it.
        let rep = try #require(capped.representations.first as? NSBitmapImageRep)
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 100)

        func card(_ image: NSImage) -> DetailContent {
            DetailContent(
                text: "", highlighted: nil, language: nil, image: image,
                imageMax: imageMax, imageStats: "400×300", meta: DetailMeta(item))
        }
        #expect(
            NSHostingView(rootView: card(full)).fittingSize
                == NSHostingView(rootView: card(capped)).fittingSize)
    }

    /// An image already smaller than the cap is handed through untouched —
    /// upscaling a small clip to the card's pixel budget would only blur it.
    @Test func animageBelowTheCapIsLeftAlone() throws {
        let data = try Fixture.png(width: 120, height: 90)

        let capped = try #require(DetailPanel.cardImage(from: data, pixels: 1_680))
        #expect(capped.size == NSSize(width: 120, height: 90))
        let rep = try #require(capped.representations.first)
        #expect(rep.pixelsWide == 120)
    }

    /// The twin swaps the string, not the layout: an image card and a link
    /// card must measure the same either way, since neither has a highlighted
    /// branch to substitute.
    @Test func thetwinChangesNothingForCardsWithoutHighlighting() throws {
        let link = DetailContent(
            text: "https://example.com/a/very/long/path?with=query",
            highlighted: nil, language: nil,
            linkHost: "example.com", meta: DetailMeta(item))
        #expect(
            NSHostingView(rootView: link).fittingSize
                == NSHostingView(rootView: link.measured).fittingSize)

        let prose = DetailContent(
            text: String(repeating: "some ordinary prose that wraps. ", count: 40),
            highlighted: nil, language: nil, meta: DetailMeta(item))
        #expect(
            NSHostingView(rootView: prose).fittingSize
                == NSHostingView(rootView: prose.measured).fittingSize)
    }
}

/// Whether the card still describes a row, which decides whether it gets a
/// grace period at all. Each case holds its own strong reference to the item
/// throughout — the situation the check exists for, since a card whose item
/// had simply been freed was already closed by its weak reference.
@MainActor
@Suite("DetailPanel liveness")
struct DetailPanelLivenessTests {
    private let store: Store
    private let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        store = Store(context: ModelContext(container), disposableLimit: { 1 })
    }

    @Test func nothingShownIsNotLive() {
        #expect(!DetailPanel.isLive(nil))
    }

    /// Store never hands one out, but a model no context owns is not a row.
    @Test func anItemNoStoreOwnsIsNotLive() {
        #expect(!DetailPanel.isLive(Item(content: "loose")))
    }

    /// The reported case: ⌘⌫ with the pointer on the card. `Store.delete`
    /// saves before the card is asked, and SwiftData clears `isDeleted` on
    /// save, so a check on that flag alone kept the card up over the row.
    @Test func aDeletedItemStopsBeingLiveOnceTheDeleteIsSaved() throws {
        store.addNote("a note the card is showing")
        let item = try #require(store.items.first)
        #expect(DetailPanel.isLive(item))

        store.delete(item)

        #expect(!DetailPanel.isLive(item))
    }

    /// The half the flag still covers. Between a delete and its save the
    /// model keeps its context, so only `isDeleted` says it is leaving.
    /// `Store` always saves at once, so this goes straight to a context.
    @Test func aDeleteNotYetSavedIsNotLive() throws {
        let context = ModelContext(container)
        let item = Item(content: "deleted, not yet saved")
        context.insert(item)
        try context.save()
        #expect(DetailPanel.isLive(item))

        context.delete(item)

        #expect(item.modelContext != nil)
        #expect(!DetailPanel.isLive(item))
    }

    /// An undone delete comes back as a new model, and that one is a row.
    @Test func theRowAnUndoPutsBackIsLive() throws {
        store.addNote("deleted, then restored")
        store.delete(try #require(store.items.first))
        #expect(store.undoDelete())

        let restored = try #require(store.items.first)
        #expect(DetailPanel.isLive(restored))
    }

    /// Trimming is a delete the user never asked for, and the card must
    /// treat it like one.
    @Test func aRowTrimmedPastTheCapIsNotLive() throws {
        let source = CopySource(name: "TestApp", bundleID: "dev.test.app")
        store.add("older", source: source)
        let older = try #require(store.items.first)
        // The cap is one, so the next copy trims the first.
        store.add("newer", source: source)
        #expect(!store.items.contains { $0 === older })

        #expect(!DetailPanel.isLive(older))
        let newer = try #require(store.items.first)
        #expect(DetailPanel.isLive(newer))
    }
}
