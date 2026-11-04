// swift-tools-version:6.0
import PackageDescription

// The macOS app. `scripts/build-app.sh` turns the `Marklight` executable into a
// bundle. Kept apart from the core package, which has no UI dependencies.
let package = Package(
    name: "MarklightApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "MarklightApp",
            dependencies: [.product(name: "MarklightCore", package: "Marklight")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Marklight",
            dependencies: ["MarklightApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MarklightAppTests",
            dependencies: ["MarklightApp", .product(name: "MarklightCore", package: "Marklight")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
