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
        .plugin(
            name: "TrebuchetPlugin",
            targets: ["TrebuchetPlugin"]
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
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
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
        // AWS SDK (Soto) - individual service packages
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Trebuchet",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
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
                .product(name: "SotoDynamoDB", package: "soto"),
                .product(name: "SotoServiceDiscovery", package: "soto"),
                .product(name: "SotoCloudWatch", package: "soto"),
                .product(name: "SotoLambda", package: "soto"),
                .product(name: "SotoIAM", package: "soto"),
                .product(name: "SotoApiGatewayManagementApi", package: "soto"),
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
                .product(name: "SotoCloudWatch", package: "soto"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .plugin(
            name: "TrebuchetPlugin",
            capability: .command(
                intent: .custom(
                    verb: "trebuchet",
                    description: "Deploy Swift distributed actors to the cloud"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Generate deployment artifacts, configuration files, and infrastructure code"
                    ),
                    .allowNetworkConnections(
                        scope: .all(ports: []),
                        reason: "Deploy to cloud providers (AWS, Fly.io) and check deployment status"
                    ),
                ]
            ),
            dependencies: ["TrebuchetCLI"]
        ),
        .testTarget(
            name: "TrebuchetTests",
            dependencies: [
                "Trebuchet",
                "TrebuchetCloud",
            ]
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
            dependencies: ["TrebuchetPostgreSQL"],
            resources: [
                .copy("setup.sql")
            ]
        ),
        .testTarget(
            name: "TrebuchetCLITests",
            dependencies: ["TrebuchetCLI"]
        ),
        .testTarget(
            name: "TrebuchetObservabilityTests",
            dependencies: [
                "TrebuchetObservability",
                .product(name: "SotoCloudWatch", package: "soto"),
            ]
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
