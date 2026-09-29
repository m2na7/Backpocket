import Foundation
import SwiftData
import Testing

@testable import BackpocketKit

/// The `--demo` content exists to be captured, and the panel purges expired
/// clips every time it opens — so anything the seed backdates past the
/// retention window is gone before the first screenshot is taken.
@MainActor
@Suite
struct DemoSeedTests {
    private let store: Store
    private let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Item.self, configurations: configuration)
        store = Store(
            context: ModelContext(container),
            disposableLimit: { HistoryLimit.default.rawValue }
        )
    }

    @Test func nothingSeededIsOldEnoughToExpireAtTheDefault() async {
        await DemoSeed.seed(into: store)
        let seeded = store.items.count
        #expect(seeded > 0)

        // What opening the panel does first. Each clip's gap is capped, but
        // the gaps add up, and a cap on one gap is no cap on their sum: the
        // oldest clip used to land past seven days and vanish from every
        // capture taken with the default settings.
        store.purgeExpired(days: ExpiryOption.default.rawValue)
        #expect(store.items.count == seeded)
    }
}
