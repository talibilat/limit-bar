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
        ),
        .executable(
            name: "LimitBarRefreshProfiler",
            targets: ["LimitBarRefreshProfiler"]
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
        .executableTarget(
            name: "LimitBarRefreshProfiler",
            dependencies: ["LimitBarCore"]
        ),
        .testTarget(
            name: "LimitBarCoreTests",
            dependencies: ["LimitBarCore"]
        )
    ]
)
