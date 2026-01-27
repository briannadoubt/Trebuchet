// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Shared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Shared",
            targets: ["Shared"]
        ),
        .executable(
            name: "Server",
            targets: ["Server"]
        ),
    ],
    dependencies: [
        .package(path: "../.."), // Trebuchet
    ],
    targets: [
        // Shared code: models and actors
        .target(
            name: "Shared",
            dependencies: ["Trebuchet"],
        ),
        // Server executable
        .executableTarget(
            name: "Server",
            dependencies: [
                "Trebuchet",
                "Shared"
            ],
        ),
    ]
)
