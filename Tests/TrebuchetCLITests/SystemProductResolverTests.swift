#if !os(Linux)
import Foundation
import Testing
@testable import TrebuchetCLI

@Suite("System Product Resolver")
struct SystemProductResolverTests {
    @Test("Resolves the only executable product")
    func resolvesSingleExecutable() throws {
        let packagePath = try makeFixturePackage(executables: [
            ExecutableFixture(name: "App", source: simpleMainSource(systemConformance: false)),
        ])
        defer { try? FileManager.default.removeItem(atPath: packagePath) }

        let result = try SystemProductResolver().resolve(projectPath: packagePath, explicitProduct: nil)
        #expect(result.product == "App")
    }

    @Test("Resolves executable containing @main System when multiple products exist")
    func resolvesSystemMainWhenMultipleExecutablesExist() throws {
        let packagePath = try makeFixturePackage(executables: [
            ExecutableFixture(name: "Helper", source: simpleMainSource(systemConformance: false)),
            ExecutableFixture(name: "Server", source: simpleMainSource(systemConformance: true)),
        ])
        defer { try? FileManager.default.removeItem(atPath: packagePath) }

        let result = try SystemProductResolver().resolve(projectPath: packagePath, explicitProduct: nil)
        #expect(result.product == "Server")
    }

    @Test("Requires --product when multiple executables are ambiguous")
    func failsWhenMultipleExecutablesAreAmbiguous() throws {
        let packagePath = try makeFixturePackage(executables: [
            ExecutableFixture(name: "First", source: simpleMainSource(systemConformance: false)),
            ExecutableFixture(name: "Second", source: simpleMainSource(systemConformance: false)),
        ])
        defer { try? FileManager.default.removeItem(atPath: packagePath) }

        do {
            _ = try SystemProductResolver().resolve(projectPath: packagePath, explicitProduct: nil)
            Issue.record("Expected ambiguity failure")
        } catch let error as CLIError {
            #expect(error.description.contains("--product"))
        }
    }

    private func makeFixturePackage(executables: [ExecutableFixture]) throws -> String {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrebuchetCLI-SystemResolver-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let productsBlock = executables.map { exe in
            ".executable(name: \"\(exe.name)\", targets: [\"\(exe.name)\"] )"
        }.joined(separator: ",\n        ")

        let targetsBlock = executables.map { exe in
            ".executableTarget(name: \"\(exe.name)\")"
        }.joined(separator: ",\n        ")

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Fixture",
            products: [
                \(productsBlock)
            ],
            targets: [
                \(targetsBlock)
            ]
        )
        """

        try packageSwift.write(to: rootURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        for executable in executables {
            let sourceDir = rootURL
                .appendingPathComponent("Sources")
                .appendingPathComponent(executable.name)
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try executable.source.write(
                to: sourceDir.appendingPathComponent("main.swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        return rootURL.path
    }

    private func simpleMainSource(systemConformance: Bool) -> String {
        if systemConformance {
            return """
            protocol System {}

            @main
            struct AppMain: System {
                static func main() {}
            }
            """
        }

        return """
        @main
        struct AppMain {
            static func main() {}
        }
        """
    }
}

private struct ExecutableFixture {
    let name: String
    let source: String
}
#endif
