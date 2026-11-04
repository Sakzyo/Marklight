// swift-tools-version:6.0
import PackageDescription

// Spike 4: caret and scroll stability, extending the Spike 3 prototype. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike4-stability",
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
            name: "spike4-host",
            dependencies: ["EditCore", "EditScenarios"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "spike4-corpus",
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
