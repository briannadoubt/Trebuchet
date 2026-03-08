// TrebuchetCLI cannot be imported on Linux because it's an executable target
// Swift Package Manager doesn't support importing executable targets in tests on Linux
#if !os(Linux)
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

    @Test("CommandConfig initialization")
    func commandConfigInit() {
        let command = CommandConfig(title: "Run Locally", script: "trebuchet dev")
        #expect(command.title == "Run Locally")
        #expect(command.script == "trebuchet dev")
    }

    @Test("TrebuchetConfig with commands")
    func configWithCommands() {
        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(provider: "fly", region: "iad"),
            commands: [
                "runLocally": CommandConfig(title: "Run Locally", script: "trebuchet dev"),
                "deploy": CommandConfig(title: "Deploy", script: "trebuchet deploy")
            ]
        )

        #expect(config.commands?.count == 2)
        #expect(config.commands?["runLocally"]?.title == "Run Locally")
        #expect(config.commands?["runLocally"]?.script == "trebuchet dev")
        #expect(config.commands?["deploy"]?.script == "trebuchet deploy")
    }

    @Test("TrebuchetConfig commands defaults to nil")
    func configCommandsDefaultsToNil() {
        let config = TrebuchetConfig(name: "test-project")
        #expect(config.commands == nil)
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
        #expect(yaml.contains("commands:"))
        #expect(yaml.contains("runLocally:"))
        #expect(yaml.contains("title: \"Run Locally\""))
        #expect(yaml.contains("script: trebuchet dev"))
    }

    @Test("Parse YAML with commands section")
    func parseYamlWithCommands() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: fly
              region: iad
              memory: 512
              timeout: 30
            actors: {}
            commands:
              runLocally:
                title: "Run Locally"
                script: trebuchet dev
              deployStaging:
                title: "Deploy Staging"
                script: trebuchet deploy --environment staging
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        #expect(config.commands?.count == 2)
        #expect(config.commands?["runLocally"]?.title == "Run Locally")
        #expect(config.commands?["runLocally"]?.script == "trebuchet dev")
        #expect(config.commands?["deployStaging"]?.title == "Deploy Staging")
        #expect(config.commands?["deployStaging"]?.script == "trebuchet deploy --environment staging")
    }

    @Test("Parse YAML without commands section")
    func parseYamlWithoutCommands() throws {
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

        #expect(config.commands == nil)
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

    // MARK: - CommandPluginGenerator Tests

    @Test("CommandPluginGenerator plugin target name from verb")
    func commandPluginGeneratorTargetName() {
        #expect(CommandPluginGenerator.pluginTargetName(from: "runLocally") == "RunLocallyPlugin")
        #expect(CommandPluginGenerator.pluginTargetName(from: "deployStaging") == "DeployStagingPlugin")
        #expect(CommandPluginGenerator.pluginTargetName(from: "runTests") == "RunTestsPlugin")
    }

    @Test("CommandPluginGenerator struct name from verb")
    func commandPluginGeneratorStructName() {
        #expect(CommandPluginGenerator.structName(from: "runLocally") == "RunLocallyCommand")
        #expect(CommandPluginGenerator.structName(from: "deployStaging") == "DeployStagingCommand")
    }

    @Test("CommandPluginGenerator generates plugin files")
    func commandPluginGeneratorGeneratesFiles() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(provider: "fly", region: "iad"),
            commands: [
                "runLocally": CommandConfig(title: "Run Locally", script: "trebuchet dev"),
                "deployStaging": CommandConfig(title: "Deploy Staging", script: "trebuchet deploy --environment staging")
            ]
        )

        let generator = CommandPluginGenerator(terminal: Terminal(useColors: false))
        let plugins = try generator.generate(
            config: config,
            outputPath: tempDir,
            verbose: false
        )

        #expect(plugins.count == 2)

        // Verify plugin files were created
        #expect(fileManager.fileExists(atPath: "\(tempDir)/Plugins/DeployStagingPlugin/plugin.swift"))
        #expect(fileManager.fileExists(atPath: "\(tempDir)/Plugins/RunLocallyPlugin/plugin.swift"))

        // Verify "runLocally" plugin content
        let runLocallyContent = try String(
            contentsOfFile: "\(tempDir)/Plugins/RunLocallyPlugin/plugin.swift",
            encoding: .utf8
        )
        #expect(runLocallyContent.contains("import PackagePlugin"))
        #expect(runLocallyContent.contains("struct RunLocallyCommand: CommandPlugin"))
        #expect(runLocallyContent.contains("trebuchet dev"))
        #expect(runLocallyContent.contains("/bin/sh"))

        // Verify "deployStaging" plugin content
        let deployStagingContent = try String(
            contentsOfFile: "\(tempDir)/Plugins/DeployStagingPlugin/plugin.swift",
            encoding: .utf8
        )
        #expect(deployStagingContent.contains("struct DeployStagingCommand: CommandPlugin"))
        #expect(deployStagingContent.contains("trebuchet deploy --environment staging"))
    }

    @Test("CommandPluginGenerator generates Package.swift snippet")
    func commandPluginGeneratorPackageSnippet() {
        let generator = CommandPluginGenerator(terminal: Terminal(useColors: false))
        let plugins = [
            GeneratedPlugin(
                verb: "runLocally",
                title: "Run Locally",
                targetName: "RunLocallyPlugin",
                script: "trebuchet dev"
            )
        ]

        let snippet = generator.generatePackageSnippet(plugins: plugins)

        #expect(snippet.contains("RunLocallyPlugin"))
        #expect(snippet.contains("runLocally"))
        #expect(snippet.contains("Run Locally"))
        #expect(snippet.contains(".command("))
        #expect(snippet.contains(".custom("))
    }

    @Test("CommandPluginGenerator handles empty commands")
    func commandPluginGeneratorEmptyCommands() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(provider: "fly", region: "iad")
        )

        let generator = CommandPluginGenerator(terminal: Terminal(useColors: false))
        let plugins = try generator.generate(
            config: config,
            outputPath: tempDir,
            verbose: false
        )

        #expect(plugins.isEmpty)
    }

    @Test("BuildResult size description")
    func buildResultSize() {
        let result = BuildResult(
            binaryPath: "/path/to/binary",
            size: 15_000_000,
            duration: .seconds(30)
        )

        #expect(result.sizeDescription.contains("MB") || result.sizeDescription.contains("KB"))
    }

    // MARK: - BootstrapGenerator Tests

    @Test("BootstrapGenerator basic bootstrap generation")
    func bootstrapGeneratorBasic() {
        let generator = BootstrapGenerator()
        let config = ResolvedConfig(
            projectName: "test-project",
            provider: "aws",
            region: "us-east-1",
            actors: [],
            stateTableName: "test-state",
            discoveryNamespace: "test-namespace"
        )
        let actors: [ActorMetadata] = []

        let bootstrap = generator.generate(config: config, actors: actors)

        // Verify essential imports
        #expect(bootstrap.contains("import Trebuchet"))
        #expect(bootstrap.contains("import TrebuchetCloud"))
        #expect(bootstrap.contains("import TrebuchetAWS"))
        #expect(bootstrap.contains("import AWSLambdaRuntime"))
        #expect(bootstrap.contains("import AWSLambdaEvents"))

        // Verify main structure
        #expect(bootstrap.contains("@main"))
        #expect(bootstrap.contains("struct LambdaBootstrap"))
        #expect(bootstrap.contains("LambdaHandler"))

        // Verify configuration
        #expect(bootstrap.contains("DynamoDBStateStore"))
        #expect(bootstrap.contains("CloudMapRegistry"))
        #expect(bootstrap.contains("CloudGateway"))
    }

    @Test("BootstrapGenerator with actors")
    func bootstrapGeneratorWithActors() {
        let generator = BootstrapGenerator()
        let config = ResolvedConfig(
            projectName: "game-server",
            provider: "aws",
            region: "us-west-2",
            actors: [
                ResolvedActorConfig(name: "GameRoom", memory: 1024, timeout: 60, stateful: true, isolated: false, environment: [:]),
                ResolvedActorConfig(name: "Lobby", memory: 512, timeout: 30, stateful: false, isolated: false, environment: [:])
            ],
            stateTableName: "game-state",
            discoveryNamespace: "game"
        )
        let actors: [ActorMetadata] = [
            ActorMetadata(name: "GameRoom", filePath: "Test.swift", lineNumber: 1, methods: []),
            ActorMetadata(name: "Lobby", filePath: "Test.swift", lineNumber: 2, methods: [])
        ]

        let bootstrap = generator.generate(config: config, actors: actors)

        // Verify actor initializations
        #expect(bootstrap.contains("let gameroom = GameRoom(actorSystem: gateway.system)"))
        #expect(bootstrap.contains("let lobby = Lobby(actorSystem: gateway.system)"))

        // Verify actor registrations
        #expect(bootstrap.contains("try await gateway.expose(gameroom, as: \"gameroom\")"))
        #expect(bootstrap.contains("try await gateway.expose(lobby, as: \"lobby\")"))

        // Verify actor count
        #expect(bootstrap.contains("actorCount: 2"))
    }

    @Test("BootstrapGenerator actor initialization helper")
    func bootstrapGeneratorActorInitHelper() {
        let actors: [ActorMetadata] = [
            ActorMetadata(name: "TestActor", filePath: "Test.swift", lineNumber: 1, methods: []),
            ActorMetadata(name: "AnotherActor", filePath: "Test.swift", lineNumber: 2, methods: [])
        ]

        let code = BootstrapGenerator.generateActorInitializations(
            actors: actors,
            indent: 4,
            systemVariable: "system"
        )

        #expect(code.contains("let testactor = TestActor(actorSystem: system)"))
        #expect(code.contains("let anotheractor = AnotherActor(actorSystem: system)"))
        #expect(code.contains("    ")) // Check indentation
    }

    @Test("BootstrapGenerator actor registration helper")
    func bootstrapGeneratorActorRegistrationHelper() {
        let actors: [ActorMetadata] = [
            ActorMetadata(name: "GameActor", filePath: "Test.swift", lineNumber: 1, methods: [])
        ]

        let code = BootstrapGenerator.generateActorRegistrations(
            actors: actors,
            indent: 4,
            logStatement: #"print("Registered: %ACTOR%")"#
        )

        #expect(code.contains("try await gateway.expose(gameactor, as: \"gameactor\")"))
        #expect(code.contains(#"print("Registered: GameActor")"#))
    }

    @Test("BootstrapGenerator Package.swift generation")
    func bootstrapGeneratorPackageSwift() {
        let generator = BootstrapGenerator()
        let config = ResolvedConfig(
            projectName: "my-actors",
            provider: "aws",
            region: "us-east-1",
            actors: [],
            stateTableName: "state",
            discoveryNamespace: "ns"
        )

        let projectPath = FileManager.default.currentDirectoryPath
        let packageSwift = generator.generatePackageSwift(config: config, projectPath: projectPath)

        #expect(packageSwift.contains("// swift-tools-version: 6.0"))
        #expect(packageSwift.contains("name: \"my-actors-lambda\""))
        #expect(packageSwift.contains("swift-aws-lambda-runtime"))
        #expect(packageSwift.contains("swift-aws-lambda-events"))
        #expect(packageSwift.contains("soto"))
        #expect(packageSwift.contains("Trebuchet"))
        #expect(packageSwift.contains("TrebuchetCloud"))
        #expect(packageSwift.contains("TrebuchetAWS"))
    }

    // MARK: - TerraformGenerator Tests

    @Test("TerraformGenerator basic generation")
    func terraformGeneratorBasic() throws {
        let fileManager = FileManager.default
        let generator = TerraformGenerator(fileManager: fileManager)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = ResolvedConfig(
            projectName: "test-infra",
            provider: "aws",
            region: "eu-west-1",
            actors: [],
            stateTableName: "test-state",
            discoveryNamespace: "test"
        )
        let actors: [ActorMetadata] = []

        let outputPath = try generator.generate(
            config: config,
            actors: actors,
            outputDir: tempDir
        )

        #expect(outputPath == tempDir)

        // Verify files were created
        #expect(fileManager.fileExists(atPath: "\(tempDir)/main.tf"))
        #expect(fileManager.fileExists(atPath: "\(tempDir)/variables.tf"))
        #expect(fileManager.fileExists(atPath: "\(tempDir)/outputs.tf"))
        #expect(fileManager.fileExists(atPath: "\(tempDir)/terraform.tfvars.example"))
    }

    @Test("TerraformGenerator main.tf content")
    func terraformGeneratorMainContent() throws {
        let fileManager = FileManager.default
        let generator = TerraformGenerator(fileManager: fileManager)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = ResolvedConfig(
            projectName: "my-project",
            provider: "aws",
            region: "ap-southeast-1",
            actors: [
                ResolvedActorConfig(name: "Actor1", memory: 512, timeout: 30, stateful: true, isolated: false, environment: [:])
            ],
            stateTableName: "state-table",
            discoveryNamespace: "my-ns"
        )
        let actors: [ActorMetadata] = [
            ActorMetadata(name: "Actor1", filePath: "Test.swift", lineNumber: 1, methods: [])
        ]

        _ = try generator.generate(
            config: config,
            actors: actors,
            outputDir: tempDir
        )

        let mainContent = try String(contentsOfFile: "\(tempDir)/main.tf", encoding: .utf8)

        // Verify Terraform structure
        #expect(mainContent.contains("terraform {"))
        #expect(mainContent.contains("required_version"))
        #expect(mainContent.contains("required_providers"))
        #expect(mainContent.contains("provider \"aws\""))

        // Verify project name and region
        #expect(mainContent.contains("my-project") || mainContent.contains("my_project"))
        #expect(mainContent.contains("ap-southeast-1") || mainContent.contains("var.aws_region"))

        // Verify AWS resources
        #expect(mainContent.contains("aws_iam_role"))
        #expect(mainContent.contains("aws_lambda_function"))
        #expect(mainContent.contains("aws_dynamodb_table"))
    }

    @Test("TerraformGenerator variables.tf has required vars")
    func terraformGeneratorVariables() throws {
        let fileManager = FileManager.default
        let generator = TerraformGenerator(fileManager: fileManager)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = ResolvedConfig(
            projectName: "test",
            provider: "aws",
            region: "us-east-1",
            actors: [],
            stateTableName: "state",
            discoveryNamespace: "ns"
        )

        _ = try generator.generate(
            config: config,
            actors: [],
            outputDir: tempDir
        )

        let varsContent = try String(contentsOfFile: "\(tempDir)/variables.tf", encoding: .utf8)

        // Verify essential variables are defined
        #expect(varsContent.contains("variable"))
        #expect(varsContent.contains("aws_region") || varsContent.contains("region"))
    }

    @Test("TerraformGenerator outputs.tf exists")
    func terraformGeneratorOutputs() throws {
        let fileManager = FileManager.default
        let generator = TerraformGenerator(fileManager: fileManager)

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        let config = ResolvedConfig(
            projectName: "test",
            provider: "aws",
            region: "us-east-1",
            actors: [],
            stateTableName: "state",
            discoveryNamespace: "ns"
        )

        _ = try generator.generate(
            config: config,
            actors: [],
            outputDir: tempDir
        )

        let outputsContent = try String(contentsOfFile: "\(tempDir)/outputs.tf", encoding: .utf8)

        // Verify outputs are defined
        #expect(outputsContent.contains("output"))
    }

    // MARK: - DockerBuilder Tests

    @Test("BuildResult properties")
    func buildResultProperties() {
        let result = BuildResult(
            binaryPath: "/tmp/bootstrap",
            size: 25_000_000,
            duration: .seconds(45)
        )

        #expect(result.binaryPath == "/tmp/bootstrap")
        #expect(result.size == 25_000_000)
        #expect(result.duration == .seconds(45))
        #expect(result.sizeDescription.count > 0)
    }

    @Test("BuildResult size formatting")
    func buildResultSizeFormatting() {
        let smallResult = BuildResult(
            binaryPath: "/tmp/small",
            size: 100_000, // 100 KB
            duration: .seconds(10)
        )

        let largeResult = BuildResult(
            binaryPath: "/tmp/large",
            size: 50_000_000, // ~50 MB
            duration: .seconds(60)
        )

        // Verify size descriptions are human-readable
        #expect(!smallResult.sizeDescription.isEmpty)
        #expect(!largeResult.sizeDescription.isEmpty)
    }
}

@Suite("Dependency Config Tests")
struct DependencyConfigTests {

    @Test("DependencyConfig initialization")
    func dependencyConfigInit() {
        let dep = DependencyConfig(
            name: "surrealdb",
            image: "surrealdb/surrealdb:latest",
            ports: ["8000:8000"],
            command: ["start", "--log", "info", "--user", "root", "--pass", "root", "memory"]
        )

        #expect(dep.name == "surrealdb")
        #expect(dep.image == "surrealdb/surrealdb:latest")
        #expect(dep.ports == ["8000:8000"])
        #expect(dep.command == ["start", "--log", "info", "--user", "root", "--pass", "root", "memory"])
        #expect(dep.environment == nil)
        #expect(dep.healthcheck == nil)
        #expect(dep.volumes == nil)
    }

    @Test("DependencyConfig with all properties")
    func dependencyConfigFull() {
        let dep = DependencyConfig(
            name: "postgresql",
            image: "postgres:16-alpine",
            ports: ["5432:5432"],
            environment: ["POSTGRES_USER": "test", "POSTGRES_PASSWORD": "test"],
            healthcheck: HealthCheckConfig(port: 5432, interval: 2, retries: 10),
            volumes: ["/data:/var/lib/postgresql/data"]
        )

        #expect(dep.name == "postgresql")
        #expect(dep.environment?["POSTGRES_USER"] == "test")
        #expect(dep.healthcheck?.port == 5432)
        #expect(dep.healthcheck?.interval == 2)
        #expect(dep.healthcheck?.retries == 10)
        #expect(dep.volumes?.count == 1)
    }

    @Test("HealthCheckConfig with URL")
    func healthCheckConfigURL() {
        let hc = HealthCheckConfig(
            url: "http://localhost:4566/_localstack/health",
            interval: 3,
            retries: 20
        )

        #expect(hc.url == "http://localhost:4566/_localstack/health")
        #expect(hc.port == nil)
        #expect(hc.interval == 3)
        #expect(hc.retries == 20)
    }

    @Test("HealthCheckConfig with port")
    func healthCheckConfigPort() {
        let hc = HealthCheckConfig(port: 8000, interval: 1, retries: 5)

        #expect(hc.url == nil)
        #expect(hc.port == 8000)
        #expect(hc.interval == 1)
        #expect(hc.retries == 5)
    }

    @Test("TrebuchetConfig with dependencies")
    func configWithDependencies() {
        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(provider: "local", region: "local"),
            dependencies: [
                DependencyConfig(
                    name: "redis",
                    image: "redis:7-alpine",
                    ports: ["6379:6379"]
                )
            ]
        )

        #expect(config.dependencies?.count == 1)
        #expect(config.dependencies?.first?.name == "redis")
    }
}

@Suite("Dependency Config Parsing Tests")
struct DependencyConfigParsingTests {

    @Test("Parse YAML with dependencies")
    func parseYamlWithDependencies() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: surrealdb
                image: surrealdb/surrealdb:latest
                ports:
                  - "8000:8000"
                command:
                  - start
                  - "--log"
                  - info
                  - memory
                healthcheck:
                  port: 8000
                  interval: 2
                  retries: 15
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        #expect(config.dependencies?.count == 1)
        let dep = config.dependencies?.first
        #expect(dep?.name == "surrealdb")
        #expect(dep?.image == "surrealdb/surrealdb:latest")
        #expect(dep?.ports == ["8000:8000"])
        #expect(dep?.command == ["start", "--log", "info", "memory"])
        #expect(dep?.healthcheck?.port == 8000)
        #expect(dep?.healthcheck?.interval == 2)
        #expect(dep?.healthcheck?.retries == 15)
    }

    @Test("Parse YAML with multiple dependencies")
    func parseYamlMultipleDependencies() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: surrealdb
                image: surrealdb/surrealdb:latest
                ports:
                  - "8000:8000"
              - name: redis
                image: redis:7-alpine
                ports:
                  - "6379:6379"
                healthcheck:
                  port: 6379
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        #expect(config.dependencies?.count == 2)
        #expect(config.dependencies?[0].name == "surrealdb")
        #expect(config.dependencies?[1].name == "redis")
    }

    @Test("Parse YAML with dependency environment variables")
    func parseYamlDependencyEnvironment() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: postgresql
                image: postgres:16-alpine
                ports:
                  - "5432:5432"
                environment:
                  POSTGRES_USER: trebuchet
                  POSTGRES_PASSWORD: secret
                  POSTGRES_DB: mydb
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        let dep = config.dependencies?.first
        #expect(dep?.environment?["POSTGRES_USER"] == "trebuchet")
        #expect(dep?.environment?["POSTGRES_PASSWORD"] == "secret")
        #expect(dep?.environment?["POSTGRES_DB"] == "mydb")
    }

    @Test("Parse YAML without dependencies (backward compatibility)")
    func parseYamlWithoutDependencies() throws {
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

        #expect(config.dependencies == nil)
    }
}

@Suite("Dependency Validation Tests")
struct DependencyValidationTests {

    @Test("Validation rejects duplicate dependency names")
    func rejectsDuplicateNames() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: redis
                image: redis:7-alpine
              - name: redis
                image: redis:6-alpine
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for duplicate dependency names")
        } catch let error as ConfigError {
            #expect(error.description.contains("Duplicate dependency name"))
            #expect(error.description.contains("redis"))
        }
    }

    @Test("Validation rejects invalid dependency name")
    func rejectsInvalidName() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: "123invalid"
                image: redis:latest
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for invalid dependency name")
        } catch let error as ConfigError {
            #expect(error.description.contains("invalid"))
        }
    }

    @Test("Validation rejects empty image")
    func rejectsEmptyImage() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: myservice
                image: ""
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for empty image")
        } catch let error as ConfigError {
            #expect(error.description.contains("image must not be empty"))
        }
    }

    @Test("Validation rejects invalid port mapping")
    func rejectsInvalidPortMapping() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: myservice
                image: nginx:latest
                ports:
                  - "invalid"
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for invalid port mapping")
        } catch let error as ConfigError {
            #expect(error.description.contains("invalid port mapping"))
        }
    }

    @Test("Validation rejects healthcheck without url or port")
    func rejectsHealthcheckWithoutTarget() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: myservice
                image: nginx:latest
                healthcheck:
                  interval: 2
                  retries: 5
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for healthcheck without url or port")
        } catch let error as ConfigError {
            #expect(error.description.contains("healthcheck must specify either"))
        }
    }

    @Test("Validation rejects healthcheck with invalid interval")
    func rejectsInvalidHealthcheckInterval() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: myservice
                image: nginx:latest
                healthcheck:
                  port: 80
                  interval: 0
            """

        let loader = ConfigLoader()

        do {
            _ = try loader.parse(yaml: yaml)
            Issue.record("Expected validation error for invalid healthcheck interval")
        } catch let error as ConfigError {
            #expect(error.description.contains("healthcheck interval must be at least 1"))
        }
    }

    @Test("Validation accepts valid dependency config")
    func acceptsValidDependency() throws {
        let yaml = """
            name: test-project
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            dependencies:
              - name: surrealdb
                image: surrealdb/surrealdb:latest
                ports:
                  - "8000:8000"
                command:
                  - start
                  - memory
                healthcheck:
                  port: 8000
                  interval: 2
                  retries: 15
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)
        #expect(config.dependencies?.count == 1)
    }
}

@Suite("Dependency Orchestrator Tests")
struct DependencyOrchestratorTests {

    @Test("Orchestrator resolves no dependencies without config")
    func resolvesNoDependenciesWithoutConfig() {
        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: nil)
        #expect(deps.isEmpty)
    }

    @Test("Orchestrator resolves no dependencies when state store has no default")
    func resolvesNoDependenciesForUnknownStateStore() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            state: StateConfig(type: "memory")
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.isEmpty)
    }

    @Test("Orchestrator auto-detects SurrealDB dependency")
    func autoDetectsSurrealDB() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            state: StateConfig(type: "surrealdb")
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.count == 1)
        #expect(deps[0].name == "surrealdb")
        #expect(deps[0].image == "surrealdb/surrealdb:latest")
        #expect(deps[0].ports == ["8000:8000"])
    }

    @Test("Orchestrator auto-detects PostgreSQL dependency")
    func autoDetectsPostgreSQL() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            state: StateConfig(type: "postgresql")
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.count == 1)
        #expect(deps[0].name == "postgresql")
        #expect(deps[0].image == "postgres:16-alpine")
        #expect(deps[0].environment?["POSTGRES_USER"] == "trebuchet")
    }

    @Test("Orchestrator auto-detects DynamoDB/LocalStack dependency")
    func autoDetectsDynamoDB() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "aws", region: "us-east-1"),
            state: StateConfig(type: "dynamodb")
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.count == 1)
        #expect(deps[0].name == "localstack")
        #expect(deps[0].image == "localstack/localstack:3.0")
        #expect(deps[0].healthcheck?.url == "http://localhost:4566/_localstack/health")
    }

    @Test("Orchestrator combines auto-detected and explicit dependencies")
    func combinesAutoAndExplicit() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            state: StateConfig(type: "surrealdb"),
            dependencies: [
                DependencyConfig(
                    name: "redis",
                    image: "redis:7-alpine",
                    ports: ["6379:6379"]
                )
            ]
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.count == 2)
        #expect(deps[0].name == "redis")       // explicit first
        #expect(deps[1].name == "surrealdb")   // auto-detected second
    }

    @Test("Orchestrator deduplicates dependencies by name, explicit wins")
    func deduplicatesDependencies() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            state: StateConfig(type: "surrealdb"),
            dependencies: [
                DependencyConfig(
                    name: "surrealdb",
                    image: "surrealdb/surrealdb:v1.5.0",
                    ports: ["9000:8000"]
                )
            ]
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        // Explicit config should win over auto-detected
        #expect(deps.count == 1)
        #expect(deps[0].name == "surrealdb")
        #expect(deps[0].image == "surrealdb/surrealdb:v1.5.0")
        #expect(deps[0].ports == ["9000:8000"])
    }

    @Test("Orchestrator with only explicit dependencies")
    func onlyExplicitDependencies() {
        let config = TrebuchetConfig(
            name: "test",
            defaults: DefaultSettings(provider: "local", region: "local"),
            dependencies: [
                DependencyConfig(
                    name: "meilisearch",
                    image: "getmeili/meilisearch:latest",
                    ports: ["7700:7700"],
                    healthcheck: HealthCheckConfig(
                        url: "http://localhost:7700/health",
                        interval: 2,
                        retries: 10
                    )
                )
            ]
        )

        let orchestrator = DependencyOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test"
        )

        let deps = orchestrator.resolveDependencies(config: config)
        #expect(deps.count == 1)
        #expect(deps[0].name == "meilisearch")
        #expect(deps[0].healthcheck?.url == "http://localhost:7700/health")
    }
}

#if os(macOS)
@Suite("Compote Orchestrator Tests")
struct CompoteOrchestratorTests {

    @Test("Compote loads config from configured project directory, not cwd")
    func loadsConfigFromConfiguredDirectory() throws {
        let fileManager = FileManager.default
        let projectDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let otherDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        try fileManager.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: otherDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(atPath: projectDir)
            try? fileManager.removeItem(atPath: otherDir)
        }

        let yaml = """
            name: path-config-test
            version: "1"
            defaults:
              provider: local
              region: local
              memory: 512
              timeout: 30
            actors: {}
            state:
              type: surrealdb
            """

        try yaml.write(
            toFile: "\(projectDir)/trebuchet.yaml",
            atomically: true,
            encoding: .utf8
        )

        let originalCwd = fileManager.currentDirectoryPath
        defer {
            _ = fileManager.changeCurrentDirectoryPath(originalCwd)
        }
        _ = fileManager.changeCurrentDirectoryPath(otherDir)

        let orchestrator = CompoteOrchestrator(
            terminal: Terminal(useColors: false),
            verbose: false,
            projectName: "test",
            configDirectory: projectDir
        )

        let config = orchestrator.getCurrentConfig()
        #expect(config?.name == "path-config-test")
        #expect(config?.state?.type == "surrealdb")
    }
}
#endif

@Suite("Orchestrator Error Tests")
struct OrchestratorErrorTests {

    @Test("OrchestratorError descriptions")
    func errorDescriptions() {
        let errors: [(OrchestratorError, String)] = [
            (.dockerNotAvailable, "Docker is not installed"),
            (.portConflict(port: 8080, dependency: "redis"), "Port 8080"),
            (.healthCheckFailed(dependency: "surrealdb", attempts: 10), "surrealdb failed to become ready"),
            (.containerExited(dependency: "postgres", message: "Exit code 1"), "postgres container exited"),
            (.dockerCommandFailed(command: "docker run test", exitCode: 1), "Docker command failed"),
        ]

        for (error, expectedSubstring) in errors {
            #expect(error.description.contains(expectedSubstring),
                    "Expected '\(expectedSubstring)' in: \(error.description)")
        }
    }
}
#endif
