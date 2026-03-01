import Foundation
import Trebuchet
import Yams
#if os(macOS)
import Darwin
#endif

struct DevDependencySession: Sendable {
    let runtime: String
    let commandPrefix: [String]
    let manifestPath: String
    let workingDirectory: String
    let projectName: String
    let generatedManifestPath: String?
}

struct DevDependencyRuntime: Sendable {
    #if os(macOS)
    private static let defaultCompoteVminitRef = "ghcr.io/apple/containerization/vminit:0.24.5"
    #endif

    private let terminal: Terminal
    private let verbose: Bool
    private let projectDirectory: String
    private let runtimePreference: String

    init(
        terminal: Terminal,
        verbose: Bool,
        projectDirectory: String,
        runtimePreference: String
    ) {
        self.terminal = terminal
        self.verbose = verbose
        self.projectDirectory = projectDirectory
        self.runtimePreference = runtimePreference
    }

    func start(plan: DeploymentPlan?) async throws -> DevDependencySession? {
        var projectName = projectNameForCompose(baseDirectory: projectDirectory)
        let manifestPath: String
        let workingDirectory: String
        let generatedManifestPath: String?

        if let existing = findExistingComposeManifest(startingAt: projectDirectory) {
            manifestPath = existing
            workingDirectory = URL(fileURLWithPath: existing).deletingLastPathComponent().path
            projectName = projectNameForCompose(baseDirectory: workingDirectory)
            generatedManifestPath = nil
            terminal.print("Using dependency manifest: \(existing)", style: .dim)
        } else {
            let inferredDependencies = inferredDependencies(from: plan)
            guard !inferredDependencies.isEmpty else {
                if verbose {
                    terminal.print("No dependency manifest found and no inferred local dependencies from topology.", style: .dim)
                }
                return nil
            }

            let generated = try writeGeneratedComposeFile(
                dependencies: inferredDependencies,
                projectName: projectName
            )
            manifestPath = generated
            workingDirectory = URL(fileURLWithPath: generated).deletingLastPathComponent().path
            generatedManifestPath = generated
            terminal.print("Generated dependency manifest: \(generated)", style: .dim)
        }

        let selection = try selectRuntime()
        guard let selection else {
            throw CLIError.configurationError(
                "Dependency orchestration is required (\(manifestPath)) but no supported runtime is available in PATH. Install `compote` on macOS or Docker Compose (`docker compose` / `docker-compose`)."
            )
        }

        try startDependencies(
            using: selection,
            manifestPath: manifestPath,
            workingDirectory: workingDirectory,
            projectName: projectName
        )

        terminal.print("Dependencies ready (\(selection.runtime)).", style: .success)

        return DevDependencySession(
            runtime: selection.runtime,
            commandPrefix: selection.commandPrefix,
            manifestPath: manifestPath,
            workingDirectory: workingDirectory,
            projectName: projectName,
            generatedManifestPath: generatedManifestPath
        )
    }

    func stop(_ session: DevDependencySession) async {
        do {
            let runtimeEnvironment = runtimeEnvironmentOverrides(for: session.runtime)
            try runCompose(
                commandPrefix: session.commandPrefix,
                args: downArgs(
                    for: session.runtime,
                    manifestPath: session.manifestPath,
                    projectName: session.projectName
                ),
                workingDirectory: session.workingDirectory,
                actionDescription: "stop dependencies with \(session.runtime)",
                environmentOverrides: runtimeEnvironment
            )
            terminal.print("Dependencies stopped (\(session.runtime)).", style: .dim)
        } catch {
            terminal.print("Failed to stop dependencies cleanly: \(error)", style: .warning)
        }

        #if os(macOS)
        if session.runtime == "compote" {
            let cleanedForwards = cleanupCompoteStalePortForwards(projectName: session.projectName)
            if cleanedForwards > 0 && verbose {
                terminal.print("Stopped \(cleanedForwards) stale compote port-forward process(es).", style: .dim)
            }
        }
        #endif

        if let generated = session.generatedManifestPath {
            try? FileManager.default.removeItem(atPath: generated)
        }
    }

    private func selectRuntime() throws -> (runtime: String, commandPrefix: [String])? {
        let preference = runtimePreference.lowercased()

        switch preference {
        case "auto":
            #if os(macOS)
            if commandAvailable(["compote", "--version"]) {
                return ("compote", ["compote"])
            }
            return nil
            #else
            if let docker = dockerComposeCommandPrefix() {
                return ("docker", docker)
            }
            return nil
            #endif
        case "compote":
            #if os(macOS)
            guard commandAvailable(["compote", "--version"]) else {
                throw CLIError.configurationError("`compote` is not available in PATH. Install compote.")
            }
            return ("compote", ["compote"])
            #else
            throw CLIError.configurationError("`--runtime compote` is only supported on macOS.")
            #endif
        case "docker":
            guard let docker = dockerComposeCommandPrefix() else {
                throw CLIError.configurationError("Docker Compose is not available in PATH. Install Docker.")
            }
            return ("docker", docker)
        default:
            throw CLIError.configurationError("Unsupported runtime '\(runtimePreference)'. Use one of: auto, compote, docker.")
        }
    }

    private func dockerComposeCommandPrefix() -> [String]? {
        if commandAvailable(["docker", "compose", "version"]) {
            return ["docker", "compose"]
        }
        if commandAvailable(["docker-compose", "version"]) {
            return ["docker-compose"]
        }
        return nil
    }

    private func commandAvailable(_ command: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func startDependencies(
        using selection: (runtime: String, commandPrefix: [String]),
        manifestPath: String,
        workingDirectory: String,
        projectName: String
    ) throws {
        let runtimeEnvironment = runtimeEnvironmentOverrides(for: selection.runtime)
        #if os(macOS)
        if selection.runtime == "compote" {
            try ensureCompoteHostToolsAvailable(manifestPath: manifestPath)
            let cleanedForwards = cleanupCompoteStalePortForwards(projectName: projectName)
            if cleanedForwards > 0 && verbose {
                terminal.print("Stopped \(cleanedForwards) stale compote port-forward process(es).", style: .dim)
            }
        }
        #endif

        // Best-effort cleanup to avoid stale local runtime state blocking `up`.
        try? runCompose(
            commandPrefix: selection.commandPrefix,
            args: downArgs(
                for: selection.runtime,
                manifestPath: manifestPath,
                projectName: projectName
            ),
            workingDirectory: workingDirectory,
            actionDescription: "pre-clean dependencies with \(selection.runtime)",
            environmentOverrides: runtimeEnvironment
        )

        #if os(macOS)
        if selection.runtime == "compote" {
            let cleaned = cleanupCompoteStaleArtifacts(
                manifestPath: manifestPath,
                projectName: projectName
            )
            if cleaned {
                terminal.print("Cleaned stale compote container artifacts before startup.", style: .dim)
            }
        }
        #endif

        let startupArgs = upArgs(
            for: selection.runtime,
            manifestPath: manifestPath,
            projectName: projectName
        )

        do {
            try runCompose(
                commandPrefix: selection.commandPrefix,
                args: startupArgs,
                workingDirectory: workingDirectory,
                actionDescription: "start dependencies with \(selection.runtime)",
                environmentOverrides: runtimeEnvironment
            )
            #if os(macOS)
            if selection.runtime == "compote" {
                try ensureCompoteServicesHealthy(
                    manifestPath: manifestPath,
                    projectName: projectName,
                    workingDirectory: workingDirectory,
                    environmentOverrides: runtimeEnvironment
                )
            }
            #endif
        } catch {
            #if os(macOS)
            if selection.runtime == "compote" {
                let cleanedAfterFailure = cleanupCompoteStaleArtifacts(
                    manifestPath: manifestPath,
                    projectName: projectName
                )
                let cleanedPortForwardsAfterFailure = cleanupCompoteStalePortForwards(projectName: projectName)
                let repairedRuntime = shouldRepairCompoteRuntime(after: error) ? repairCompoteRuntimeState() : false
                if cleanedAfterFailure || cleanedPortForwardsAfterFailure > 0 || repairedRuntime {
                    if repairedRuntime {
                        terminal.print("Detected stale Compote runtime state. Retrying dependency startup...", style: .warning)
                    } else {
                        terminal.print("Detected stale compote state. Retrying dependency startup...", style: .warning)
                    }
                    try runCompose(
                        commandPrefix: selection.commandPrefix,
                        args: startupArgs,
                        workingDirectory: workingDirectory,
                        actionDescription: "retry dependency startup with \(selection.runtime)",
                        environmentOverrides: runtimeEnvironment
                    )
                    try ensureCompoteServicesHealthy(
                        manifestPath: manifestPath,
                        projectName: projectName,
                        workingDirectory: workingDirectory,
                        environmentOverrides: runtimeEnvironment
                    )
                } else {
                    throw error
                }
            } else {
                throw error
            }
            #else
            throw error
            #endif
        }
    }

    private func downArgs(for runtime: String, manifestPath: String, projectName: String) -> [String] {
        switch runtime {
        case "docker":
            let dockerProjectName = normalizedDockerProjectName(projectName)
            return [
                "--file", manifestPath,
                "--project-name", dockerProjectName,
                "down",
            ]
        default:
            return [
                "down",
                "--file", manifestPath,
                "--project-name", projectName,
            ]
        }
    }

    private func upArgs(for runtime: String, manifestPath: String, projectName: String) -> [String] {
        switch runtime {
        case "docker":
            let dockerProjectName = normalizedDockerProjectName(projectName)
            return [
                "--file", manifestPath,
                "--project-name", dockerProjectName,
                "up",
                "--detach",
                "--force-recreate",
            ]
        default:
            return [
                "up",
                "--file", manifestPath,
                "--project-name", projectName,
                "--detach",
                "--force-recreate",
            ]
        }
    }

    private func normalizedDockerProjectName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let filteredCharacters = name.lowercased().unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }

        var normalized = String(filteredCharacters)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))

        if normalized.isEmpty {
            normalized = "trebuchet"
        }

        if let first = normalized.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) {
            normalized = "t-\(normalized)"
        }

        return normalized
    }

    private func runCompose(
        commandPrefix: [String],
        args: [String],
        workingDirectory: String,
        actionDescription: String,
        environmentOverrides: [String: String]? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = commandPrefix + args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        if let environmentOverrides {
            process.environment = environmentOverrides
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        if verbose {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            process.standardOutput = outputPipe
            process.standardError = errorPipe
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output: String
            if verbose {
                output = ""
            } else {
                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                output = [stdout, stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }

            let commandText = (commandPrefix + args).joined(separator: " ")
            let outputSuffix = output.isEmpty ? "" : "\n\(output)"
            throw CLIError.commandFailed("Failed to \(actionDescription) (exit \(process.terminationStatus)): \(commandText)\(outputSuffix)")
        }
    }

    private func findExistingComposeManifest(startingAt startDirectory: String) -> String? {
        let candidates = [
            "compote.yml",
            "compote.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml",
        ]

        let fileManager = FileManager.default
        var currentURL = URL(fileURLWithPath: startDirectory).standardizedFileURL

        while true {
            for name in candidates {
                let path = currentURL.appendingPathComponent(name).path
                if fileManager.fileExists(atPath: path) {
                    return path
                }
            }

            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path {
                break
            }
            currentURL = parent
        }

        return nil
    }

    private func writeGeneratedComposeFile(
        dependencies: [DependencyConfig],
        projectName: String
    ) throws -> String {
        let config = TrebuchetConfig(
            name: projectName,
            state: nil,
            dependencies: dependencies
        )
        let composeFile = ComposeFileGenerator(config: config).generate()
        let yaml = try YAMLEncoder().encode(composeFile)

        let outputDirectory = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(".trebuchet")
            .path
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let outputPath = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("dev-dependencies.generated.yml")
            .path
        try yaml.write(toFile: outputPath, atomically: true, encoding: .utf8)
        return outputPath
    }

    private func inferredDependencies(from plan: DeploymentPlan?) -> [DependencyConfig] {
        guard let plan else { return [] }

        var byName: [String: DependencyConfig] = [:]

        for actor in plan.actors {
            guard let state = actor.state else { continue }
            switch state {
            case .memory:
                continue
            case .postgres:
                byName["postgresql"] = DependencyConfig(
                    name: "postgresql",
                    image: "postgres:16-alpine",
                    ports: ["5432:5432"],
                    environment: [
                        "POSTGRES_USER": "trebuchet",
                        "POSTGRES_PASSWORD": "trebuchet",
                        "POSTGRES_DB": "trebuchet_dev"
                    ],
                    healthcheck: HealthCheckConfig(
                        port: 5432,
                        interval: 2,
                        retries: 15
                    ),
                    volumes: ["postgres-data:/var/lib/postgresql/data"]
                )
            case .dynamoDB:
                byName["localstack"] = DependencyConfig(
                    name: "localstack",
                    image: "localstack/localstack:3.0",
                    ports: ["4566:4566"],
                    environment: [
                        "SERVICES": "dynamodb,dynamodbstreams,cloudmap,iam,lambda,apigateway",
                        "DEFAULT_REGION": "us-east-1"
                    ],
                    healthcheck: HealthCheckConfig(
                        url: "http://localhost:4566/_localstack/health",
                        interval: 3,
                        retries: 20
                    )
                )
            }
        }

        return byName.keys.sorted().compactMap { byName[$0] }
    }

    private func projectNameForCompose(baseDirectory: String) -> String {
        let rawName = URL(fileURLWithPath: baseDirectory).lastPathComponent
        let hyphenScalar = UnicodeScalar(45)!
        let underscoreScalar = UnicodeScalar(95)!
        let characters = rawName.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == underscoreScalar || scalar == hyphenScalar {
                return Character(String(scalar))
            }
            return "-"
        }
        let sanitized = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "trebuchet" : sanitized
    }

    private func runtimeEnvironmentOverrides(for runtime: String) -> [String: String]? {
        #if os(macOS)
        guard runtime == "compote" else { return nil }
        var environment = ProcessInfo.processInfo.environment
        if environment["COMPOTE_VMINIT_REF"]?.isEmpty != false {
            environment["COMPOTE_VMINIT_REF"] = Self.defaultCompoteVminitRef
        }
        return environment
        #else
        _ = runtime
        return nil
        #endif
    }

    #if os(macOS)
    private func ensureCompoteHostToolsAvailable(manifestPath: String) throws {
        guard manifestDeclaresPorts(manifestPath) else { return }
        guard commandAvailable(["socat", "-V"]) else {
            throw CLIError.configurationError(
                "Compote port mappings require `socat` on PATH. Install it (for example `brew install socat`) and retry."
            )
        }
    }

    private func manifestDeclaresPorts(_ manifestPath: String) -> Bool {
        guard
            let yaml = try? String(contentsOfFile: manifestPath, encoding: .utf8),
            let root = try? Yams.load(yaml: yaml) as? [String: Any],
            let services = root["services"] as? [String: Any]
        else {
            return false
        }

        for (_, rawService) in services {
            guard let service = rawService as? [String: Any] else { continue }
            if let ports = service["ports"] as? [Any], !ports.isEmpty {
                return true
            }
        }

        return false
    }

    private func ensureCompoteServicesHealthy(
        manifestPath: String,
        projectName: String,
        workingDirectory: String,
        environmentOverrides: [String: String]?
    ) throws {
        let statusCommand = [
            "compote",
            "ps",
            "--file", manifestPath,
            "--project-name", projectName,
        ]
        let deadline = Date().addingTimeInterval(8)
        var lastOutput = ""

        while true {
            guard let status = runCommand(
                statusCommand,
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            ) else {
                throw CLIError.commandFailed("Unable to read compote status after startup.")
            }

            guard status.exitCode == 0 else {
                let details = status.output.isEmpty ? "" : "\n\(status.output)"
                throw CLIError.commandFailed("Failed to inspect compote service health (exit \(status.exitCode)).\(details)")
            }

            lastOutput = status.output
            let serviceLines = parseCompoteStatusLines(status.output)
            if !serviceLines.isEmpty && serviceLines.allSatisfy(isCompoteStatusHealthy) {
                return
            }

            if Date() >= deadline {
                break
            }
            Thread.sleep(forTimeInterval: 0.8)
        }

        let output = lastOutput.isEmpty ? "(no status output)" : lastOutput
        throw CLIError.commandFailed(
            """
            Compote reported unhealthy services after startup:
            \(output)
            Run `compote logs --file \(manifestPath) --project-name \(projectName)` for details.
            """
        )
    }

    private func parseCompoteStatusLines(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.lowercased().hasPrefix("name") {
                    return false
                }
                return line.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil
            }
    }

    private func isCompoteStatusHealthy(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("exited")
            || lower.contains("stopped")
            || lower.contains("failed")
            || lower.contains("error")
            || lower.contains("dead")
        {
            return false
        }

        return lower.contains("running")
            || lower.contains("healthy")
            || lower.contains("up")
    }

    private func cleanupCompoteStalePortForwards(projectName: String) -> Int {
        let statePath = ("~/Library/Application Support/compote/state/\(projectName).json" as NSString)
            .expandingTildeInPath
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let portForwards = object["portForwards"] as? [String: Any]
        else {
            return 0
        }

        var cleaned = 0
        for (_, rawForward) in portForwards {
            guard let forward = rawForward as? [String: Any] else { continue }
            let pidValue: Int?
            if let pid = forward["pid"] as? Int {
                pidValue = pid
            } else if let pid = forward["pid"] as? NSNumber {
                pidValue = pid.intValue
            } else {
                pidValue = nil
            }

            guard let pid = pidValue, pid > 0, isSocatProcess(pid: pid) else { continue }

            if kill(pid_t(pid), SIGTERM) == 0 || errno == ESRCH {
                cleaned += 1
            }
        }

        return cleaned
    }

    private func shouldRepairCompoteRuntime(after error: Error) -> Bool {
        guard case let CLIError.commandFailed(message) = error else {
            return true
        }

        let lower = message.lowercased()
        if lower.contains("compote reported unhealthy services") {
            return false
        }
        return true
    }

    private func isSocatProcess(pid: Int) -> Bool {
        guard let process = runCommand(["ps", "-p", "\(pid)", "-o", "comm="]), process.exitCode == 0 else {
            return false
        }

        return process.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("socat")
    }

    private func repairCompoteRuntimeState() -> Bool {
        var repaired = false

        if startContainerSystemIfNeeded() {
            repaired = true
        }

        let initfsPath = ("~/Library/Application Support/com.apple.containerization/initfs.ext4" as NSString)
            .expandingTildeInPath
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: initfsPath) {
            let backupPath = "\(initfsPath).bak-trebuchet-\(Int(Date().timeIntervalSince1970))"
            do {
                try fileManager.moveItem(atPath: initfsPath, toPath: backupPath)
                repaired = true
                if verbose {
                    terminal.print("Backed up stale Compote initfs to: \(backupPath)", style: .dim)
                }
            } catch {
                if verbose {
                    terminal.print("Failed to reset Compote initfs at \(initfsPath): \(error)", style: .warning)
                }
            }
        }

        return repaired
    }

    private func startContainerSystemIfNeeded() -> Bool {
        guard let status = runCommand(["container", "system", "status"]) else {
            return false
        }

        if status.output.localizedCaseInsensitiveContains("apiserver is running") {
            return false
        }

        guard let start = runCommand(["container", "system", "start"]), start.exitCode == 0 else {
            return false
        }

        if verbose {
            terminal.print("Started Apple container system for Compote runtime.", style: .dim)
        }
        return true
    }

    private func runCommand(
        _ command: [String],
        workingDirectory: String? = nil,
        environmentOverrides: [String: String]? = nil
    ) -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environmentOverrides {
            process.environment = environmentOverrides
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return (process.terminationStatus, combined)
    }

    private func cleanupCompoteStaleArtifacts(manifestPath: String, projectName: String) -> Bool {
        let fileManager = FileManager.default
        let containersRoot = ("~/Library/Application Support/com.apple.containerization/containers" as NSString)
            .expandingTildeInPath

        guard fileManager.fileExists(atPath: containersRoot) else {
            return false
        }

        let signatures = compoteContainerSignatures(
            manifestPath: manifestPath,
            projectName: projectName
        )
        guard !signatures.exactNames.isEmpty || !signatures.prefixes.isEmpty else {
            return false
        }

        guard let entries = try? fileManager.contentsOfDirectory(atPath: containersRoot) else {
            return false
        }

        var removed = false
        for entry in entries {
            let exact = signatures.exactNames.contains(entry)
            let prefixed = signatures.prefixes.contains { entry.hasPrefix($0) }
            guard exact || prefixed else { continue }

            let path = URL(fileURLWithPath: containersRoot)
                .appendingPathComponent(entry)
                .path
            do {
                try fileManager.removeItem(atPath: path)
                removed = true
                if verbose {
                    terminal.print("Removed stale compote artifact: \(path)", style: .dim)
                }
            } catch {
                if verbose {
                    terminal.print("Failed to remove stale artifact \(path): \(error)", style: .warning)
                }
            }
        }

        return removed
    }

    private func compoteContainerSignatures(
        manifestPath: String,
        projectName: String
    ) -> (exactNames: Set<String>, prefixes: Set<String>) {
        var exactNames = Set<String>()
        var prefixes = Set<String>()

        guard
            let yaml = try? String(contentsOfFile: manifestPath, encoding: .utf8),
            let root = try? Yams.load(yaml: yaml) as? [String: Any],
            let services = root["services"] as? [String: Any]
        else {
            return (exactNames, prefixes)
        }

        for (serviceName, rawService) in services {
            prefixes.insert("\(projectName)_\(serviceName)_")

            if
                let service = rawService as? [String: Any],
                let containerName = service["container_name"] as? String,
                !containerName.isEmpty
            {
                exactNames.insert(containerName)
            }
        }

        return (exactNames, prefixes)
    }
    #endif
}
