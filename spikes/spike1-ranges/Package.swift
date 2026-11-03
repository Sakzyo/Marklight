// swift-tools-version:6.0
import PackageDescription

// Spike 1: swift-markdown source ranges. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike1-ranges",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "spike1-ranges",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
