#if !os(Linux)
import Testing
@testable import TrebuchetCLI

@Suite("Command Registry")
struct CommandRegistryTests {
    @Test("Root command does not expose legacy YAML commands")
    func rootCommandExcludesLegacyYamlCommands() {
        let names = TrebuchetCommand.configuration.subcommands.map { command in
            command.configuration.commandName
        }

        #expect(names.contains("deploy"))
        #expect(names.contains("dev"))
        #expect(names.contains("xcode"))
        #expect(names.contains("doctor"))

        #expect(!names.contains("init"))
        #expect(!names.contains("run"))
    }
}
#endif
