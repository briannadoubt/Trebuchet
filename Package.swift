// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Trebuchet",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .custom("wasi", versionString: "1.0")
    ],
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
            name: "TrebuchetObservability",
            targets: ["TrebuchetObservability"]
        ),
        .library(
            name: "TrebuchetSecurity",
            targets: ["TrebuchetSecurity"]
        ),
        .library(
            name: "TrebuchetSQLite",
            targets: ["TrebuchetSQLite"]
        ),
        .plugin(
            name: "TrebuchetPlugin",
            targets: ["TrebuchetPlugin"]
        ),
        .library(
            name: "TrebuchetCLI",
            targets: ["TrebuchetCLI"]
        ),
        .executable(
            name: "trebuchet",
            targets: ["TrebuchetCLITool"]
        ),
        .library(
            name: "TrebuchetOTel",
            targets: ["TrebuchetOTel"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.19.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
        // SQLite support (GRDB)
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.1"),
        // Cryptography (cross-platform)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Observability (Apple standard libraries)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
        // CLI dependencies
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "Trebuchet",
            dependencies: [
                .product(
                    name: "NIO",
                    package: "swift-nio",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "NIOFoundationCompat",
                    package: "swift-nio",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "NIOWebSocket",
                    package: "swift-nio",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "NIOExtras",
                    package: "swift-nio-extras",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "NIOSSL",
                    package: "swift-nio-ssl",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "WebSocketKit",
                    package: "websocket-kit",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "JavaScriptKit",
                    package: "JavaScriptKit",
                    condition: .when(platforms: [.wasi])
                ),
                .product(
                    name: "JavaScriptEventLoop",
                    package: "JavaScriptKit",
                    condition: .when(platforms: [.wasi])
                ),
                .target(
                    name: "TrebuchetMacros",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "Metrics",
                    package: "swift-metrics",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "Tracing",
                    package: "swift-distributed-tracing",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
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
            name: "TrebuchetSQLite",
            dependencies: [
                "Trebuchet",
                "TrebuchetCloud",
                .product(name: "GRDB", package: "GRDB.swift"),
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
        .target(
            name: "TrebuchetCLI",
            dependencies: [
                "Trebuchet",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "TrebuchetCLITool",
            dependencies: ["TrebuchetCLI"]
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
            dependencies: ["TrebuchetCLITool"]
        ),
        .target(
            name: "TrebuchetOTel",
            dependencies: [
                "Trebuchet",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TrebuchetOTelTests",
            dependencies: ["TrebuchetOTel"]
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
            name: "TrebuchetSQLiteTests",
            dependencies: ["TrebuchetSQLite"]
        ),
        .testTarget(
            name: "TrebuchetCLITests",
            dependencies: ["TrebuchetCLI"]
        ),
        .testTarget(
            name: "TrebuchetObservabilityTests",
            dependencies: [
                "TrebuchetObservability",
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
        // TrebuchetMacrosTests temporarily disabled due to swift-syntax linker conflicts on Linux
        // The issue is that both TrebuchetCLI (for actor discovery) and TrebuchetMacrosTests
        // depend on swift-syntax, causing hundreds of "multiple definition" errors when linking
        // the test executable on Linux. This is a known issue with swift-syntax prebuilt binaries.
        // TODO: Re-enable when swift-syntax fixes the prebuilt binary conflicts or we find a workaround
        // .testTarget(
        //     name: "TrebuchetMacrosTests",
        //     dependencies: [
        //         "TrebuchetMacros",
        //     ]
        // ),
    ]
)
