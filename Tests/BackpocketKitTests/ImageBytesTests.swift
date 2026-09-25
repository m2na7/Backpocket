import AppKit
import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// Where an image clip's bytes live once it is recorded. The rows `Store`
/// publishes stay alive for the whole session, so the pixels must not ride
/// along in them: they go to disk when the row is written and come back only
/// for the read that needs them. None of that may be visible — every read
/// still gets the whole image — on either kind of container the app runs on.
@MainActor
@Suite("Image bytes")
struct ImageBytesTests {
    /// On disk is where the memory is at stake: only there do the bytes move
    /// to external storage. In memory is what the app falls back to when its
    /// store cannot be opened, and it has to behave identically.
    enum Backing: String, CaseIterable, CustomTestStringConvertible {
        case memory, disk
        var testDescription: String { rawValue }
    }

    private let source = CopySource(name: "TestApp", bundleID: "dev.test.app")

    /// Runs `body` against a store of its own and the context it was built
    /// on, and removes the store's directory afterwards when there is one.
    private func withStore(
        _ backing: Backing,
        _ body: @MainActor (Store, ModelContext) async throws -> Void
    ) async throws {
        var directory: URL?
        let configuration: ModelConfiguration
        switch backing {
        case .memory:
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        case .disk:
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "backpocket-image-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
            configuration = ModelConfiguration(url: url.appending(path: "Backpocket.store"))
        }
        defer { directory.map { try? FileManager.default.removeItem(at: $0) } }

        let context = ModelContext(
            try ModelContainer(for: Item.self, configurations: configuration))
        try await body(Store(context: context), context)
    }

    /// Noise, so the PNG barely compresses: at this size it lands well past
    /// the point where SwiftData moves a blob out of the row, which is the
    /// path the app's real screenshots take.
    private func noisePNG(side: Int = 320, seed: UInt32 = 1) throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        let pixels = try #require(bitmap.bitmapData)
        var state = seed
        for index in 0..<(bitmap.bytesPerRow * side) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func record(_ png: Data, in store: Store) async throws -> Item {
        store.addImage(png, source: source)
        await store.imageCapturesDidFinish()
        return try #require(store.items.first { $0.isImage })
    }

    @Test(arguments: Backing.allCases)
    func aRecordedImageReadsBackWhole(_ backing: Backing) async throws {
        try await withStore(backing) { store, context in
            let png = try noisePNG()
            let image = try await record(png, in: store)

            #expect(image.loadImageData() == png)
            // And again: every read fetches afresh, so the second has to be
            // as whole as the first.
            #expect(image.loadImageData() == png)
            let persisted = try ModelContext(context.container).fetch(FetchDescriptor<Item>())
            #expect(persisted.map(\.imageData) == [png])
        }
    }

    @Test(arguments: Backing.allCases)
    func aDeletedImageHasNoBytesToGive(_ backing: Backing) async throws {
        try await withStore(backing) { store, _ in
            let image = try await record(noisePNG(), in: store)
            store.delete(image)

            // A reference can outlive its row: the detail card's dwell task
            // may fire on a target deleted just before the list re-renders.
            // The store no longer has the bytes and the model may never have
            // loaded them, so the read has to come back empty, not trap.
            #expect(image.loadImageData() == nil)
            // Nor may paste fall back to the row's text: that is only the
            // placeholder "Image 320×320", which would land in the user's
            // document where their screenshot was meant to go.
            #expect(PasteFlavor.flavor(for: image) == nil)
        }
    }

    @Test(arguments: Backing.allCases)
    func aPastedImageClipOffersBothPNGAndTIFF(_ backing: Backing) async throws {
        try await withStore(backing) { store, _ in
            let png = try noisePNG()
            let image = try await record(png, in: store)

            guard case .image(let data) = PasteFlavor.flavor(for: image) else {
                Issue.record("an image clip must paste as an image")
                return
            }
            #expect(data == png)

            // A pasteboard of its own: `.general` is the clipboard of
            // whoever runs the suite.
            let pasteboard = NSPasteboard(name: .init("backpocket-image-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            Paster.writeImage(data, to: pasteboard)

            #expect(pasteboard.data(forType: .png) == png)
            let tiff = try #require(pasteboard.data(forType: .tiff))
            #expect(NSBitmapImageRep(data: tiff)?.pixelsWide == 320)
        }
    }

    @Test(arguments: Backing.allCases)
    func aRecordedImageIsTheStoresOwnRow(_ backing: Backing) async throws {
        try await withStore(backing) { store, context in
            let png = try noisePNG()
            let image = try await record(png, in: store)

            // The row is written through a context of its own, but what
            // `items` holds must still be a model of the store's context:
            // every later write to it is saved through that context, and a
            // model registered anywhere else would lose it.
            #expect(image.modelContext === context)

            // Re-copying the same image finds this very object and promotes
            // it instead of filing a second row.
            _ = try await record(png, in: store)
            #expect(store.items.count == 1)
            #expect(store.items.first === image)

            // And a later write, a pin here, reaches the file.
            store.togglePin(image)
            #expect(image.isPinned)
            let persisted = try ModelContext(context.container).fetch(FetchDescriptor<Item>())
            #expect(persisted.map(\.isPinned) == [true])
        }
    }

    @Test(arguments: Backing.allCases)
    func undoGivesADeletedImageBackWhole(_ backing: Backing) async throws {
        try await withStore(backing) { store, context in
            let png = try noisePNG()
            let image = try await record(png, in: store)
            let hash = image.imageHash
            let thumbnail = try #require(image.thumbnailData)

            store.delete(image)
            #expect(store.items.isEmpty)
            #expect(store.undoDelete())

            // The restore goes back through the same detached insert as a
            // capture, and must lose nothing on the way: the pixels, the
            // dedup key, and the thumbnail the row renders.
            let restored = try #require(store.items.first)
            #expect(restored.modelContext === context)
            #expect(restored.loadImageData() == png)
            #expect(restored.imageHash == hash)
            #expect(restored.thumbnailData == thumbnail)
            #expect(restored.content == "Image 320×320")

            // Still the store's own row: a re-copy promotes it.
            _ = try await record(png, in: store)
            #expect(store.items.count == 1)
            #expect(store.items.first === restored)
        }
    }

    /// On disk only: the failure is arranged by opening the same file a
    /// second time, read-only, and a store in memory has no file to reopen.
    @Test func aFailedImageWriteRecordsNoRow() async throws {
        try await withStore(.disk) { store, context in
            store.add("keep", source: source)

            // Every save through this container throws, and cleanly: the
            // refusal comes before anything reaches the file.
            let url = try #require(context.container.configurations.first).url
            let readOnly = try ModelContainer(
                for: Item.self, configurations: ModelConfiguration(url: url, allowsSave: false))
            let failing = Store(context: ModelContext(readOnly))
            let revision = failing.revision

            failing.addImage(try noisePNG(), source: source)
            await failing.imageCapturesDidFinish()

            // The row is written through a context of its own, and has to
            // fail exactly as a write through the store's context does:
            // nothing recorded, the list agreeing with the database, the
            // failure reported, and one revision for the views to see it by.
            #expect(failing.items.map(\.content) == ["keep"])
            let persisted = try ModelContext(readOnly).fetch(FetchDescriptor<Item>())
            #expect(persisted.map(\.content) == ["keep"])
            #expect(failing.hasStorageFailure)
            #expect(failing.revision == revision + 1)
        }
    }
}
