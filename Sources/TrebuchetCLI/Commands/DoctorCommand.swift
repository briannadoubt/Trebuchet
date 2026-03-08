import ArgumentParser
import Foundation

public struct DoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose project setup and surface migration guidance"
    )

    @Argument(help: "Path to the app project root")
    public var projectPath: String = "."

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(projectPath)
        let fileManager = FileManager.default

        terminal.print("Trebuchet doctor", style: .header)
        terminal.print("Project: \(root)", style: .dim)
        terminal.print("", style: .info)

        var issues: [String] = []

        let legacyArtifacts = [
            "\(root)/.trebuchet",
            "\(root)/trebuchet.yaml",
            "\(root)/trebuchet.yml",
            "\(root)/Trebuchetfile",
        ]
        for artifact in legacyArtifacts where fileManager.fileExists(atPath: artifact) {
            issues.append("Legacy artifact detected: \(artifact)")
        }

        let serverCandidate = "\(root)/Server/Package.swift"
        let rootPackage = "\(root)/Package.swift"
        let hasServerPackage = fileManager.fileExists(atPath: serverCandidate)
        let hasRootPackage = fileManager.fileExists(atPath: rootPackage)

        if !hasServerPackage && !hasRootPackage {
            issues.append("No Swift package detected at ./Server or project root.")
        }

        if issues.isEmpty {
            terminal.print("✓ No migration issues detected.", style: .success)
            return
        }

        terminal.print("Detected issues:", style: .warning)
        for issue in issues {
            terminal.print("  • \(issue)", style: .dim)
        }
        terminal.print("", style: .info)

        let recommendedSystemPath = hasServerPackage ? "./Server" : "."
        terminal.print("Recommended next steps:", style: .info)
        terminal.print("  1. Use System-package dev flow:", style: .dim)
        terminal.print("     trebuchet dev \(recommendedSystemPath) --product <SystemExecutable>", style: .dim)
        terminal.print("  2. Rewire Xcode integration:", style: .dim)
        terminal.print("     trebuchet xcode setup --project-path . --system-path \(recommendedSystemPath) --product <SystemExecutable>", style: .dim)
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }
}
