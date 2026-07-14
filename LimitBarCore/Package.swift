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
            name: "limitbar-migration-validator",
            targets: ["LimitBarMigrationValidator"]
        )
    ],
    targets: [
        .target(
            name: "LimitBarCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "LimitBarMigrationValidation",
            dependencies: ["LimitBarCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LimitBarMigrationValidator",
            dependencies: ["LimitBarMigrationValidation"]
        ),
        .testTarget(
            name: "LimitBarCoreTests",
            dependencies: ["LimitBarCore", "LimitBarMigrationValidation"],
            exclude: ["Fixtures"]
        )
    ]
)
