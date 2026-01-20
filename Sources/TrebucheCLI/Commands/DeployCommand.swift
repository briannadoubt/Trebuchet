import ArgumentParser
import Foundation

struct DeployCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Deploy distributed actors to the cloud"
    )

    @Option(name: .shortAndLong, help: "Cloud provider (aws, gcp, azure)")
    var provider: String?

    @Option(name: .shortAndLong, help: "Deployment region")
    var region: String?

    @Option(name: .shortAndLong, help: "Environment name (production, staging)")
    var environment: String?

    @Option(name: .long, help: "Path to trebuche.yaml")
    var config: String?

    @Flag(name: .long, help: "Show what would be deployed without deploying")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load configuration
        terminal.print("Loading configuration...", style: .dim)
        let configLoader = ConfigLoader()
        let trebucheConfig: TrebucheConfig

        do {
            if let configPath = config {
                trebucheConfig = try configLoader.load(file: configPath)
            } else {
                trebucheConfig = try configLoader.load(from: cwd)
            }
        } catch ConfigError.fileNotFound {
            terminal.print("No trebuche.yaml found. Run 'trebuche init' to create one.", style: .error)
            throw ExitCode.failure
        }

        // Discover actors
        terminal.print("")
        terminal.print("Discovering actors...", style: .header)

        let discovery = ActorDiscovery()
        let actors = try discovery.discover(in: cwd)

        if actors.isEmpty {
            terminal.print("No distributed actors found.", style: .warning)
            terminal.print("Make sure your actors use @Trebuchet macro or TrebuchetActorSystem typealias.", style: .dim)
            throw ExitCode.failure
        }

        for actor in actors {
            terminal.print("  ✓ \(actor.name)", style: .success)
            if verbose {
                for method in actor.methods {
                    terminal.print("      → \(method.signature)", style: .dim)
                }
            }
        }

        // Resolve configuration
        let resolvedProvider = provider ?? trebucheConfig.defaults.provider
        let resolvedRegion = region ?? trebucheConfig.defaults.region

        let resolvedConfig = try configLoader.resolve(
            config: trebucheConfig,
            environment: environment,
            discoveredActors: actors
        )

        terminal.print("")

        if dryRun {
            terminal.print("Dry run - would deploy:", style: .header)
            terminal.print("")
            terminal.print("  Provider: \(resolvedProvider)", style: .info)
            terminal.print("  Region: \(resolvedRegion)", style: .info)
            terminal.print("  State Table: \(resolvedConfig.stateTableName)", style: .info)
            terminal.print("  Namespace: \(resolvedConfig.discoveryNamespace)", style: .info)
            terminal.print("")

            for actorConfig in resolvedConfig.actors {
                terminal.print("  Actor: \(actorConfig.name)", style: .info)
                terminal.print("    Memory: \(actorConfig.memory) MB", style: .dim)
                terminal.print("    Timeout: \(actorConfig.timeout)s", style: .dim)
                terminal.print("    Isolated: \(actorConfig.isolated)", style: .dim)
            }
            return
        }

        // Build
        terminal.print("Building for Lambda (arm64)...", style: .header)

        let builder = DockerBuilder()
        let buildResult = try await builder.build(
            projectPath: cwd,
            config: resolvedConfig,
            verbose: verbose,
            terminal: terminal
        )

        terminal.print("  ✓ Package built (\(buildResult.sizeDescription))", style: .success)
        terminal.print("")

        // Generate Terraform
        terminal.print("Generating infrastructure...", style: .header)

        let terraformGenerator = TerraformGenerator()
        let terraformDir = try terraformGenerator.generate(
            config: resolvedConfig,
            actors: actors,
            outputDir: "\(cwd)/.trebuche/terraform"
        )

        terminal.print("  ✓ Terraform generated at \(terraformDir)", style: .success)
        terminal.print("")

        // Deploy
        terminal.print("Deploying to AWS...", style: .header)

        let deployer = TerraformDeployer()
        let deployment = try await deployer.deploy(
            terraformDir: terraformDir,
            region: resolvedRegion,
            verbose: verbose,
            terminal: terminal
        )

        terminal.print("  ✓ Lambda: \(deployment.lambdaArn)", style: .success)
        if let apiUrl = deployment.apiGatewayUrl {
            terminal.print("  ✓ API Gateway: \(apiUrl)", style: .success)
        }
        terminal.print("  ✓ DynamoDB: \(deployment.dynamoDBTable)", style: .success)
        terminal.print("  ✓ CloudMap: \(deployment.cloudMapNamespace)", style: .success)

        terminal.print("")
        terminal.print("Ready! Actors can discover each other automatically.", style: .header)

        // Save deployment info
        let deploymentInfo = DeploymentInfo(
            projectName: resolvedConfig.projectName,
            provider: resolvedProvider,
            region: resolvedRegion,
            lambdaArn: deployment.lambdaArn,
            apiGatewayUrl: deployment.apiGatewayUrl,
            dynamoDBTable: deployment.dynamoDBTable,
            cloudMapNamespace: deployment.cloudMapNamespace,
            deployedAt: Date()
        )

        try saveDeploymentInfo(deploymentInfo, to: "\(cwd)/.trebuche/deployment.json")
    }

    private func saveDeploymentInfo(_ info: DeploymentInfo, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)

        let dirPath = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// Information about a deployment
struct DeploymentInfo: Codable {
    let projectName: String
    let provider: String
    let region: String
    let lambdaArn: String
    let apiGatewayUrl: String?
    let dynamoDBTable: String
    let cloudMapNamespace: String
    let deployedAt: Date
}

/// Result from Terraform deployment
struct TerraformDeploymentResult {
    let lambdaArn: String
    let apiGatewayUrl: String?
    let dynamoDBTable: String
    let cloudMapNamespace: String
}

/// Runs Terraform to deploy infrastructure
struct TerraformDeployer {
    func deploy(
        terraformDir: String,
        region: String,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> TerraformDeploymentResult {
        // Initialize Terraform
        terminal.print("  Initializing Terraform...", style: .dim)
        try await runTerraform(["init"], in: terraformDir, verbose: verbose)

        // Plan
        terminal.print("  Planning infrastructure...", style: .dim)
        try await runTerraform(
            ["plan", "-var", "aws_region=\(region)", "-out=tfplan"],
            in: terraformDir,
            verbose: verbose
        )

        // Apply
        terminal.print("  Applying infrastructure...", style: .dim)
        try await runTerraform(
            ["apply", "-auto-approve", "tfplan"],
            in: terraformDir,
            verbose: verbose
        )

        // Get outputs
        let outputs = try await getTerraformOutputs(in: terraformDir)

        return TerraformDeploymentResult(
            lambdaArn: outputs["lambda_arn"] ?? "unknown",
            apiGatewayUrl: outputs["api_gateway_url"],
            dynamoDBTable: outputs["dynamodb_table"] ?? "unknown",
            cloudMapNamespace: outputs["cloudmap_namespace"] ?? "unknown"
        )
    }

    private func runTerraform(_ args: [String], in directory: String, verbose: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["terraform"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.terraformFailed("Terraform command failed with status \(process.terminationStatus)")
        }
    }

    private func getTerraformOutputs(in directory: String) async throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["terraform", "output", "-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var outputs: [String: String] = [:]
        for (key, value) in json {
            if let dict = value as? [String: Any], let valueStr = dict["value"] as? String {
                outputs[key] = valueStr
            }
        }

        return outputs
    }
}

/// CLI errors
enum CLIError: Error, CustomStringConvertible {
    case buildFailed(String)
    case terraformFailed(String)
    case deploymentFailed(String)
    case configurationError(String)

    var description: String {
        switch self {
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .terraformFailed(let msg): return "Terraform failed: \(msg)"
        case .deploymentFailed(let msg): return "Deployment failed: \(msg)"
        case .configurationError(let msg): return "Configuration error: \(msg)"
        }
    }
}
