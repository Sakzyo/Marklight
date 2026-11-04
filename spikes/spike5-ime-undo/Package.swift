// swift-tools-version:6.0
import PackageDescription

// Spike 5: IME and unified undo, extending the Spike 4 prototype. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike5-ime-undo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "EditCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "EditScenarios",
            dependencies: ["EditCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "spike5-host",
            dependencies: ["EditCore", "EditScenarios"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "spike5-corpus",
            dependencies: ["EditCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EditCoreTests",
            dependencies: ["EditCore", "EditScenarios"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
