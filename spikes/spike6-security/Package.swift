// swift-tools-version:6.0
import PackageDescription

// Spike 6: preview security and local files. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike6-security",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "spike6-security",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
