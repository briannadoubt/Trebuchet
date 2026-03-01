import Foundation

/// Information about an AWS deployment
public struct DeploymentInfo: Codable {
    let projectName: String
    let provider: String
    let region: String
    let lambdaArn: String
    let apiGatewayUrl: String?
    let dynamoDBTable: String
    let cloudMapNamespace: String
    let deployedAt: Date
}

/// Information about a Fly.io deployment
public struct FlyDeploymentInfo: Codable {
    let projectName: String
    let provider: String
    let appName: String
    let hostname: String
    let region: String
    let databaseUrl: String?
    let deployedAt: Date
}

/// Result from Terraform deployment
public struct TerraformDeploymentResult {
    let lambdaArn: String
    let apiGatewayUrl: String?
    let dynamoDBTable: String
    let cloudMapNamespace: String
}

/// Runs Terraform to deploy infrastructure
public struct TerraformDeployer {
    func deploy(
        terraformDir: String,
        region: String,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> TerraformDeploymentResult {
        terminal.print("  Initializing Terraform...", style: .dim)
        try await runTerraform(["init"], in: terraformDir, verbose: verbose)

        terminal.print("  Planning infrastructure...", style: .dim)
        try await runTerraform(
            ["plan", "-var", "aws_region=\(region)", "-out=tfplan"],
            in: terraformDir,
            verbose: verbose
        )

        terminal.print("  Applying infrastructure...", style: .dim)
        try await runTerraform(
            ["apply", "-auto-approve", "tfplan"],
            in: terraformDir,
            verbose: verbose
        )

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
            throw CLIError.commandFailed("Terraform command failed: terraform \(args.joined(separator: " "))")
        }
    }

    private func getTerraformOutputs(in directory: String) async throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["terraform", "output", "-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("Failed to get Terraform outputs")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw CLIError.commandFailed("Invalid Terraform output JSON")
        }

        var outputs: [String: String] = [:]
        for (key, value) in json {
            outputs[key] = value["value"] as? String
        }

        return outputs
    }
}
