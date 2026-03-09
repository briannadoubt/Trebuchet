import ArgumentParser
import Foundation
import Trebuchet

public struct DeployCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Deploy a System executable from a Swift package to the cloud"
    )

    @Argument(help: "Path to the Swift package containing the @main ...: System executable")
    public var projectPath: String = "."

    @Option(name: .shortAndLong, help: "Cloud provider (aws, fly)")
    public var provider: String?

    @Option(name: .shortAndLong, help: "Deployment region override")
    public var region: String?

    @Option(name: .shortAndLong, help: "Environment name (production, staging)")
    public var environment: String?

    @Option(name: .long, help: "Executable product to deploy")
    public var product: String?

    @Flag(name: .long, help: "Show what would be deployed without deploying")
    public var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectDirectory = try resolveProjectDirectory(projectPath)

        let resolver = SystemProductResolver()
        let resolvedProduct = try resolver.resolve(projectPath: projectDirectory, explicitProduct: product)

        let runner = SystemExecutableRunner()
        var plan = try runner.buildPlan(
            projectPath: projectDirectory,
            product: resolvedProduct.product,
            provider: nil,
            environment: environment
        )

        let selectedProvider = (provider?.lowercased() ?? defaultProvider(from: plan))
        plan.provider = selectedProvider
        plan.environment = environment
        plan = filterPlan(plan, for: selectedProvider)

        if let region {
            applyRegionOverride(&plan, provider: selectedProvider, region: region)
        }

        if dryRun {
            printDryRun(plan: plan, terminal: terminal)
            return
        }

        printDatabaseGuidance(plan: plan, provider: selectedProvider, terminal: terminal)

        if verbose, !plan.warnings.isEmpty {
            terminal.print("Deployment merge warnings:", style: .warning)
            for warning in plan.warnings {
                terminal.print("  • \(warning)", style: .dim)
            }
            terminal.print("", style: .info)
        }

        let providerImpl = try DeploymentProviderRegistry().provider(for: selectedProvider)
        let result = try await providerImpl.deploy(
            plan: plan,
            projectPath: projectDirectory,
            executableProduct: resolvedProduct.product,
            verbose: verbose,
            terminal: terminal
        )

        try saveDeploymentInfo(
            result.deploymentInfo,
            to: "\(projectDirectory)/.trebuchet/deployment.json"
        )

        terminal.print("", style: .info)
        terminal.print("Deployment successful (\(result.provider)).", style: .header)
        for line in result.summaryLines {
            terminal.print("  \(line)", style: .success)
        }
    }

    private func resolveProjectDirectory(_ path: String) throws -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL

        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.configurationError("Project path does not exist or is not a directory: \(path)")
        }

        return url.path
    }

    private func defaultProvider(from plan: DeploymentPlan) -> String {
        if plan.actors.contains(where: { $0.aws != nil }) {
            return "aws"
        }
        if plan.actors.contains(where: { $0.fly != nil }) {
            return "fly"
        }
        return "fly"
    }

    private func filterPlan(_ plan: DeploymentPlan, for provider: String) -> DeploymentPlan {
        var copy = plan
        copy.provider = provider

        copy.actors = plan.actors.map { actor in
            var next = actor
            switch provider {
            case "aws":
                next.fly = nil
            case "fly":
                next.aws = nil
            default:
                break
            }
            return next
        }

        return copy
    }

    private func applyRegionOverride(_ plan: inout DeploymentPlan, provider: String, region: String) {
        for idx in plan.actors.indices {
            switch provider {
            case "aws":
                var aws = plan.actors[idx].aws ?? AWSDeploymentOptions()
                aws.region = region
                plan.actors[idx].aws = aws
            case "fly":
                var fly = plan.actors[idx].fly ?? FlyDeploymentOptions()
                fly.region = region
                plan.actors[idx].fly = fly
            default:
                break
            }
        }
    }

    private func printDryRun(plan: DeploymentPlan, terminal: Terminal) {
        terminal.print("", style: .info)
        terminal.print("Dry run - would deploy:", style: .header)
        terminal.print("", style: .info)
        terminal.print("  System: \(plan.systemName)", style: .info)
        terminal.print("  Provider: \(plan.provider ?? "auto")", style: .info)
        if let env = plan.environment {
            terminal.print("  Environment: \(env)", style: .info)
        }
        terminal.print("", style: .info)

        for actor in plan.actors {
            terminal.print("  Actor: \(actor.actorType)", style: .info)
            terminal.print("    Exposed as: \(actor.exposeName)", style: .dim)
            if !actor.clusterPath.isEmpty {
                terminal.print("    Clusters: \(actor.clusterPath.joined(separator: " -> "))", style: .dim)
            }
            if let state = actor.state {
                terminal.print("    State: \(stateLabel(state))", style: .dim)
            }
            if let aws = actor.aws {
                terminal.print("    AWS: region=\(aws.region ?? "default") memory=\(aws.memory.map(String.init) ?? "512") timeout=\(aws.timeout.map(String.init) ?? "30")", style: .dim)
            }
            if let fly = actor.fly {
                terminal.print("    Fly: app=\(fly.app ?? "<auto>") region=\(fly.region ?? "iad") memoryMB=\(fly.memoryMB.map(String.init) ?? "default")", style: .dim)
            }
        }

        if !plan.warnings.isEmpty {
            terminal.print("", style: .info)
            terminal.print("Warnings:", style: .warning)
            for warning in plan.warnings {
                terminal.print("  • \(warning)", style: .dim)
            }
        }

        let selectedProvider = plan.provider ?? "fly"
        printDatabaseGuidance(plan: plan, provider: selectedProvider, terminal: terminal)
    }

    private func stateLabel(_ state: StateConfiguration) -> String {
        switch state {
        case .memory: return "memory (no persistence)"
        case .dynamoDB(let table): return "DynamoDB (table: \(table))"
        case .postgres(let url): return url != nil ? "PostgreSQL (configured)" : "PostgreSQL (no URL configured)"
        case .surrealDB(let url): return url != nil ? "SurrealDB (configured)" : "SurrealDB (no URL configured)"
        case .sqlite(let path, let shards):
            let pathLabel = path ?? "default path"
            let shardLabel = shards == 1 ? "" : ", \(shards) shards"
            return "SQLite (\(pathLabel)\(shardLabel))"
        }
    }

    private func printDatabaseGuidance(plan: DeploymentPlan, provider: String, terminal: Terminal) {
        let appName = plan.systemName
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        for actor in plan.actors {
            guard let state = actor.state else { continue }

            switch state {
            case .memory, .dynamoDB, .sqlite:
                // memory needs nothing; DynamoDB is auto-provisioned via Terraform
                continue

            case .postgres(let url) where url != nil:
                continue

            case .surrealDB(let url) where url != nil:
                continue

            case .postgres:
                terminal.print("", style: .info)
                terminal.print("Actor \(actor.actorType) uses PostgreSQL but no database URL is configured.", style: .warning)
                terminal.print("", style: .info)

                switch provider {
                case "fly":
                    let dbName = "\(appName)-db"
                    terminal.print("  To provision on Fly.io:", style: .info)
                    terminal.print("    fly postgres create --name \(dbName) --region iad", style: .dim)
                    terminal.print("    fly postgres attach \(dbName) --app \(appName)", style: .dim)
                    terminal.print("", style: .info)
                    terminal.print("  This sets DATABASE_URL automatically on your app.", style: .dim)

                case "aws":
                    terminal.print("  To provision on AWS:", style: .info)
                    terminal.print("    Create an RDS PostgreSQL instance in your VPC", style: .dim)
                    terminal.print("    Then configure the connection:", style: .dim)
                    terminal.print("      .state(.postgres(databaseURL: \"postgresql://user:pass@host:5432/db\"))", style: .dim)

                default:
                    terminal.print("  Configure the connection URL:", style: .info)
                    terminal.print("    .state(.postgres(databaseURL: \"postgresql://user:pass@host:5432/db\"))", style: .dim)
                }
                terminal.print("", style: .info)

            case .surrealDB:
                terminal.print("", style: .info)
                terminal.print("Actor \(actor.actorType) uses SurrealDB but no database URL is configured.", style: .warning)
                terminal.print("", style: .info)

                switch provider {
                case "fly":
                    let dbAppName = "\(appName)-surrealdb"
                    terminal.print("  To provision on Fly.io:", style: .info)
                    terminal.print("    fly apps create \(dbAppName)", style: .dim)
                    terminal.print("    fly volumes create surrealdb_data --app \(dbAppName) --size 1 --region iad", style: .dim)
                    terminal.print("    fly deploy --image surrealdb/surrealdb:latest --app \(dbAppName)", style: .dim)
                    terminal.print("    fly secrets set SURREALDB_URL=ws://\(dbAppName).internal:8000 --app \(appName)", style: .dim)
                    terminal.print("", style: .info)
                    terminal.print("  Then configure the connection:", style: .dim)
                    terminal.print("    .state(.surrealDB(url: \"ws://\(dbAppName).internal:8000\"))", style: .dim)

                case "aws":
                    terminal.print("  SurrealDB is not a managed AWS service. Options:", style: .info)
                    terminal.print("    - Run SurrealDB on ECS/Fargate with an EBS volume", style: .dim)
                    terminal.print("    - Use Surreal Cloud (https://surrealdb.com/cloud)", style: .dim)
                    terminal.print("    - Consider .state(.dynamoDB(table: \"...\")) for native AWS integration", style: .dim)
                    terminal.print("", style: .info)
                    terminal.print("  Then configure the connection:", style: .dim)
                    terminal.print("    .state(.surrealDB(url: \"ws://your-surrealdb-host:8000\"))", style: .dim)

                default:
                    terminal.print("  Configure the connection URL:", style: .info)
                    terminal.print("    .state(.surrealDB(url: \"ws://your-surrealdb-host:8000\"))", style: .dim)
                }
                terminal.print("", style: .info)
            }
        }
    }

    private func saveDeploymentInfo(_ data: Data, to path: String) throws {
        let dirPath = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

public enum CLIError: Error, CustomStringConvertible {
    case commandFailed(String)
    case buildFailed(String)
    case configurationError(String)

    public var description: String {
        switch self {
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .configurationError(let msg): return "Configuration error: \(msg)"
        }
    }
}
