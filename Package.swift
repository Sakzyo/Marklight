// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MarklightCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarklightCore", targets: ["MarklightCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MarklightCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "MarklightCoreTests",
            dependencies: ["MarklightCore"]
        ),
    ]
)
