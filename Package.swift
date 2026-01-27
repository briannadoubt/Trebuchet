// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Trebuchet",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(
            name: "Trebuchet",
            targets: ["Trebuchet"]
        ),
        .library(
            name: "TrebuchetCloud",
            targets: ["TrebuchetCloud"]
        ),
        .library(
            name: "TrebuchetAWS",
            targets: ["TrebuchetAWS"]
        ),
        .library(
            name: "TrebuchetPostgreSQL",
            targets: ["TrebuchetPostgreSQL"]
        ),
        .library(
            name: "TrebuchetObservability",
            targets: ["TrebuchetObservability"]
        ),
        .library(
            name: "TrebuchetSecurity",
            targets: ["TrebuchetSecurity"]
        ),
        .executable(
            name: "trebuchet",
            targets: ["TrebuchetCLI"]
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
            name: "Trebuchet",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                "TrebuchetMacros",
            ]
        ),
        .macro(
            name: "TrebuchetMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "TrebuchetCloud",
            dependencies: [
                "Trebuchet",
                "TrebuchetObservability",
                "TrebuchetSecurity",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "TrebuchetAWS",
            dependencies: [
                "Trebuchet",
                "TrebuchetCloud",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "TrebuchetPostgreSQL",
            dependencies: [
                "Trebuchet",
                "TrebuchetCloud",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .target(
            name: "TrebuchetObservability",
            dependencies: [
                "Trebuchet",
            ]
        ),
        .target(
            name: "TrebuchetSecurity",
            dependencies: [
                "Trebuchet",
                "TrebuchetObservability",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "TrebuchetCLI",
            dependencies: [
                "Trebuchet",
                "TrebuchetCloud",
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
            name: "TrebuchetTests",
            dependencies: ["Trebuchet"]
        ),
        .testTarget(
            name: "TrebuchetCloudTests",
            dependencies: ["TrebuchetCloud"]
        ),
        .testTarget(
            name: "TrebuchetAWSTests",
            dependencies: ["TrebuchetAWS"]
        ),
        .testTarget(
            name: "TrebuchetPostgreSQLTests",
            dependencies: ["TrebuchetPostgreSQL"]
        ),
        .testTarget(
            name: "TrebuchetCLITests",
            dependencies: ["TrebuchetCLI"]
        ),
        .testTarget(
            name: "TrebuchetObservabilityTests",
            dependencies: ["TrebuchetObservability"]
        ),
        .testTarget(
            name: "TrebuchetSecurityTests",
            dependencies: [
                "TrebuchetSecurity",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
    ]
)
