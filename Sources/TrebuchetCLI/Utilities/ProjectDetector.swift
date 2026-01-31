import Foundation

/// Detects project type and provides utilities for package generation
public struct ProjectDetector {
    let projectPath: String
    let fileManager: FileManager

    public init(projectPath: String, fileManager: FileManager = .default) {
        self.projectPath = projectPath
        self.fileManager = fileManager
    }

    /// Check if the project is an Xcode project (vs Swift Package)
    public var isXcodeProject: Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: projectPath) else {
            return false
        }

        // Check for .xcodeproj or .xcworkspace
        return contents.contains {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        }
    }

    /// Check if the project has a Package.swift
    public var hasPackageSwift: Bool {
        fileManager.fileExists(atPath: "\(projectPath)/Package.swift")
    }

    /// Get the package name from Package.swift if it exists
    public func getPackageName() throws -> String? {
        let packagePath = "\(projectPath)/Package.swift"
        guard fileManager.fileExists(atPath: packagePath) else {
            return nil
        }

        let contents = try String(contentsOfFile: packagePath, encoding: .utf8)

        // Extract package name using regex
        if let range = contents.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
            let match = String(contents[range])
            if let nameRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                let nameMatch = String(match[nameRange])
                return nameMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        return nil
    }

    /// Copy actor source files and their dependencies to a target directory
    public func copyActorSources(
        actors: [ActorMetadata],
        to targetPath: String,
        verbose: Bool = false,
        terminal: Terminal? = nil
    ) throws {
        // Use dependency analyzer to find all required files
        let analyzer = DependencyAnalyzer(projectPath: projectPath, fileManager: fileManager)
        let requiredFiles: Set<String>

        do {
            requiredFiles = try analyzer.findDependencies(for: actors)
            if verbose, let term = terminal {
                term.print("  Analyzing dependencies...", style: .dim)
                term.print("  Found \(requiredFiles.count) required file(s)", style: .dim)
            }
        } catch {
            // Fallback to simple copy if dependency analysis fails
            if let term = terminal {
                term.print("  Warning: Dependency analysis failed, copying actor files only", style: .warning)
                if verbose {
                    term.print("  Error: \(error)", style: .dim)
                }
            }
            requiredFiles = Set(actors.map { $0.filePath })
        }

        // Track which files we've copied
        var copiedFiles = Set<String>()

        for sourceFile in requiredFiles {
            let fileName = URL(fileURLWithPath: sourceFile).lastPathComponent

            // Skip if already copied
            guard !copiedFiles.contains(fileName) else {
                continue
            }

            let targetFile = "\(targetPath)/\(fileName)"

            // Read source file
            guard let sourceContent = try? String(contentsOfFile: sourceFile, encoding: .utf8) else {
                if let term = terminal {
                    term.print("Warning: Could not read \(sourceFile)", style: .warning)
                }
                continue
            }

            // Write to target
            try sourceContent.write(toFile: targetFile, atomically: true, encoding: .utf8)
            copiedFiles.insert(fileName)

            if verbose, let term = terminal {
                term.print("  Copied: \(fileName)", style: .dim)
            }
        }

        if let term = terminal {
            let fileLabel = copiedFiles.count == 1 ? "file" : "files"
            term.print("✓ Copied \(copiedFiles.count) source \(fileLabel) (including dependencies)", style: .success)
        }
    }

    /// Generate a Package.swift dependency for the project
    /// Returns either a package dependency or nil if actors should be copied
    public func generatePackageDependency(
        for packageName: String,
        relativePath: String = ".."
    ) -> String? {
        guard hasPackageSwift else {
            // No Package.swift means we should copy sources instead
            return nil
        }

        return ".package(path: \"\(relativePath)\")"
    }

    /// Generate appropriate package manifest for standalone server
    public func generateStandalonePackageManifest(
        packageName: String,
        targetName: String,
        moduleName: String,
        needsPostgreSQL: Bool = false,
        relativePath: String = "..",
        platforms: String = ".macOS(.v14)"
    ) -> String {
        var dependencies: [String] = [
            ".package(url: \"https://github.com/briannadoubt/Trebuchet.git\", .upToNextMajor(from: \"0.3.0\"))"
        ]

        var targetDependencies: [String] = [
            "\"Trebuchet\"",
            ".product(name: \"TrebuchetCloud\", package: \"Trebuchet\")"
        ]

        // Add project dependency if it's a Swift Package
        if hasPackageSwift {
            dependencies.append(".package(path: \"\(relativePath)\")")
            targetDependencies.append(".product(name: \"\(moduleName)\", package: \"\(moduleName)\")")
        }

        // Add PostgreSQL if needed
        if needsPostgreSQL {
            dependencies.append(".package(url: \"https://github.com/vapor/postgres-nio.git\", from: \"1.0.0\")")
            targetDependencies.append(".product(name: \"TrebuchetPostgreSQL\", package: \"Trebuchet\")")
        }

        let dependenciesStr = dependencies.map { "        \($0)" }.joined(separator: ",\n")
        let targetDepsStr = targetDependencies.map { "            \($0)" }.joined(separator: ",\n")

        // If we need to include copied sources, add an ActorSources target
        let actorSourcesTarget = !hasPackageSwift ? """

                .target(
                    name: "ActorSources",
                    dependencies: [
                        "Trebuchet"
                    ]
                ),
        """ : ""

        // Add ActorSources to dependencies if not using package
        let finalTargetDeps = !hasPackageSwift ?
            targetDepsStr + ",\n            \"ActorSources\"" :
            targetDepsStr

        return """
        // swift-tools-version: 6.0
        // Auto-generated by trebuchet CLI
        // DO NOT EDIT - Regenerate with: trebuchet generate server --force

        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            platforms: [\(platforms)],
            dependencies: [
        \(dependenciesStr)
            ],
            targets: [\(actorSourcesTarget)
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
        \(finalTargetDeps)
                    ]
                )
            ]
        )

        """
    }
}
