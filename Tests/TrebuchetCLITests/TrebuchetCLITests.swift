import Testing
import Foundation
@testable import TrebuchetCLI

@Suite("Configuration Tests")
struct ConfigurationTests {

    @Test("TrebuchetConfig initialization")
    func configInit() {
        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(
                provider: "aws",
                region: "us-east-1"
            )
        )

        #expect(config.name == "test-project")
        #expect(config.defaults.provider == "aws")
        #expect(config.defaults.region == "us-east-1")
    }

    @Test("DefaultSettings defaults")
    func defaultSettingsDefaults() {
        let defaults = DefaultSettings()

        #expect(defaults.provider == "fly")
        #expect(defaults.region == "iad")
        #expect(defaults.memory == 512)
        #expect(defaults.timeout == 30)
    }

    @Test("ActorConfig optional properties")
    func actorConfigOptionals() {
        let config = ActorConfig(
            memory: 1024,
            stateful: true
        )

        #expect(config.memory == 1024)
        #expect(config.stateful == true)
        #expect(config.timeout == nil)
        #expect(config.isolated == nil)
    }

    @Test("ResolvedConfig creation")
    func resolvedConfigCreation() {
        let actors = [
            ResolvedActorConfig(
                name: "TestActor",
                memory: 512,
                timeout: 30,
                stateful: false,
                isolated: false,
                environment: [:]
            )
        ]

        let resolved = ResolvedConfig(
            projectName: "test-project",
            provider: "aws",
            region: "us-east-1",
            actors: actors,
            stateTableName: "test-state",
            discoveryNamespace: "test"
        )

        #expect(resolved.projectName == "test-project")
        #expect(resolved.actors.count == 1)
        #expect(resolved.actors[0].name == "TestActor")
    }
}

@Suite("Config Loader Tests")
struct ConfigLoaderTests {

    @Test("Parse simple YAML configuration")
    func parseSimpleYaml() throws {
        // Minimal YAML with required fields
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 30
            actors: {}
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        #expect(config.name == "test-project")
        #expect(config.version == "1")
        #expect(config.defaults.provider == "aws")
    }

    @Test("Generate default configuration")
    func generateDefault() {
        let yaml = ConfigLoader.generateDefault(projectName: "test-app")

        #expect(yaml.contains("name: test-app"))
        #expect(yaml.contains("provider: fly"))
        #expect(yaml.contains("region: iad"))
    }

    // MARK: - Validation Tests

    @Test("Validation accepts implemented providers")
    func validationAcceptsImplementedProviders() throws {
        let providers = ["aws", "fly", "local"]

        for provider in providers {
            let yaml = """
                name: test-project
                version: "1"
                defaults:
                  provider: \(provider)
                  region: us-east-1
                  memory: 512
                  timeout: 30
                actors: {}
                """

            let loader = ConfigLoader()
            // Should not throw
            let config = try loader.parse(yaml: yaml)
            #expect(config.defaults.provider == provider)
        }
    }

    @Test("Validation rejects unimplemented providers")
    func validationRejectsUnimplementedProviders() throws {
        let unimplementedProviders = ["gcp", "azure", "kubernetes"]

        for provider in unimplementedProviders {
            let yaml = """
                name: test-project
                version: "1"
                defaults:
                  provider: \(provider)
                  region: us-east-1
                  memory: 512
                  timeout: 30
                actors: {}
                """

            let loader = ConfigLoader()

            do {
                _ = try loader.parse(yaml: yaml)
                Issue.record("Expected validation error for provider '\(provider)' but parsing succeeded")
            } catch let error as ConfigError {
                // Should fail with validation error
                #expect(error.description.contains("not yet implemented"))
                #expect(error.description.contains(provider))
            }
        }
    }

    @Test("Validation rejects unknown providers")
    func validationRejectsUnknownProviders() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: invalid-provider
              region: us-east-1
              memory: 512
              timeout: 30
            actors: {}
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for unknown provider")
        } catch let error as ConfigError {
            #expect(error.description.contains("Unknown provider"))
        }
    }

    @Test("Validation requires AWS region")
    func validationRequiresAWSRegion() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: ""
              memory: 512
              timeout: 30
            actors: {}
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for missing AWS region")
        } catch let error as ConfigError {
            #expect(error.description.contains("region"))
        }
    }

    @Test("Validation checks state store compatibility")
    func validationChecksStateStoreCompatibility() throws {
        // Test incompatible: AWS + Firestore
        let yaml1 = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 30
            actors: {}
            state:
              type: firestore
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml1)
            Issue.record("Expected validation error for AWS + Firestore")
        } catch let error as ConfigError {
            #expect(error.description.contains("firestore"))
            #expect(error.description.contains("not compatible"))
        }

        // Test compatible: AWS + DynamoDB (should succeed)
        let yaml2 = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 30
            actors: {}
            state:
              type: dynamodb
            """

        _ = try loader.parse(yaml: yaml2)  // Should not throw
    }

    @Test("Validation checks discovery compatibility")
    func validationChecksDiscoveryCompatibility() throws {
        // Test incompatible: GCP + CloudMap
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: gcp
              region: us-central1
              memory: 512
              timeout: 30
            actors: {}
            discovery:
              type: cloudmap
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for GCP + CloudMap")
        } catch let error as ConfigError {
            // Should fail on provider first, but if we fix that, should fail on discovery
            #expect(error.description.contains("not yet implemented") || error.description.contains("cloudmap"))
        }
    }

    @Test("Validation enforces minimum memory")
    func validationEnforcesMinimumMemory() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 64
              timeout: 30
            actors: {}
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for memory < 128")
        } catch let error as ConfigError {
            #expect(error.description.contains("at least 128"))
        }
    }

    @Test("Validation enforces maximum memory")
    func validationEnforcesMaximumMemory() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 20000
              timeout: 30
            actors: {}
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for memory > 10240")
        } catch let error as ConfigError {
            #expect(error.description.contains("at most 10240"))
        }
    }

    @Test("Validation enforces timeout limits")
    func validationEnforcesTimeoutLimits() throws {
        // Test minimum
        let yaml1 = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 0
            actors: {}
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml1)
            Issue.record("Expected validation error for timeout < 1")
        } catch let error as ConfigError {
            #expect(error.description.contains("at least 1"))
        }

        // Test maximum
        let yaml2 = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 1000
            actors: {}
            """

        do {
            _ = try loader.parse(yaml: yaml2)
            Issue.record("Expected validation error for timeout > 900")
        } catch let error as ConfigError {
            #expect(error.description.contains("at most 900"))
        }
    }

    @Test("Validation checks actor-specific resource limits")
    func validationChecksActorResourceLimits() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: aws
              region: us-east-1
              memory: 512
              timeout: 30
            actors:
              BigActor:
                memory: 20000
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for actor memory > 10240")
        } catch let error as ConfigError {
            #expect(error.description.contains("BigActor"))
            #expect(error.description.contains("memory"))
        }
    }
}

@Suite("Actor Discovery Tests")
struct ActorDiscoveryTests {

    @Test("ActorMetadata creation")
    func actorMetadataCreation() {
        let method = MethodMetadata(
            name: "join",
            signature: "join(player:)",
            parameters: [
                ParameterMetadata(label: "player", name: "player", type: "Player")
            ],
            returnType: "RoomState",
            canThrow: true
        )

        let actor = ActorMetadata(
            name: "GameRoom",
            filePath: "/path/to/GameRoom.swift",
            lineNumber: 10,
            methods: [method],
            isStateful: true
        )

        #expect(actor.name == "GameRoom")
        #expect(actor.methods.count == 1)
        #expect(actor.methods[0].signature == "join(player:)")
        #expect(actor.isStateful == true)
    }

    @Test("MethodMetadata properties")
    func methodMetadataProperties() {
        let method = MethodMetadata(
            name: "getPlayers",
            signature: "getPlayers()",
            parameters: [],
            returnType: "[Player]",
            canThrow: false
        )

        #expect(method.name == "getPlayers")
        #expect(method.parameters.isEmpty)
        #expect(method.returnType == "[Player]")
        #expect(method.canThrow == false)
    }

    @Test("ParameterMetadata properties")
    func parameterMetadataProperties() {
        let param1 = ParameterMetadata(label: "with", name: "player", type: "Player")
        let param2 = ParameterMetadata(label: nil, name: "count", type: "Int")

        #expect(param1.label == "with")
        #expect(param1.name == "player")
        #expect(param2.label == nil)
    }
}

@Suite("Terminal Tests")
struct TerminalTests {

    @Test("Terminal initialization")
    func terminalInit() {
        let terminal = Terminal(useColors: false)
        #expect(terminal != nil)
    }

    @Test("Progress bar generation")
    func progressBar() {
        let terminal = Terminal(useColors: false)

        let bar0 = terminal.progressBar(current: 0, total: 10, width: 10)
        #expect(bar0.contains("0%"))

        let bar50 = terminal.progressBar(current: 5, total: 10, width: 10)
        #expect(bar50.contains("50%"))

        let bar100 = terminal.progressBar(current: 10, total: 10, width: 10)
        #expect(bar100.contains("100%"))
    }

    @Test("Spinner animation")
    func spinnerAnimation() {
        let terminal = Terminal()

        let frame0 = terminal.spinner(frame: 0)
        let frame1 = terminal.spinner(frame: 1)

        // Different frames should produce different characters
        #expect(frame0 != frame1)
    }
}

@Suite("Build System Tests")
struct BuildSystemTests {

    @Test("BuildResult size description")
    func buildResultSize() {
        let result = BuildResult(
            binaryPath: "/path/to/binary",
            size: 15_000_000,
            duration: .seconds(30)
        )

        #expect(result.sizeDescription.contains("MB") || result.sizeDescription.contains("KB"))
    }
}
