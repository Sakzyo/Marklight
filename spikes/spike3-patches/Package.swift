// swift-tools-version:6.0
import PackageDescription

// Spike 3: rendered edit to source patch. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike3-patches",
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
            name: "spike3-host",
            dependencies: ["EditCore", "EditScenarios"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "spike3-corpus",
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
