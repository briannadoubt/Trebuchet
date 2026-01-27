import ArgumentParser
import Foundation

struct UndeployCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undeploy",
        abstract: "Remove deployed infrastructure"
    )

    @Option(name: .long, help: "Path to deployment info")
    var deployment: String?

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load deployment info
        let deploymentPath = deployment ?? "\(cwd)/.trebuche/deployment.json"
        let terraformDir = "\(cwd)/.trebuche/terraform"

        guard FileManager.default.fileExists(atPath: deploymentPath) else {
            terminal.print("No deployment found.", style: .warning)
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: deploymentPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Detect provider from deployment info
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = jsonObj["provider"] as? String else {
            terminal.print("Invalid deployment info.", style: .error)
            throw ExitCode.failure
        }

        terminal.print("")

        switch provider.lowercased() {
        case "fly", "fly.io":
            let info = try decoder.decode(FlyDeploymentInfo.self, from: data)
            try await undeployFromFly(info: info, force: force, verbose: verbose, terminal: terminal)

        case "aws":
            let info = try decoder.decode(DeploymentInfo.self, from: data)
            try await undeployFromAWS(
                info: info,
                terraformDir: terraformDir,
                force: force,
                verbose: verbose,
                terminal: terminal
            )

        default:
            terminal.print("Unknown provider: \(provider)", style: .error)
            throw ExitCode.failure
        }

        // Clean up local files
        try? FileManager.default.removeItem(atPath: deploymentPath)

        terminal.print("")
        terminal.print("✓ Infrastructure destroyed", style: .success)
    }

    // MARK: - Fly.io Undeploy

    private func undeployFromFly(
        info: FlyDeploymentInfo,
        force: Bool,
        verbose: Bool,
        terminal: Terminal
    ) async throws {
        terminal.print("Undeploying from Fly.io: \(info.projectName)", style: .header)
        terminal.print("")

        terminal.print("This will destroy:", style: .warning)
        terminal.print("  • App: \(info.appName)", style: .dim)
        terminal.print("  • URL: https://\(info.hostname)", style: .dim)
        if let dbUrl = info.databaseUrl {
            terminal.print("  • Database: \(dbUrl)", style: .dim)
        }
        terminal.print("")

        if !force {
            terminal.print("Are you sure? Type 'yes' to confirm: ", style: .warning, terminator: "")
            guard let response = readLine(), response.lowercased() == "yes" else {
                terminal.print("Cancelled.", style: .info)
                return
            }
        }

        terminal.print("")
        terminal.print("Destroying infrastructure...", style: .header)

        let deployer = FlyDeployer(terminal: terminal)
        try await deployer.undeploy(appName: info.appName, verbose: verbose)
    }

    // MARK: - AWS Undeploy

    private func undeployFromAWS(
        info: DeploymentInfo,
        terraformDir: String,
        force: Bool,
        verbose: Bool,
        terminal: Terminal
    ) async throws {
        terminal.print("Undeploying from AWS: \(info.projectName)", style: .header)
        terminal.print("")

        terminal.print("This will destroy:", style: .warning)
        terminal.print("  • Lambda: \(info.lambdaArn)", style: .dim)
        if let apiUrl = info.apiGatewayUrl {
            terminal.print("  • API Gateway: \(apiUrl)", style: .dim)
        }
        terminal.print("  • DynamoDB: \(info.dynamoDBTable)", style: .dim)
        terminal.print("  • CloudMap: \(info.cloudMapNamespace)", style: .dim)
        terminal.print("")

        if !force {
            terminal.print("Are you sure? Type 'yes' to confirm: ", style: .warning, terminator: "")
            guard let response = readLine(), response.lowercased() == "yes" else {
                terminal.print("Cancelled.", style: .info)
                return
            }
        }

        terminal.print("")
        terminal.print("Destroying infrastructure...", style: .header)

        // Run terraform destroy
        guard FileManager.default.fileExists(atPath: terraformDir) else {
            terminal.print("Terraform directory not found. Manual cleanup may be required.", style: .error)
            throw ExitCode.failure
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "terraform", "destroy",
            "-auto-approve",
            "-var", "aws_region=\(info.region)"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: terraformDir)

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            terminal.print("Terraform destroy failed.", style: .error)
            throw ExitCode.failure
        }
    }
}
