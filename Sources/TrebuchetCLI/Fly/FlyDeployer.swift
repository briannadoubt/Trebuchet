import Foundation

/// Deploys Trebuchet actors to Fly.io
public struct FlyDeployer {
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

        // Validate state type
        if let stateType = config.stateType {
            guard ["memory", "postgresql", "postgres"].contains(stateType) else {
                throw FlyError.invalidStateType(stateType)
            }
        }

        // Generate server package with state store support
        terminal.print("Generating server package...", style: .dim)

        // Create TrebuchetConfig from ResolvedConfig for generator
        let trebuchetConfig = TrebuchetConfig(
            name: config.projectName,
            defaults: DefaultSettings(
                provider: config.provider,
                region: config.region
            ),
            state: config.stateType.map { StateConfig(type: $0) }
        )

        let serverGen = FlyServerGenerator(terminal: terminal)
        try serverGen.generate(
            config: trebuchetConfig,
            actors: actors,
            projectPath: projectPath
        )
        terminal.print("  ✓ Server package generated", style: .success)

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
            terminal.print("⚠️  PostgreSQL on Fly.io requires a paid account", style: .warning)
            terminal.print("   If you have a free account, consider using in-memory state or an external database", style: .dim)
            terminal.print("")
            terminal.print("Setting up PostgreSQL...", style: .header)
            do {
                databaseUrl = try await setupPostgreSQL(appName: resolvedAppName, verbose: verbose)
                terminal.print("  ✓ PostgreSQL configured", style: .success)
                terminal.print("")
            } catch {
                terminal.print("  ⚠️  PostgreSQL setup failed (may require paid account)", style: .warning)
                terminal.print("     Continuing without database - actors will use in-memory state", style: .dim)
                terminal.print("")
            }
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
        // Note: flyctl apps create doesn't accept --region flag
        // Region is specified in fly.toml and used during deployment

        // Get user's personal org to create the app in
        let org = try await getCurrentOrg()
        let args = ["apps", "create", appName, "--org", org]
        try await runFly(args, in: ".", verbose: verbose)
    }

    private func getCurrentOrg() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["flyctl", "orgs", "list", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FlyError.commandFailed("Failed to get Fly.io organizations. Make sure you're logged in with: flyctl auth login")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Fly.io returns JSON as: { "slug": "name", "slug2": "name2" }
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let firstSlug = orgs.keys.first else {
            throw FlyError.commandFailed("No Fly.io organizations found. Create one at: https://fly.io/dashboard")
        }

        // Prefer personal org if it exists
        return orgs["personal"] != nil ? "personal" : firstSlug
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

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let errorMessage = errorOutput.isEmpty
                ? "flyctl \(args.joined(separator: " ")) failed"
                : "flyctl \(args.joined(separator: " ")) failed:\n\(errorOutput)"

            throw FlyError.commandFailed(errorMessage)
        }
    }

    // MARK: - Configuration Generation

    private func generateFlyToml(config: ResolvedConfig, appName: String?, region: String?) -> String {
        let resolvedAppName = appName ?? config.projectName
        let port = 8080

        // Use Fly.io v2 format (free-tier friendly)
        let toml = """
        # fly.toml - Trebuchet deployment configuration
        # Generated by trebuchet CLI

        app = "\(resolvedAppName)"
        primary_region = "\(region ?? "auto")"

        [build]
          dockerfile = "Dockerfile"

        [env]
          PORT = "\(port)"

        [http_service]
          internal_port = \(port)
          force_https = true
          auto_stop_machines = "stop"
          auto_start_machines = true
          min_machines_running = 0
          processes = ["app"]

        [[vm]]
          memory = "\(config.actors.map(\.memory).max() ?? 256)mb"
          cpu_kind = "shared"
          cpus = 1

        """

        return toml
    }

    private func generateDockerfile(config: ResolvedConfig) -> String {
        """
        # Swift 6.2 on Ubuntu 24.04
        FROM swift:6.2-jammy as build

        WORKDIR /build

        # Copy generated server package
        COPY .trebuchet/fly-server ./

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

        # Copy built binary (from generated server package)
        COPY --from=build /build/.build/release/TrebuchetAutoServer /app/server

        # Create non-root user
        RUN useradd -m -u 1000 trebuchet
        USER trebuchet

        # Expose port
        EXPOSE 8080

        # Run the server
        CMD ["./server"]

        """
    }

    private func generateDockerignore() -> String {
        """
        .build
        .swiftpm
        .git
        .github
        .trebuchet
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

public struct FlyDeploymentResult {
    let appName: String
    let region: String
    let hostname: String
    let status: String
    let databaseUrl: String?
}

public struct FlyAppInfo {
    let region: String
    let hostname: String
    let status: String
}

public enum FlyError: Error, CustomStringConvertible {
    case flyctlNotInstalled
    case commandFailed(String)
    case invalidResponse
    case invalidStateType(String)

    public var description: String {
        switch self {
        case .flyctlNotInstalled:
            return "flyctl CLI not installed"
        case .commandFailed(let message):
            return "Fly.io command failed: \(message)"
        case .invalidResponse:
            return "Invalid response from Fly.io API"
        case .invalidStateType(let type):
            return "Invalid state type '\(type)' for Fly.io. Supported types: memory, postgresql, postgres"
        }
    }
}
