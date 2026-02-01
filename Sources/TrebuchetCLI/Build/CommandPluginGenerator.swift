import Foundation

/// Generates Swift Package Manager Command Plugin source files from trebuchet.yaml commands
public struct CommandPluginGenerator {
    let terminal: Terminal

    init(terminal: Terminal = Terminal()) {
        self.terminal = terminal
    }

    /// Generate command plugins for all commands in the config
    /// - Parameters:
    ///   - config: Trebuchet configuration containing commands
    ///   - outputPath: Root directory to generate plugins into (creates Plugins/ subdirectory)
    ///   - verbose: Enable verbose output
    /// - Returns: List of generated plugin metadata for Package.swift integration
    func generate(
        config: TrebuchetConfig,
        outputPath: String,
        verbose: Bool
    ) throws -> [GeneratedPlugin] {
        guard let commands = config.commands, !commands.isEmpty else {
            terminal.print("No commands defined in trebuchet.yaml", style: .warning)
            return []
        }

        let pluginsDir = "\(outputPath)/Plugins"

        var generatedPlugins: [GeneratedPlugin] = []

        for (verb, command) in commands.sorted(by: { $0.key < $1.key }) {
            let pluginTargetName = Self.pluginTargetName(from: verb)
            let pluginDir = "\(pluginsDir)/\(pluginTargetName)"

            try FileManager.default.createDirectory(
                atPath: pluginDir,
                withIntermediateDirectories: true
            )

            let pluginSource = generatePluginSource(
                verb: verb,
                title: command.title,
                script: command.script
            )

            try pluginSource.write(
                toFile: "\(pluginDir)/plugin.swift",
                atomically: true,
                encoding: .utf8
            )

            if verbose {
                terminal.print("  Generated plugin: \(pluginTargetName) (verb: \(verb))", style: .dim)
            }

            generatedPlugins.append(GeneratedPlugin(
                verb: verb,
                title: command.title,
                targetName: pluginTargetName,
                script: command.script
            ))
        }

        return generatedPlugins
    }

    /// Generate the Package.swift snippet for adding command plugins
    func generatePackageSnippet(plugins: [GeneratedPlugin]) -> String {
        guard !plugins.isEmpty else { return "" }

        var snippet = "// Add these plugin targets to your Package.swift:\n\n"

        // Products
        snippet += "// Products:\n"
        for plugin in plugins {
            snippet += """
            .plugin(
                name: "\(plugin.targetName)",
                targets: ["\(plugin.targetName)"]
            ),

            """
        }

        snippet += "\n// Targets:\n"
        for plugin in plugins {
            snippet += """
            .plugin(
                name: "\(plugin.targetName)",
                capability: .command(
                    intent: .custom(
                        verb: "\(plugin.verb)",
                        description: "\(plugin.title)"
                    ),
                    permissions: [
                        .writeToPackageDirectory(
                            reason: "Execute command: \(plugin.script)"
                        ),
                    ]
                )
            ),

            """
        }

        return snippet
    }

    // MARK: - Plugin Source Generation

    private func generatePluginSource(
        verb: String,
        title: String,
        script: String
    ) -> String {
        let structName = Self.structName(from: verb)

        return """
        import Foundation
        import PackagePlugin

        @main
        struct \(structName): CommandPlugin {
            func performCommand(
                context: PluginContext,
                arguments: [String]
            ) async throws {
                let workingDirectory = context.package.directoryURL

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", \(Self.escapeSwiftString(script))]
                process.currentDirectoryURL = workingDirectory

                // Pass through environment
                var environment = ProcessInfo.processInfo.environment
                environment["TREBUCHET_PACKAGE_DIR"] = workingDirectory.path
                process.environment = environment

                // Inherit stdio for interactive use
                process.standardOutput = FileHandle.standardOutput
                process.standardError = FileHandle.standardError
                process.standardInput = FileHandle.standardInput

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    throw CommandError.scriptFailed(exitCode: process.terminationStatus)
                }
            }
        }

        #if canImport(XcodeProjectPlugin)
        import XcodeProjectPlugin

        extension \(structName): XcodeCommandPlugin {
            func performCommand(
                context: XcodePluginContext,
                arguments: [String]
            ) throws {
                let workingDirectory = context.xcodeProject.directoryURL

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", \(Self.escapeSwiftString(script))]
                process.currentDirectoryURL = workingDirectory

                var environment = ProcessInfo.processInfo.environment
                environment["TREBUCHET_PACKAGE_DIR"] = workingDirectory.path
                process.environment = environment

                process.standardOutput = FileHandle.standardOutput
                process.standardError = FileHandle.standardError
                process.standardInput = FileHandle.standardInput

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    throw CommandError.scriptFailed(exitCode: process.terminationStatus)
                }
            }
        }
        #endif

        enum CommandError: Error, CustomStringConvertible {
            case scriptFailed(exitCode: Int32)

            var description: String {
                switch self {
                case .scriptFailed(let exitCode):
                    return "\(title) failed with exit code \\(exitCode)"
                }
            }
        }

        """
    }

    // MARK: - Name Conversion Helpers

    /// Convert a verb like "runLocally" to a Swift-safe plugin target name like "RunLocallyPlugin"
    static func pluginTargetName(from verb: String) -> String {
        verb.prefix(1).uppercased() + verb.dropFirst() + "Plugin"
    }

    /// Convert a verb like "runLocally" to a Swift struct name like "RunLocallyCommand"
    static func structName(from verb: String) -> String {
        verb.prefix(1).uppercased() + verb.dropFirst() + "Command"
    }

    /// Escape a string for use inside a Swift string literal
    static func escapeSwiftString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Metadata about a generated command plugin
public struct GeneratedPlugin: Sendable {
    public let verb: String
    public let title: String
    public let targetName: String
    public let script: String
}
