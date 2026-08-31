// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Backpocket",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // All application logic lives here so it can be tested.
        // The executable target below is a thin entry point only.
        .target(
            name: "BackpocketKit",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BackpocketKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
