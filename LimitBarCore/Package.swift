// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LimitBarCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LimitBarCore",
            targets: ["LimitBarCore"]
        )
    ],
    targets: [
        .target(name: "LimitBarCore"),
        .testTarget(
            name: "LimitBarCoreTests",
            dependencies: ["LimitBarCore"]
        )
    ]
)
