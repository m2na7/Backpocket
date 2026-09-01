// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Mac App Store build must not contain Sparkle at all. Apple distributes
// and updates that copy, an app that updates itself is rejected on review, and
// Sparkle's XPC services need a temporary-exception entitlement the store does
// not grant. Leaving the framework linked but unused would still ship the
// binary, so the dependency is dropped from the manifest rather than guarded
// in code — `Updater` compiles to a no-op under the same flag.
let isMAS = ProcessInfo.processInfo.environment["BACKPOCKET_MAS"] == "1"

let package = Package(
    name: "Backpocket",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: isMAS
        ? []
        : [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [
        // All application logic lives here so it can be tested.
        // The executable target below is a thin entry point only.
        .target(
            name: "BackpocketKit",
            dependencies: isMAS ? [] : [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BackpocketKit",
            swiftSettings: isMAS
                ? [.swiftLanguageMode(.v6), .define("BACKPOCKET_MAS")]
                : [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Backpocket",
            dependencies: ["BackpocketKit"],
            path: "Sources/Backpocket",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BackpocketKitTests",
            dependencies: ["BackpocketKit"],
            path: "Tests/BackpocketKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
