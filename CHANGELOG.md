# Changelog

All notable changes to Trebuchet will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Xcode Project Support
- **Automatic Xcode Project Detection**: CLI now works seamlessly with Xcode projects (`.xcodeproj` / `.xcworkspace`)
  - Zero configuration required - just run `trebuchet dev` in any Xcode project
  - Automatically detects project type and adapts behavior
  - Works across all commands: `dev`, `generate server`, `deploy`

- **Automatic Dependency Analysis**: Intelligent type dependency discovery using SwiftSyntax
  - Analyzes actor method signatures to extract all parameter and return types
  - Recursively discovers transitive dependencies (e.g., PlayerInfo → GameStatus)
  - Handles complex types: generics (`Array<T>`), optionals (`T?`), nested types
  - Smart filtering of standard library types (String, Int, UUID, etc.)
  - Copies only files needed by actors - nothing more

- **Cascade Prevention**: Symbol-scoped analysis prevents copying entire app
  - Hybrid approach: file-level copying + symbol-level dependency analysis
  - Only analyzes types actually used by actors, not all types in a file
  - Prevents cascade through unrelated dependencies
  - 20-60x improvement over naive file-level analysis
  - Example: Actor uses `PlayerInfo` from `Models.swift`, but `UnrelatedType` in same file doesn't trigger cascade to its dependencies

- **Project Detection Utility**: `ProjectDetector` in `Sources/TrebuchetCLI/Utilities/`
  - Detects `.xcodeproj` or `.xcworkspace` files
  - Extracts package names from `Package.swift` when available
  - Generates appropriate package manifests for Xcode vs SPM projects
  - Copies actor sources with full dependency resolution

- **Dependency Analysis Engine**: `DependencyAnalyzer` in `Sources/TrebuchetCLI/Discovery/`
  - SwiftSyntax-based AST parsing and type extraction
  - Specialized visitors for type definitions and usages
  - Recursive dependency resolution with cycle detection
  - File-level caching for performance (50-100ms typical)

#### Comprehensive Documentation

**User Documentation (DocC):**
- **XCODE_PROJECT_SUPPORT.md**: User guide and feature overview (149 lines)
- **DEPENDENCY_ANALYSIS.md**: Deep dive into dependency discovery (400+ lines)

**Developer Documentation (DevelopmentDocs):**
- **CASCADE_PREVENTION.md**: Critical cascade prevention explanation (450+ lines)
- **COMPLEXITY_COMPARISON.md**: File-level vs symbol-level analysis (600+ lines)
- **SYMBOL_LEVEL_EXTRACTION.md**: Future enhancement design doc (400+ lines)
- **DOCS_INDEX.md**: Complete documentation navigation guide (180 lines)

#### CLI Enhancements
- **DevCommand**: Updated for Xcode project support with verbose dependency output
- **ServerGenerator**: Automatic dependency copying for `generate server` command
- **BootstrapGenerator**: Lambda bootstrap generation supports Xcode projects
- **Updated Tests**: All 34 CLI tests pass with new functionality

### Changed
- **DevCommand**: Now skips `swift build` for Xcode projects (not applicable)
- **ServerGenerator**: Generates different `Package.swift` for Xcode vs SPM projects
- **README.md**: Added Xcode project support section with examples
- **CLAUDE.md**: Added Xcode support reference for AI assistant

### Performance
- **Dependency Analysis**: 50-100ms for typical projects
- **Cascade Prevention**: Avoids copying 200+ unnecessary files in worst case
- **File Copying**: Only 1-5 files typically copied vs entire app

## [0.3.0] - 2026-01-30

### Breaking Changes

#### Removed deprecated APIs

The following deprecated APIs have been removed. Please update your code to use the new equivalents:

**TrebuchetSecurity - JWTAuthenticator**
- Removed `SigningKey.symmetric(secret:)` → Use `SigningKey.hs256(secret:)` instead
- Removed `SigningKey.asymmetric(publicKey:)` → Use `SigningKey.es256(publicKey:)` instead

**Trebuchet - SwiftUI View Modifiers**
- Removed `View.trebuchetClient(transport:reconnectionPolicy:autoConnect:)` → Use `View.trebuchet(transport:reconnectionPolicy:autoConnect:)` instead

### Migration Guide

**Before:**
```swift
// JWT Authentication
let key = SigningKey.symmetric(secret: "my-secret")
let key = SigningKey.asymmetric(publicKey: publicKey)

// SwiftUI
ContentView()
    .trebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
```

**After:**
```swift
// JWT Authentication
let key = SigningKey.hs256(secret: "my-secret")
let key = SigningKey.es256(publicKey: publicKey)

// SwiftUI
ContentView()
    .trebuchet(transport: .webSocket(host: "localhost", port: 8080))
```

### Added

#### AWS Integration (Production-Ready)
- **Complete Soto SDK Integration**: Migrated from SmokeLambda to official AWS SDK for production reliability
  - DynamoDB for actor state persistence with optimistic locking
  - CloudWatch for metrics and observability
  - Cloud Map for service discovery
  - Lambda for serverless actor deployment
  - IAM for role management
  - API Gateway WebSocket for connection management
- **LocalStack Integration Tests**: Comprehensive test suite for AWS services
  - Automatic LocalStack initialization scripts
  - DynamoDB state store tests with versioning
  - Cloud Map registry tests
  - End-to-end workflow tests
  - Full documentation in `Tests/TrebuchetAWSTests/README.md`

#### Production Features
- **State Versioning**: Optimistic concurrency control for actor state
  - Conditional updates prevent lost writes
  - Automatic version tracking and conflict detection
- **Protocol Versioning**: Client-server compatibility handling
  - Version negotiation for distributed systems
  - Graceful degradation support
- **Graceful Shutdown**: Clean actor lifecycle management
  - Proper resource cleanup
  - In-flight request completion
  - Connection draining

#### Streaming & Cloud Gateway
- **Stream Resumption**: Resume streams from last known position after disconnection
  - Automatic sequence tracking
  - Reliable state synchronization
- **CloudGateway.process()**: Programmatic actor invocation for actor-to-actor calls
  - Direct method invocation without HTTP overhead
  - Lambda-to-Lambda communication support
- **WebSocket Lambda Handler**: RPC execution via CloudGateway in AWS Lambda
  - Full WebSocket support for serverless deployments
  - API Gateway integration

#### Testing & Quality
- **SwiftUI Integration Tests**: 325 lines covering connection lifecycle, state management, and multi-server scenarios
- **CLI Configuration Tests**: 610 lines testing configuration parsing, validation, and build system
  - Provider compatibility validation
  - Resource limit enforcement
  - State store and discovery mechanism compatibility checks
- **Configuration Validation**: Comprehensive validation to prevent misconfigurations
  - Rejects unimplemented providers (GCP, Azure, Kubernetes)
  - Validates provider-specific requirements
  - Enforces memory limits (128MB - 10GB)
  - Enforces timeout limits (1s - 900s)
- **Platform Compatibility**: Linux compatibility fixes with platform guards
  - SwiftUI tests properly guarded for macOS-only APIs
  - Executable target import workarounds for Linux

#### PostgreSQL Enhancements
- **LISTEN/NOTIFY Stream Adapter**: Full implementation for multi-instance synchronization
  - Real-time state broadcasting across PostgreSQL-backed instances
  - Automatic reconnection and channel management
- **Docker Compose Infrastructure**: PostgreSQL integration tests with automated setup
  - Healthcheck verification
  - Unique actor IDs for test isolation
- **Comprehensive Documentation**: `Tests/TrebuchetPostgreSQLTests/README.md` with setup and troubleshooting

#### Developer Experience
- **Improved Error Messages**: Better validation and debugging guidance
- **CLAUDE.md Updates**: Critical debugging instructions to never guess without seeing actual error logs
- **LocalStack Setup**: Streamlined initialization with automatic resource creation

- **TCP Transport**: Production-ready TCP transport for efficient server-to-server communication
  - Length-prefixed message framing (4-byte big-endian) via NIOExtras
  - Connection pooling with automatic stale connection cleanup
  - Idle connection timeout (5 minutes) to prevent resource leaks
  - Backpressure handling with 30-second write timeout
  - Optimized EventLoopGroup thread count (2-4 threads for I/O workloads)
  - Full integration with TrebuchetServer and TrebuchetClient
  - Comprehensive test suite with 12 integration tests including error scenarios
  - Security: Designed for trusted networks only (no TLS support)
  - Ideal for actor-to-actor communication in multi-machine deployments (e.g., Fly.io)
  - Usage: `.tcp(host: "0.0.0.0", port: 9001)`
- PostgreSQL integration tests with Docker Compose infrastructure
- Full LISTEN/NOTIFY stream adapter implementation with end-to-end verification
- Comprehensive test documentation in `Tests/TrebuchetPostgreSQLTests/README.md`

### Fixed

- **PostgreSQL**: Healthcheck now uses correct database name
- **PostgreSQL**: Integration tests use unique actor IDs to prevent conflicts
- **PostgreSQL**: NOTIFY test now actually verifies notification delivery through stream
- **Linux Build**: Platform guards for SwiftUI and executable target imports
- **AWS**: CloudClient credential handling improvements
- **DynamoDB**: Soto SDK workarounds for AWSBase64Data extraction
- **Configuration**: Provider validation prevents deployment failures for unimplemented providers

---

## Release History

This is the initial changelog. Previous releases were not tracked in this format.
