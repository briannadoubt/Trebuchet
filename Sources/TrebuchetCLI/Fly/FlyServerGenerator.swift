import Foundation

/// Generates server package for Fly.io deployment
struct FlyServerGenerator {
    let terminal: Terminal

    init(terminal: Terminal = Terminal()) {
        self.terminal = terminal
    }

    /// Generate server package for Fly.io
    /// - Parameters:
    ///   - config: Trebuchet configuration
    ///   - actors: Discovered actors
    ///   - projectPath: Path to the main project
    func generate(
        config: TrebuchetConfig,
        actors: [ActorMetadata],
        projectPath: String
    ) throws {
        let outputPath = "\(projectPath)/.trebuchet/fly-server"

        // Use ServerGenerator to create the package
        let generator = ServerGenerator(terminal: terminal)
        try generator.generate(
            config: config,
            actors: actors,
            projectPath: projectPath,
            outputPath: outputPath,
            verbose: false
        )
    }
}
