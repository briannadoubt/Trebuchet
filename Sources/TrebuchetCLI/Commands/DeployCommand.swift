import ArgumentParser
import Foundation
import Trebuchet

public struct DeployCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Deploy a System executable to the cloud"
    )

    @Argument(help: "Path to the Swift package project")
    public var projectPath: String = "."

    @Option(name: .shortAndLong, help: "Cloud provider (aws, fly)")
    public var provider: String?

    @Option(name: .shortAndLong, help: "Deployment region override")
    public var region: String?

    @Option(name: .shortAndLong, help: "Environment name (production, staging)")
    public var environment: String?

    @Option(name: .long, help: "Path to trebuchet.yaml (deprecated; ignored in topology-first mode)")
    public var config: String?

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

        if config != nil {
            terminal.print("`--config` is ignored in topology-first mode.", style: .warning)
        }

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
