// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Trebuche",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(
            name: "Trebuche",
            targets: ["Trebuche"]
        ),
        .library(
            name: "TrebucheCloud",
            targets: ["TrebucheCloud"]
        ),
        .library(
            name: "TrebucheAWS",
            targets: ["TrebucheAWS"]
        ),
        .library(
            name: "TrebuchePostgreSQL",
            targets: ["TrebuchePostgreSQL"]
        ),
        .library(
            name: "TrebucheObservability",
            targets: ["TrebucheObservability"]
        ),
        .library(
            name: "TrebucheSecurity",
            targets: ["TrebucheSecurity"]
        ),
        .executable(
            name: "trebuche",
            targets: ["TrebucheCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        // PostgreSQL support
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // Cryptography (cross-platform)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // CLI dependencies
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "Trebuche",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                "TrebucheMacros",
            ]
        ),
        .macro(
            name: "TrebucheMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "TrebucheCloud",
            dependencies: [
                "Trebuche",
                "TrebucheObservability",
                "TrebucheSecurity",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "TrebucheAWS",
            dependencies: [
                "Trebuche",
                "TrebucheCloud",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TrebuchePostgreSQL",
            dependencies: [
                "Trebuche",
                "TrebucheCloud",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .target(
            name: "TrebucheObservability",
            dependencies: [
                "Trebuche",
            ]
        ),
        .target(
            name: "TrebucheSecurity",
            dependencies: [
                "Trebuche",
                "TrebucheObservability",
            ]
        ),
        .executableTarget(
            name: "TrebucheCLI",
            dependencies: [
                "Trebuche",
                "TrebucheCloud",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "TrebucheTests",
            dependencies: ["Trebuche"]
        ),
        .testTarget(
            name: "TrebucheCloudTests",
            dependencies: ["TrebucheCloud"]
        ),
        .testTarget(
            name: "TrebucheAWSTests",
            dependencies: ["TrebucheAWS"]
        ),
        .testTarget(
            name: "TrebuchePostgreSQLTests",
            dependencies: ["TrebuchePostgreSQL"]
        ),
        .testTarget(
            name: "TrebucheCLITests",
            dependencies: ["TrebucheCLI"]
        ),
        .testTarget(
            name: "TrebucheObservabilityTests",
            dependencies: ["TrebucheObservability"]
        ),
        .testTarget(
            name: "TrebucheSecurityTests",
            dependencies: ["TrebucheSecurity"]
        ),
    ]
)
