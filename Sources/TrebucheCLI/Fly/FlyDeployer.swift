import Foundation

/// Deploys Trebuche actors to Fly.io
struct FlyDeployer {
    let terminal: Terminal

    init(terminal: Terminal = Terminal()) {
        self.terminal = terminal
    }

    /// Deploy to Fly.io
    /// - Parameters:
    ///   - config: Resolved configuration
    ///   - actors: Discovered actors
    ///   - projectPath: Path to the project
    ///   - appName: Fly.io app name (optional, uses config.projectName if not provided)
    ///   - region: Primary region (optional, defaults to auto-detect)
    ///   - verbose: Enable verbose output
    /// - Returns: Deployment result
    func deploy(
        config: ResolvedConfig,
        actors: [ActorMetadata],
        projectPath: String,
        appName: String? = nil,
        region: String? = nil,
        verbose: Bool = false
    ) async throws -> FlyDeploymentResult {
        // Check if flyctl is installed
        try checkFlyctl()

        // Generate fly.toml
        terminal.print("Generating Fly.io configuration...", style: .dim)
        let flyToml = generateFlyToml(config: config, appName: appName, region: region)
        try flyToml.write(toFile: "\(projectPath)/fly.toml", atomically: true, encoding: .utf8)
        terminal.print("  ✓ Generated fly.toml", style: .success)

        // Generate Dockerfile
        let dockerfile = generateDockerfile(config: config)
        try dockerfile.write(toFile: "\(projectPath)/Dockerfile", atomically: true, encoding: .utf8)
        terminal.print("  ✓ Generated Dockerfile", style: .success)

        // Generate .dockerignore
        let dockerignore = generateDockerignore()
        try dockerignore.write(toFile: "\(projectPath)/.dockerignore", atomically: true, encoding: .utf8)
        terminal.print("  ✓ Generated .dockerignore", style: .success)

        terminal.print("")

        // Check if app exists
        let resolvedAppName = appName ?? config.projectName
        let appExists = try await checkAppExists(resolvedAppName)

        if !appExists {
            // Create new app
            terminal.print("Creating Fly.io app '\(resolvedAppName)'...", style: .header)
            try await createApp(resolvedAppName, region: region, verbose: verbose)
            terminal.print("  ✓ App created", style: .success)
        } else {
            terminal.print("Using existing Fly.io app '\(resolvedAppName)'", style: .dim)
        }

        terminal.print("")

        // Set up PostgreSQL if needed
        var databaseUrl: String?
        if config.stateType == "postgresql" || config.stateType == "postgres" {
            terminal.print("Setting up PostgreSQL...", style: .header)
            databaseUrl = try await setupPostgreSQL(appName: resolvedAppName, verbose: verbose)
            terminal.print("  ✓ PostgreSQL configured", style: .success)
            terminal.print("")
        }

        // Deploy
        terminal.print("Deploying to Fly.io...", style: .header)
        terminal.print("  Building and pushing Docker image...", style: .dim)
        try await runFly(["deploy", "--app", resolvedAppName], in: projectPath, verbose: verbose)

        terminal.print("  ✓ Deployed successfully", style: .success)
        terminal.print("")

        // Get app info
        let appInfo = try await getAppInfo(resolvedAppName)

        return FlyDeploymentResult(
            appName: resolvedAppName,
            region: appInfo.region,
            hostname: appInfo.hostname,
            status: appInfo.status,
            databaseUrl: databaseUrl
        )
    }

    /// Undeploy from Fly.io
    func undeploy(appName: String, verbose: Bool = false) async throws {
        terminal.print("Destroying Fly.io app '\(appName)'...", style: .header)

        // Confirm destruction
        terminal.print("⚠️  This will permanently delete the app and all its data.", style: .warning)
        terminal.print("Type the app name to confirm: ", style: .dim)

        guard let input = readLine(), input == appName else {
            terminal.print("Cancelled.", style: .dim)
            return
        }

        try await runFly(["apps", "destroy", appName, "--yes"], in: ".", verbose: verbose)
        terminal.print("  ✓ App destroyed", style: .success)
    }

    // MARK: - Private Helpers

    private func checkFlyctl() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "flyctl"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            terminal.print("❌ flyctl not found. Install it:", style: .error)
            terminal.print("   curl -L https://fly.io/install.sh | sh", style: .dim)
            terminal.print("   or: brew install flyctl", style: .dim)
            throw FlyError.flyctlNotInstalled
        }
    }

    private func checkAppExists(_ appName: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["flyctl", "apps", "list", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }

        return apps.contains { ($0["Name"] as? String) == appName }
    }

    private func createApp(_ appName: String, region: String?, verbose: Bool) async throws {
        var args = ["apps", "create", appName]
        if let region = region {
            args.append(contentsOf: ["--region", region])
        }
        try await runFly(args, in: ".", verbose: verbose)
    }

    private func setupPostgreSQL(appName: String, verbose: Bool) async throws -> String {
        let dbName = "\(appName)-db"

        // Check if database exists
        let dbExists = try await checkAppExists(dbName)

        if !dbExists {
            // Create PostgreSQL database
            terminal.print("  Creating PostgreSQL database...", style: .dim)
            try await runFly([
                "postgres", "create",
                "--name", dbName,
                "--region", "primary",  // Use same region as app
                "--vm-size", "shared-cpu-1x",
                "--volume-size", "1"  // 1GB minimum
            ], in: ".", verbose: verbose)
        }

        // Attach database to app
        terminal.print("  Attaching database to app...", style: .dim)
        try await runFly(["postgres", "attach", dbName, "--app", appName], in: ".", verbose: verbose)

        // Get connection string (will be in DATABASE_URL env var)
        return "postgresql://\(appName)-db.internal:5432/\(appName)"
    }

    private func getAppInfo(_ appName: String) async throws -> FlyAppInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["flyctl", "status", "--app", appName, "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FlyError.commandFailed("Failed to get app info")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlyError.invalidResponse
        }

        let hostname = json["Hostname"] as? String ?? "\(appName).fly.dev"
        let region = (json["Allocations"] as? [[String: Any]])?.first?["Region"] as? String ?? "unknown"
        let status = json["Status"] as? String ?? "unknown"

        return FlyAppInfo(
            region: region,
            hostname: hostname,
            status: status
        )
    }

    private func runFly(_ args: [String], in directory: String, verbose: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["flyctl"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FlyError.commandFailed("flyctl \(args.joined(separator: " ")) failed")
        }
    }

    // MARK: - Configuration Generation

    private func generateFlyToml(config: ResolvedConfig, appName: String?, region: String?) -> String {
        let resolvedAppName = appName ?? config.projectName
        let port = 8080

        var toml = """
        # fly.toml - Trebuche deployment configuration
        # Generated by trebuche CLI

        app = "\(resolvedAppName)"
        primary_region = "\(region ?? "auto")"

        [build]
          dockerfile = "Dockerfile"

        [env]
          PORT = "\(port)"

        [[services]]
          internal_port = \(port)
          protocol = "tcp"
          auto_stop_machines = true
          auto_start_machines = true
          min_machines_running = 0

          [[services.ports]]
            port = 80
            handlers = ["http"]
            force_https = true

          [[services.ports]]
            port = 443
            handlers = ["http", "tls"]

          [services.concurrency]
            type = "connections"
            hard_limit = 1000
            soft_limit = 500

        [[vm]]
          cpu_kind = "shared"
          cpus = 1
          memory_mb = \(config.actors.map(\.memory).max() ?? 512)

        """

        return toml
    }

    private func generateDockerfile(config: ResolvedConfig) -> String {
        """
        # Swift 6.2 on Ubuntu 24.04
        FROM swift:6.2-jammy as build

        WORKDIR /build

        # Copy package files
        COPY Package.swift Package.resolved ./

        # Resolve dependencies
        RUN swift package resolve

        # Copy source code
        COPY Sources ./Sources

        # Build release binary
        RUN swift build -c release --static-swift-stdlib

        # Runtime stage
        FROM ubuntu:24.04

        # Install runtime dependencies
        RUN apt-get update && apt-get install -y \\
            libcurl4 \\
            libxml2 \\
            && rm -rf /var/lib/apt/lists/*

        WORKDIR /app

        # Copy built binary
        COPY --from=build /build/.build/release/TrebucheDemo /app/TrebucheDemo

        # Create non-root user
        RUN useradd -m -u 1000 trebuche
        USER trebuche

        # Expose port
        EXPOSE 8080

        # Run the server
        CMD ["./TrebucheDemo"]

        """
    }

    private func generateDockerignore() -> String {
        """
        .build
        .swiftpm
        .git
        .github
        .trebuche
        .DS_Store
        *.xcodeproj
        *.xcworkspace
        .vscode
        fly.toml
        terraform
        node_modules

        """
    }
}

// MARK: - Types

struct FlyDeploymentResult {
    let appName: String
    let region: String
    let hostname: String
    let status: String
    let databaseUrl: String?
}

struct FlyAppInfo {
    let region: String
    let hostname: String
    let status: String
}

enum FlyError: Error, CustomStringConvertible {
    case flyctlNotInstalled
    case commandFailed(String)
    case invalidResponse

    var description: String {
        switch self {
        case .flyctlNotInstalled:
            return "flyctl CLI not installed"
        case .commandFailed(let message):
            return "Fly.io command failed: \(message)"
        case .invalidResponse:
            return "Invalid response from Fly.io API"
        }
    }
}
