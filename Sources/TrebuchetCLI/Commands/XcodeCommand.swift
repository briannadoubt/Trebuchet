import ArgumentParser
import Foundation

public struct XcodeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Set up and manage Xcode app + Trebuchet dev server workflows",
        subcommands: [
            XcodeSetupCommand.self,
            XcodeTeardownCommand.self,
            XcodeStatusCommand.self,
            XcodeSessionCommand.self,
        ]
    )

    public init() {}
}

public struct XcodeSetupCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create or update a Trebuchet-managed shared Xcode scheme"
    )

    @Option(name: .long, help: "Path to the app project root (directory containing .xcodeproj)")
    public var projectPath: String = "."

    @Option(name: .long, help: "Base scheme to clone/patch")
    public var scheme: String?

    @Option(name: .long, help: "Managed scheme name to create (default: <scheme>+Trebuchet)")
    public var createSchemeName: String?

    @Flag(name: .long, help: "Patch the source scheme in place instead of creating a managed scheme copy")
    public var inPlace: Bool = false

    @Option(name: .long, help: "Host for dev server sessions")
    public var host: String = "127.0.0.1"

    @Option(name: .long, help: "Port for dev server sessions")
    public var port: UInt16 = 8080

    @Option(name: .long, help: "Path to local Trebuchet checkout to pass to `trebuchet dev --local`")
    public var local: String?

    @Option(name: .long, help: "Container runtime passed to `trebuchet dev` (auto, compote, docker)")
    public var runtime: String = "auto"

    @Flag(name: .long, help: "Pass --no-deps to `trebuchet dev` sessions")
    public var noDeps: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    @Flag(name: .long, help: "Print planned changes without writing files")
    public var dryRun: Bool = false

    @Flag(name: .long, help: "Allow overwriting an existing non-managed destination scheme")
    public var force: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let project = try XcodeIntegration.findProject(at: projectRoot)

        let baseScheme = try XcodeIntegration.resolveBaseSchemeName(
            preferredScheme: scheme,
            in: project
        )
        let destinationScheme = createSchemeName ?? (inPlace ? baseScheme : "\(baseScheme)+Trebuchet")
        let target = try XcodeIntegration.preferredTargetInfo(in: project, preferredName: baseScheme)

        let cliPath = XcodeIntegration.resolveCLIExecutablePath()
        let startScript = XcodeIntegration.startScriptContents(
            cliExecutablePath: cliPath,
            host: host,
            port: port,
            local: local,
            runtime: runtime,
            noDeps: noDeps
        )
        let stopScript = XcodeIntegration.stopScriptContents(cliExecutablePath: cliPath)

        let sharedSchemeDir = project.sharedSchemesDirectory
        let sourceSchemePath = "\(sharedSchemeDir)/\(baseScheme).xcscheme"
        let destinationSchemePath = "\(sharedSchemeDir)/\(destinationScheme).xcscheme"

        let sourceSchemeExists = FileManager.default.fileExists(atPath: sourceSchemePath)
        if inPlace && !sourceSchemeExists {
            terminal.print("In-place setup requires an existing shared scheme at \(sourceSchemePath)", style: .error)
            throw ExitCode.failure
        }

        if !dryRun && FileManager.default.fileExists(atPath: destinationSchemePath) && !inPlace && !force {
            // We always allow overwriting Trebuchet-managed scheme names.
            if !destinationScheme.hasSuffix("+Trebuchet") {
                terminal.print("Destination scheme already exists: \(destinationSchemePath)", style: .error)
                terminal.print("Use --force to overwrite.", style: .dim)
                throw ExitCode.failure
            }
        }

        let sourceXML: String
        if sourceSchemeExists {
            sourceXML = try String(contentsOfFile: sourceSchemePath, encoding: .utf8)
        } else {
            sourceXML = XcodeIntegration.buildFallbackSchemeXML(target: target)
        }
        let managedXML = try XcodeIntegration.addManagedLaunchActions(
            to: sourceXML,
            host: host,
            port: port
        )

        terminal.print("")
        terminal.print("Preparing Xcode integration...", style: .header)
        terminal.print("Project: \(project.xcodeprojPath)", style: .dim)
        terminal.print("Base scheme: \(baseScheme)", style: .dim)
        terminal.print("Destination scheme: \(destinationScheme)", style: .dim)
        terminal.print("Server endpoint: \(host):\(port)", style: .dim)
        terminal.print("")

        if dryRun {
            terminal.print("Dry run complete. No files were written.", style: .info)
            return
        }

        try FileManager.default.createDirectory(atPath: project.sharedSchemesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: "\(project.projectRoot)/\(XcodeIntegration.xcodeArtifactsDirectoryRelativePath)",
            withIntermediateDirectories: true
        )

        let startScriptPath = "\(project.projectRoot)/\(XcodeIntegration.startScriptRelativePath)"
        let stopScriptPath = "\(project.projectRoot)/\(XcodeIntegration.stopScriptRelativePath)"
        try startScript.write(toFile: startScriptPath, atomically: true, encoding: .utf8)
        try stopScript.write(toFile: stopScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: startScriptPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stopScriptPath)

        try managedXML.write(toFile: destinationSchemePath, atomically: true, encoding: .utf8)

        do {
            let updatedVisibilityFiles = try XcodeIntegration.ensureSharedSchemeVisible(
                named: destinationScheme,
                in: project
            )
            for path in updatedVisibilityFiles {
                terminal.print("✓ Updated scheme visibility: \(path)", style: .success)
            }
        } catch {
            terminal.print("Could not update scheme visibility metadata: \(error)", style: .warning)
        }

        terminal.print("✓ Wrote start script: \(startScriptPath)", style: .success)
        terminal.print("✓ Wrote stop script: \(stopScriptPath)", style: .success)
        terminal.print("✓ Wrote scheme: \(destinationSchemePath)", style: .success)
        terminal.print("")
        terminal.print("Next in Xcode:", style: .info)
        terminal.print("  1. Select scheme '\(destinationScheme)'", style: .dim)
        terminal.print("  2. Press Run", style: .dim)
    }
}

public struct XcodeTeardownCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Remove Trebuchet-managed Xcode scripts/scheme integration"
    )

    @Option(name: .long, help: "Path to the app project root (directory containing .xcodeproj)")
    public var projectPath: String = "."

    @Option(name: .long, help: "Base scheme to use for managed scheme name resolution")
    public var scheme: String?

    @Option(name: .long, help: "Managed scheme name to remove (default: <scheme>+Trebuchet)")
    public var createSchemeName: String?

    @Flag(name: .long, help: "Remove managed actions from the base scheme itself")
    public var inPlace: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let project = try XcodeIntegration.findProject(at: projectRoot)
        let baseScheme = try XcodeIntegration.resolveBaseSchemeName(preferredScheme: scheme, in: project)
        let managedScheme = createSchemeName ?? (inPlace ? baseScheme : "\(baseScheme)+Trebuchet")
        let sharedSchemeDir = project.sharedSchemesDirectory

        var removedSomething = false
        let managedSchemePath = "\(sharedSchemeDir)/\(managedScheme).xcscheme"

        if inPlace {
            if FileManager.default.fileExists(atPath: managedSchemePath) {
                let xml = try String(contentsOfFile: managedSchemePath, encoding: .utf8)
                let stripped = XcodeIntegration.stripManagedActions(from: xml)
                try stripped.write(toFile: managedSchemePath, atomically: true, encoding: .utf8)
                terminal.print("✓ Removed managed actions from \(managedSchemePath)", style: .success)
                removedSomething = true
            }
        } else if FileManager.default.fileExists(atPath: managedSchemePath) {
            try FileManager.default.removeItem(atPath: managedSchemePath)
            terminal.print("✓ Removed scheme \(managedSchemePath)", style: .success)
            removedSomething = true
        }

        if !inPlace {
            do {
                let updatedVisibilityFiles = try XcodeIntegration.removeSharedSchemeVisibility(
                    named: managedScheme,
                    in: project
                )
                for path in updatedVisibilityFiles {
                    terminal.print("✓ Updated scheme visibility: \(path)", style: .success)
                    removedSomething = true
                }
            } catch {
                terminal.print("Could not update scheme visibility metadata: \(error)", style: .warning)
            }
        }

        let startScriptPath = "\(project.projectRoot)/\(XcodeIntegration.startScriptRelativePath)"
        let stopScriptPath = "\(project.projectRoot)/\(XcodeIntegration.stopScriptRelativePath)"
        for scriptPath in [startScriptPath, stopScriptPath] {
            if FileManager.default.fileExists(atPath: scriptPath) {
                try FileManager.default.removeItem(atPath: scriptPath)
                terminal.print("✓ Removed script \(scriptPath)", style: .success)
                removedSomething = true
            }
        }

        let sessionManager = XcodeSessionManager(
            projectPath: project.projectRoot,
            cliExecutablePath: XcodeIntegration.resolveCLIExecutablePath(),
            terminal: terminal,
            verbose: verbose
        )
        sessionManager.stop()

        if !removedSomething {
            terminal.print("No Trebuchet-managed Xcode artifacts found.", style: .dim)
        }
    }
}

public struct XcodeStatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show Trebuchet Xcode integration status"
    )

    @Option(name: .long, help: "Path to the app project root (directory containing .xcodeproj)")
    public var projectPath: String = "."

    @Option(name: .long, help: "Base scheme to use for managed scheme name resolution")
    public var scheme: String?

    @Option(name: .long, help: "Managed scheme name to check (default: <scheme>+Trebuchet)")
    public var createSchemeName: String?

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let project = try XcodeIntegration.findProject(at: projectRoot)
        let baseScheme = try XcodeIntegration.resolveBaseSchemeName(preferredScheme: scheme, in: project)
        let managedScheme = createSchemeName ?? "\(baseScheme)+Trebuchet"

        let managedSchemePath = "\(project.sharedSchemesDirectory)/\(managedScheme).xcscheme"
        let startScriptPath = "\(project.projectRoot)/\(XcodeIntegration.startScriptRelativePath)"
        let stopScriptPath = "\(project.projectRoot)/\(XcodeIntegration.stopScriptRelativePath)"

        terminal.print("Project: \(project.xcodeprojPath)", style: .info)
        terminal.print("Base scheme: \(baseScheme)", style: .info)
        terminal.print("Managed scheme: \(managedScheme)", style: .info)
        terminal.print("")
        terminal.print("Scheme file: \(FileManager.default.fileExists(atPath: managedSchemePath) ? "present" : "missing")", style: .dim)
        terminal.print("Start script: \(FileManager.default.fileExists(atPath: startScriptPath) ? "present" : "missing")", style: .dim)
        terminal.print("Stop script: \(FileManager.default.fileExists(atPath: stopScriptPath) ? "present" : "missing")", style: .dim)

        let sessionManager = XcodeSessionManager(
            projectPath: project.projectRoot,
            cliExecutablePath: XcodeIntegration.resolveCLIExecutablePath(),
            terminal: terminal,
            verbose: false
        )

        switch sessionManager.status() {
        case .running(let record):
            terminal.print("Session: running (pid \(record.pid), \(record.host):\(record.port))", style: .success)
            terminal.print("Logs: \(record.logPath)", style: .dim)
        case .stopped:
            terminal.print("Session: stopped", style: .dim)
        case .stale(let record):
            if let record {
                terminal.print("Session: stale (pid \(record.pid), \(record.host):\(record.port))", style: .warning)
            } else {
                terminal.print("Session: stale", style: .warning)
            }
        }
    }
}

public struct XcodeSessionCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage Trebuchet dev server background sessions for Xcode",
        subcommands: [
            XcodeSessionStartCommand.self,
            XcodeSessionStopCommand.self,
            XcodeSessionStatusCommand.self,
        ]
    )

    public init() {}
}

public struct XcodeSessionStartCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start (or reuse) a Trebuchet dev session for the current project"
    )

    @Option(name: .long, help: "Path to the app project root")
    public var projectPath: String = "."

    @Option(name: .long, help: "Host for dev server")
    public var host: String = "127.0.0.1"

    @Option(name: .long, help: "Port for dev server")
    public var port: UInt16 = 8080

    @Option(name: .long, help: "Path to local Trebuchet checkout to pass to `trebuchet dev --local`")
    public var local: String?

    @Option(name: .long, help: "Container runtime passed to `trebuchet dev` (auto, compote, docker)")
    public var runtime: String = "auto"

    @Flag(name: .long, help: "Pass --no-deps to `trebuchet dev`")
    public var noDeps: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let manager = XcodeSessionManager(
            projectPath: projectRoot,
            cliExecutablePath: XcodeIntegration.resolveCLIExecutablePath(),
            terminal: terminal,
            verbose: verbose
        )

        do {
            try manager.start(
                host: host,
                port: port,
                local: local,
                runtime: runtime,
                noDeps: noDeps
            )
        } catch {
            terminal.print("\(error)", style: .error)
            throw ExitCode.failure
        }
    }
}

public struct XcodeSessionStopCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop Trebuchet dev session for the current project"
    )

    @Option(name: .long, help: "Path to the app project root")
    public var projectPath: String = "."

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let manager = XcodeSessionManager(
            projectPath: projectRoot,
            cliExecutablePath: XcodeIntegration.resolveCLIExecutablePath(),
            terminal: terminal,
            verbose: verbose
        )
        manager.stop()
    }
}

public struct XcodeSessionStatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show status for the current Trebuchet dev session"
    )

    @Option(name: .long, help: "Path to the app project root")
    public var projectPath: String = "."

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectRoot = resolveProjectRoot(from: projectPath)
        let manager = XcodeSessionManager(
            projectPath: projectRoot,
            cliExecutablePath: XcodeIntegration.resolveCLIExecutablePath(),
            terminal: terminal,
            verbose: false
        )

        switch manager.status() {
        case .running(let record):
            terminal.print("running", style: .success)
            terminal.print("pid: \(record.pid)", style: .dim)
            terminal.print("endpoint: \(record.host):\(record.port)", style: .dim)
            terminal.print("log: \(record.logPath)", style: .dim)
        case .stopped:
            terminal.print("stopped", style: .dim)
        case .stale(let record):
            terminal.print("stale", style: .warning)
            if let record {
                terminal.print("last pid: \(record.pid)", style: .dim)
                terminal.print("last endpoint: \(record.host):\(record.port)", style: .dim)
            }
        }
    }
}

private func resolveProjectRoot(from inputPath: String) -> String {
    let expanded = (inputPath as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded)
        .standardizedFileURL
        .path
}
