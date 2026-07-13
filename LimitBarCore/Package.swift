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
        ),
        .executable(
            name: "limitbar-collect",
            targets: ["CollectorCLI"]
        )
    ],
    targets: [
        .target(
            name: "LimitBarCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CollectorCLI",
            dependencies: ["LimitBarCore"]
        ),
        .testTarget(
            name: "LimitBarCoreTests",
            dependencies: ["LimitBarCore"]
        )
    ]
)
