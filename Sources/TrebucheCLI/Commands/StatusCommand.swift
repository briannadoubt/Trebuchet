import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show deployment status"
    )

    @Option(name: .long, help: "Path to deployment info")
    var deployment: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load deployment info
        let deploymentPath = deployment ?? "\(cwd)/.trebuche/deployment.json"

        guard FileManager.default.fileExists(atPath: deploymentPath) else {
            terminal.print("No deployment found.", style: .warning)
            terminal.print("Run 'trebuche deploy' first.", style: .dim)
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: deploymentPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(DeploymentInfo.self, from: data)

        terminal.print("")
        terminal.print("Deployment Status: \(info.projectName)", style: .header)
        terminal.print("")

        terminal.print("Provider: \(info.provider)", style: .info)
        terminal.print("Region: \(info.region)", style: .info)
        terminal.print("")

        terminal.print("Resources:", style: .header)
        terminal.print("  Lambda: \(info.lambdaArn)", style: .info)
        if let apiUrl = info.apiGatewayUrl {
            terminal.print("  API Gateway: \(apiUrl)", style: .info)
        }
        terminal.print("  DynamoDB: \(info.dynamoDBTable)", style: .info)
        terminal.print("  CloudMap: \(info.cloudMapNamespace)", style: .info)
        terminal.print("")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        terminal.print("Deployed: \(formatter.string(from: info.deployedAt))", style: .dim)

        if verbose {
            terminal.print("")
            terminal.print("Checking Lambda status...", style: .dim)

            // Get Lambda function status
            let status = try await getLambdaStatus(arn: info.lambdaArn, region: info.region)
            terminal.print("  State: \(status.state)", style: status.state == "Active" ? .success : .warning)
            terminal.print("  Last Modified: \(status.lastModified)", style: .dim)
            terminal.print("  Memory: \(status.memorySize) MB", style: .dim)
            terminal.print("  Runtime: \(status.runtime)", style: .dim)
        }
    }

    struct LambdaStatus {
        let state: String
        let lastModified: String
        let memorySize: Int
        let runtime: String
    }

    private func getLambdaStatus(arn: String, region: String) async throws -> LambdaStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "aws", "lambda", "get-function",
            "--function-name", arn,
            "--region", region,
            "--output", "json"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["Configuration"] as? [String: Any] else {
            return LambdaStatus(
                state: "Unknown",
                lastModified: "Unknown",
                memorySize: 0,
                runtime: "Unknown"
            )
        }

        return LambdaStatus(
            state: config["State"] as? String ?? "Unknown",
            lastModified: config["LastModified"] as? String ?? "Unknown",
            memorySize: config["MemorySize"] as? Int ?? 0,
            runtime: config["Runtime"] as? String ?? "Unknown"
        )
    }
}
