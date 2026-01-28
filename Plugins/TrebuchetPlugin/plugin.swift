import Foundation
import PackagePlugin

@main
struct TrebuchetPlugin: CommandPlugin {
    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        // Get the TrebuchetCLI executable tool from this package
        guard let tool = try? context.tool(named: "TrebuchetCLI") else {
            print("Error: Could not find 'TrebuchetCLI' tool. Make sure the package is built.")
            throw PluginError.toolNotFound
        }

        let toolURL = tool.url
        let workingDirectory = context.package.directoryURL

        try runTool(
            toolURL: toolURL,
            workingDirectory: workingDirectory,
            arguments: arguments
        )
    }
}

// MARK: - Xcode Support

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension TrebuchetPlugin: XcodeCommandPlugin {
    func performCommand(
        context: XcodePluginContext,
        arguments: [String]
    ) throws {
        // Get the TrebuchetCLI executable tool from this package
        guard let tool = try? context.tool(named: "TrebuchetCLI") else {
            print("Error: Could not find 'TrebuchetCLI' tool. Make sure the package is built.")
            throw PluginError.toolNotFound
        }

        let toolURL = tool.url
        let workingDirectory = context.xcodeProject.directoryURL

        try runTool(
            toolURL: toolURL,
            workingDirectory: workingDirectory,
            arguments: arguments
        )
    }
}
#endif

// MARK: - Shared Implementation

extension TrebuchetPlugin {
    private func runTool(
        toolURL: URL,
        workingDirectory: URL,
        arguments: [String]
    ) throws {
        // Set working directory to project root
        let workingPath = workingDirectory.path
        FileManager.default.changeCurrentDirectoryPath(workingPath)

        // Create process
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        // Set environment to pass project context
        var environment = ProcessInfo.processInfo.environment
        environment["TREBUCHET_PACKAGE_DIR"] = workingPath
        process.environment = environment

        // Inherit stdio for interactive use
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        // Run
        try process.run()
        process.waitUntilExit()

        // Exit with same code
        if process.terminationStatus != 0 {
            throw PluginError.toolFailed(exitCode: process.terminationStatus)
        }
    }
}

// MARK: - Errors

enum PluginError: Error, CustomStringConvertible {
    case toolNotFound
    case toolFailed(exitCode: Int32)

    var description: String {
        switch self {
        case .toolNotFound:
            return "Could not find 'TrebuchetCLI' tool"
        case .toolFailed(let exitCode):
            return "Tool exited with code \(exitCode)"
        }
    }
}
