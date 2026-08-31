import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import BackpocketKit

/// A smoke harness for the SwiftUI views, and nothing more than that.
///
/// WHAT IT PROVES: that a view can be built with real data, that laying it out
/// does not crash or trap — a SwiftData fault on a deleted item, a force
/// unwrap, an index walked off the end of a row builder — that it asks for a
/// size in the region of sane, and that drawing it puts something on the
/// canvas. A view that lays out and then draws nothing is a real failure mode
/// here, and the raster check is what catches it.
///
/// WHAT IT DOES NOT PROVE: that any of it LOOKS right. Nothing below compares
/// pixels, and nothing below should start to. Appearance is verified by a
/// human against a screenshot (`--snapshot`, see `DebugLaunch`); a pixel
/// suite would be green on the machine that recorded it and red on every
/// contributor's, which is worse than not having one. Read a failure here as
/// "this view is broken", never as "this view changed".
///
/// The technique is `NSHostingView` plus `cacheDisplay(in:to:)`, which the app
/// already uses for its own screenshots: it needs no third-party dependency,
/// no window server, and no awake display.
///
/// ONE KNOWN LIMIT, worth stating because it decides how these tests are
/// written: rows inside a SwiftUI `List` are populated by the AppKit table
/// underneath it, which does no work until the view is in a window being
/// driven by a run loop. So a panel rendered here draws its chrome, its
/// headers, its counts and its empty states, but not the rows themselves —
/// and waiting for them would be exactly the timing assumption that makes a
/// render suite flaky. The row views are therefore rendered on their own,
/// which is also the only way to reach one row kind at a time.
@MainActor
struct RenderedView {
    /// What the view asks for when nothing constrains it.
    let fittingSize: NSSize
    /// What it was actually rasterized at.
    let rasterSize: NSSize
    /// Distinct pixel values over a bounded sample of the raster. A view that
    /// laid out but drew nothing comes back as exactly one.
    let distinctColors: Int

    var drewSomething: Bool { distinctColors > 1 }
}

@MainActor
enum OffscreenRender {
    /// A dimension past this is not a layout, it is a runaway. Deliberately
    /// loose: the point is to catch a view that asked for a million points,
    /// not to pin any view to a number that a font change could move.
    static let saneLimit: CGFloat = 20_000

    /// Sampling ceiling. Rasters here are panel-sized at most, so this only
    /// bounds the pathological case; the stride keeps the scan proportional.
    private static let sampleBudget = 200_000

    /// Lays `view` out and draws it. `size` fixes the raster; without one the
    /// view's own fitting size is used, so a self-sizing view is measured on
    /// its own terms.
    static func run(_ view: some View, at size: NSSize? = nil) throws -> RenderedView {
        let host = NSHostingView(rootView: view)
        let fitting = host.fittingSize

        // A zero side makes bitmapImageRepForCachingDisplay return nil, which
        // would report as "could not render" rather than as the degenerate
        // layout it is. Clamp, and let the caller's bounds check say so.
        let raster = NSSize(
            width: min(max(size?.width ?? fitting.width, 1), saneLimit),
            height: min(max(size?.height ?? fitting.height, 1), saneLimit)
        )
        host.frame = NSRect(origin: .zero, size: raster)
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "no bitmap for \(host.bounds)")
        host.cacheDisplay(in: host.bounds, to: bitmap)

        return RenderedView(
            fittingSize: fitting,
            rasterSize: raster,
            distinctColors: try distinctColors(in: bitmap)
        )
    }

    private static func distinctColors(in bitmap: NSBitmapImageRep) throws -> Int {
        let plane = try #require(bitmap.bitmapData, "raster has no backing bytes")
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        // Sample on a grid rather than reading every pixel: a difference
        // anywhere in the raster is enough to answer "did anything draw".
        let stride = max(1, Int((Double(width * height) / Double(sampleBudget)).squareRoot()))

        var seen = Set<UInt32>()
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                var value: UInt32 = 0
                for byte in 0..<min(4, bytesPerPixel) {
                    value = value << 8 | UInt32(plane[offset + byte])
                }
                seen.insert(value)
                // Two distinct values already answer the question; the rest of
                // the scan would only make the suite slower.
                if seen.count > 1 { return seen.count }
            }
        }
        return seen.count
    }
}

/// Renders `view` and checks the three things a smoke test can honestly check.
/// `name` names the case in the failure, since one test body covers several.
@MainActor
@discardableResult
func expectRenders(
    _ view: some View,
    named name: String,
    at size: NSSize? = nil,
    minimum: NSSize = NSSize(width: 1, height: 1),
    drawsInk: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> RenderedView {
    let rendered = try OffscreenRender.run(view, at: size)

    // Only meaningful for a view that sizes itself; one given an explicit
    // raster is being measured against that instead.
    if size == nil {
        #expect(
            rendered.fittingSize.width >= minimum.width
                && rendered.fittingSize.height >= minimum.height,
            "\(name): degenerate fitting size \(rendered.fittingSize)",
            sourceLocation: sourceLocation)
    }
    #expect(
        rendered.fittingSize.width < OffscreenRender.saneLimit
            && rendered.fittingSize.height < OffscreenRender.saneLimit,
        "\(name): runaway fitting size \(rendered.fittingSize)",
        sourceLocation: sourceLocation)

    if drawsInk {
        #expect(
            rendered.drewSomething,
            "\(name): laid out at \(rendered.rasterSize) but drew a blank raster",
            sourceLocation: sourceLocation)
    }
    return rendered
}

// MARK: - Fixtures

/// In-memory content for the views to render. Nothing here touches the user's
/// store or preferences: the container is `isStoredInMemoryOnly`, and the one
/// thing that must exist on disk — a file copy's target, which `FileClip`
/// re-checks against the filesystem on every read — is created under a
/// per-fixture temporary directory and removed with it.
@MainActor
final class ViewFixture {
    let container: ModelContainer
    let context: ModelContext
    let store: Store

    /// A fixed reference point. Everything is placed relative to `Date()`
    /// rather than at an absolute stamp, so the recency buckets and the row
    /// labels land the same way in any timezone and under any calendar.
    let now = Date()

    private let scratchDirectory: URL

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        context = ModelContext(container)
        // Zero means unlimited: a fixture must keep exactly what it inserted,
        // whatever the user's own history cap happens to be.
        store = Store(context: context, disposableLimit: { 0 })

        scratchDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backpocket-view-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    // MARK: Items

    /// Inserts an item and reloads the store. `age` places it in the past, in
    /// seconds, which is what puts notes into distinct recency buckets.
    @discardableResult
    private func insert(_ item: Item, age: TimeInterval, pinned: Bool = false) -> Item {
        item.usedAt = now.addingTimeInterval(-age)
        item.createdAt = item.usedAt
        item.isPinned = pinned
        context.insert(item)
        store.reload()
        return item
    }

    @discardableResult
    func addText(_ content: String, age: TimeInterval = 60, pinned: Bool = false) -> Item {
        insert(
            Item(content: content, source: CopySource(name: "Notes", bundleID: "com.apple.Notes")),
            age: age, pinned: pinned)
    }

    /// A rich copy: carrying HTML is what unlocks the "paste as Markdown"
    /// entry in the row's context menu.
    @discardableResult
    func addCode(_ content: String, age: TimeInterval = 120) -> Item {
        insert(
            Item(
                content: content,
                source: CopySource(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
                html: "<pre>\(content)</pre>"),
            age: age)
    }

    @discardableResult
    func addLink(_ url: String = "https://example.com/a/path?q=1", age: TimeInterval = 180) -> Item
    {
        insert(
            Item(content: url, source: CopySource(name: "Safari", bundleID: "com.apple.Safari")),
            age: age)
    }

    /// A real encoded PNG, thumbnail included: the row decodes the bytes it is
    /// given, so a stub blob would exercise the missing-thumbnail branch
    /// instead of the one being aimed at.
    @discardableResult
    func addImage(width: Int = 640, height: Int = 400, age: TimeInterval = 240) throws -> Item {
        let full = try Self.png(width: width, height: height)
        let thumbnail = try Self.png(width: 44, height: 28)
        return insert(
            Item(
                content: "Image \(width)×\(height)",
                source: CopySource(name: "Preview", bundleID: "com.apple.Preview"),
                imageData: full,
                thumbnailData: thumbnail,
                imageHash: "fixture-\(width)x\(height)"),
            age: age)
    }

    /// A file copy that resolves: `FileClip` rejects any path that is not on
    /// disk, so without a real file this would render as ordinary text.
    @discardableResult
    func addFileCopy(name: String = "report.pdf", age: TimeInterval = 300) throws -> Item {
        let url = scratchDirectory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return insert(
            Item(
                content: url.path,
                source: CopySource(name: "Finder", bundleID: "com.apple.finder"),
                isFileCopy: true),
            age: age)
    }

    @discardableResult
    func addNote(_ content: String, age: TimeInterval = 60, pinned: Bool = false) -> Item {
        insert(Item(content: content, isNote: true), age: age, pinned: pinned)
    }

    /// One of everything, plus notes spread across the recency buckets, which
    /// is where the notes column's section merging has to hold up.
    func fill() throws {
        addText("a plain piece of copied text that is long enough to need truncating somewhere")
        addCode("func hello(name: String) -> Int { name.count * 2 }")
        addLink()
        addLink("https://a.very.long.subdomain.example.org/deep/path/segment#fragment", age: 200)
        try addImage()
        try addFileCopy()
        addText("a pinned clip", age: 90, pinned: true)

        addNote("a note written today")
        addNote("a note from earlier this week", age: 3 * 86_400)
        addNote("a note from last month", age: 20 * 86_400)
        addNote("a note from a while back", age: 200 * 86_400)
        addNote("a pinned note", age: 5 * 86_400, pinned: true)
    }

    static func png(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let plane = try #require(bitmap.bitmapData)
        // A flat grey rather than zeroed bytes: a fully transparent thumbnail
        // would draw nothing and make the ink check meaningless.
        for index in 0..<(bitmap.bytesPerRow * height) { plane[index] = 0x80 }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

// MARK: - The harness, checked against itself

/// The blank check is the one assertion here that could quietly stop meaning
/// anything: if the raster came back as noise for every view, "it drew
/// something" would be true no matter what broke. These two pin both answers.
@MainActor
@Suite
struct ViewSmokeHarnessTests {
    @Test func aviewThatDrawsNothingIsReportedBlank() throws {
        let rendered = try OffscreenRender.run(
            Color.clear, at: NSSize(width: 120, height: 40))
        #expect(!rendered.drewSomething, "a clear view rastered \(rendered.distinctColors) colors")
    }

    @Test func aviewThatDrawsSomethingIsNotReportedBlank() throws {
        let rendered = try OffscreenRender.run(
            Text(verbatim: "smoke").padding(), at: NSSize(width: 120, height: 40))
        #expect(rendered.drewSomething)
    }
}
