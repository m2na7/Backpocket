import AppKit
import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// Real encoded images, one builder for every suite that needs one. The
/// store's digest, the favicon sanitizer and the detail card read dimensions
/// from the bytes or decode them, so a stub blob would be rejected as
/// undecodable and a test would pass for the wrong reason; the watcher hands
/// the bytes through verbatim, so its tests compare against exactly these.
///
/// Nonisolated, unlike `ViewFixture`: suites that are not on the main actor
/// build images too.
enum Fixture {
    /// An RGBA bitmap, zeroed unless `fill` says otherwise. Zeroed is fully
    /// transparent, which is fine wherever only the bytes matter and wrong
    /// wherever something has to be seen drawn.
    static func bitmap(width: Int, height: Int, fill: UInt8? = nil) throws -> NSBitmapImageRep {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let fill {
            // One call rather than a loop over every byte. Tests build
            // unoptimized, where the loop costs about 100 ms for a 640×400
            // image and this well under one.
            let plane = try #require(bitmap.bitmapData)
            plane.update(repeating: fill, count: bitmap.bytesPerRow * height)
        }
        return bitmap
    }

    static func png(width: Int, height: Int, fill: UInt8? = nil) throws -> Data {
        try #require(
            bitmap(width: width, height: height, fill: fill)
                .representation(using: .png, properties: [:]))
    }
}

/// A real file, because `Item.fileURLs` checks existence on every read and a
/// made-up path would make a lookup come back empty for the wrong reason. It
/// sits alone in a folder of its own, removed afterwards.
///
/// Named `id_rsa`, after the file whose path the file-copy rules exist to
/// keep from pasting as the file itself; suites assert on that name.
func withRealFile(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "backpocket-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appending(path: "id_rsa")
    try Data("private key".utf8).write(to: file)
    try body(file)
}

/// A pasteboard of its own: writing to `.general` would clobber whatever the
/// person running the suite has on their real clipboard. Named pasteboards
/// live on in the pasteboard server after the process exits, so it is
/// released afterwards rather than left to pile up across runs.
func withPrivatePasteboard<R>(_ body: (NSPasteboard) throws -> R) rethrows -> R {
    let pasteboard = NSPasteboard(name: .init("backpocket-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    return try body(pasteboard)
}

/// A suite built on one store over an in-memory container of its own, as
/// StoreTests, DeletionUndoTests and LinkTests are. swift-testing makes a
/// fresh suite value for every test, so no two tests ever share the store;
/// conforming supplies the two ways such a suite reads it back.
@MainActor
protocol InMemoryStoreSuite {
    var container: ModelContainer { get }
    var store: Store { get }
}

extension InMemoryStoreSuite {
    /// For the suite's initializer: nothing else, and no file on disk, can
    /// reach what the store writes here.
    static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Item.self, configurations: configuration)
    }

    func item(_ content: String) throws -> Item {
        try #require(store.items.first { $0.content == content })
    }

    /// A fresh context sees only what actually reached the container, so a
    /// desync between the published array and the database cannot hide.
    func persistedContents() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Item>()).map(\.content)
    }
}
