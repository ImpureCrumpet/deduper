// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Deduper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DeduperKit", targets: ["DeduperKit"]),
        .library(name: "DeduperUI", targets: ["DeduperUI"]),
        .executable(name: "deduper", targets: ["DeduperCLI"]),
        .executable(name: "DeduperApp", targets: ["DeduperApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "DeduperKit",
            dependencies: []
        ),
        .target(
            name: "DeduperUI",
            dependencies: ["DeduperKit"]
        ),
        .executableTarget(
            name: "DeduperCLI",
            dependencies: [
                "DeduperKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "DeduperApp",
            dependencies: ["DeduperKit", "DeduperUI"]
        ),
        .testTarget(
            name: "DeduperKitTests",
            dependencies: ["DeduperKit"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
