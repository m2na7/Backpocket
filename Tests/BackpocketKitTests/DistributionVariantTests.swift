import Foundation
import Testing

@testable import BackpocketKit

/// The App Store and direct builds differ at compile time, and each difference
/// pinned here is one App Review rejects: a store build that asks for the
/// Accessibility permission (guideline 2.4.5, which sent 0.1.4 back) or one
/// that updates itself. Pinned against literals, per variant — checking one
/// flag against another agrees with itself whichever way both of them go.
///
/// The store half only compiles under BACKPOCKET_MAS=1: `make test-mas`, and
/// the `mas` job in CI.
@MainActor
@Suite("Distribution variant")
struct DistributionVariantTests {
    @Test func transferIdentitiesCannotStartTheNormalApp() {
        for base in ["dev.m2na.backpocket.transfer-source", "dev.m2na.backpocket.transfer-sandbox"]
        {
            #expect(AppDelegate.isTransferBundle(base))
            #expect(AppDelegate.isTransferBundle(base + "." + UUID().uuidString.lowercased()))
        }
    }

    @Test func ordinaryAppIdentitiesAreNotTransferBundles() {
        for identifier in [
            nil, "dev.m2na.backpocket", "dev.m2na.backpocket.mas",
            "dev.m2na.backpocket.transfer-source-other",
        ] {
            #expect(!AppDelegate.isTransferBundle(identifier))
        }
    }

    @Test func sandboxAllowsWritingUserChosenNoteExports() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Backpocket.entitlements"))
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-only"] == nil)
    }

    #if BACKPOCKET_MAS
    @Test func theStoreBuildNeverPromptsAndHasNoUpdater() {
        #expect(Paster.mayPrompt == false)
        #expect(Updater.isAvailable == false)
        // The stub's switch reads as off and refuses to turn on.
        Updater.checksAutomatically = true
        #expect(Updater.checksAutomatically == false)
    }
    #else
    @Test func theDirectBuildPromptsAndUpdates() {
        #expect(Paster.mayPrompt == true)
        #expect(Updater.isAvailable == true)
        // checksAutomatically is left alone: this build's setter writes
        // Sparkle's key into UserDefaults.standard, which no test may do.
    }
    #endif

    /// What an untouched install does, rather than what the constant says.
    @Test func anUntouchedInstallPastesAutomaticallyOnlyWhereItMayAsk() throws {
        try withScratchPreferences { _ in
            #if BACKPOCKET_MAS
            #expect(PasteBehavior.isAutomatic == false)
            #else
            #expect(PasteBehavior.isAutomatic == true)
            #endif
        }
    }
}
