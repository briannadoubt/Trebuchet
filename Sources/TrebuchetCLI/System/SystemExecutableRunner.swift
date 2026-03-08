import Foundation
import Trebuchet

struct SystemExecutableRunner {
    func runDev(
        projectPath: String,
        product: String,
        host: String,
        port: UInt16,
        verbose: Bool
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = [
            "swift", "run",
            "--package-path", projectPath,
            product,
            "--",
            "--_trebuchet-mode", "dev",
            "--_trebuchet-host", host,
            "--_trebuchet-port", String(port),
        ]

        if verbose {
            arguments.append("--_trebuchet-verbose")
        }

        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed(
                "Dev executable '\(product)' exited with status \(process.terminationStatus)"
            )
        }
    }

    func buildPlan(
        projectPath: String,
        product: String,
        provider: String?,
        environment: String?
    ) throws -> DeploymentPlan {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = [
            "swift", "run",
            "--package-path", projectPath,
            product,
            "--",
            "--_trebuchet-mode", "plan",
        ]

        if let provider {
            arguments.append(contentsOf: ["--_trebuchet-provider", provider])
        }

        if let environment {
            arguments.append(contentsOf: ["--_trebuchet-environment", environment])
        }

        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.commandFailed("Failed to query deployment plan from executable '\(product)'. \(errorText)")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()

        do {
            return try decoder.decode(DeploymentPlan.self, from: outputData)
        } catch {
            let outputText = String(data: outputData, encoding: .utf8) ?? ""
            throw CLIError.commandFailed(
                "Could not parse deployment plan JSON from executable '\(product)'. Output was:\n\(outputText)"
            )
        }
    }
}
