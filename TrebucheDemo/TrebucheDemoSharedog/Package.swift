// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrebucheDemo",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "TrebucheDemoShared",
            targets: ["TrebucheDemoShared"]
        ),
        .executable(
            name: "TrebucheDemoServer",
            targets: ["TrebucheDemoServer"]
        ),
    ],
    dependencies: [
        .package(path: ".."),  // Trebuche
    ],
    targets: [
        // Shared code: models and actors
        .target(
            name: "TrebucheDemoShared",
            dependencies: ["Trebuche"],
            path: "Sources/Shared"
        ),
        // Server executable
        .executableTarget(
            name: "TrebucheDemoServer",
            dependencies: [
                "Trebuche",
                "TrebucheDemoShared"
            ],
            path: "Sources/Server"
        ),
    ]
)
