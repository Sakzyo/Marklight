// swift-tools-version:6.0
import PackageDescription

// Spike 2: zero-diff file I/O. Throwaway; never imported by the app or core.
let package = Package(
    name: "spike2-io",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spike2-io", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
