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
        let command = CommandConfig(script: "trebuchet dev")
        #expect(command.script == "trebuchet dev")
    }

    @Test("TrebuchetConfig with commands")
    func configWithCommands() {
        let config = TrebuchetConfig(
            name: "test-project",
            defaults: DefaultSettings(provider: "fly", region: "iad"),
            commands: [
                "Run Locally": CommandConfig(script: "trebuchet dev"),
                "Deploy": CommandConfig(script: "trebuchet deploy")
            ]
        )

        #expect(config.commands?.count == 2)
        #expect(config.commands?["Run Locally"]?.script == "trebuchet dev")
        #expect(config.commands?["Deploy"]?.script == "trebuchet deploy")
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
        #expect(yaml.contains("Run Locally"))
        #expect(yaml.contains("trebuchet dev"))
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
              "Run Locally":
                script: trebuchet dev
              "Deploy Staging":
                script: trebuchet deploy --environment staging
            """

        let loader = ConfigLoader()
        let config = try loader.parse(yaml: yaml)

        #expect(config.commands?.count == 2)
        #expect(config.commands?["Run Locally"]?.script == "trebuchet dev")
        #expect(config.commands?["Deploy Staging"]?.script == "trebuchet deploy --environment staging")
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

    @Test("CommandPluginGenerator verb from name")
    func commandPluginGeneratorVerbFromName() {
        #expect(CommandPluginGenerator.verbFromName("Run Locally") == "run-locally")
        #expect(CommandPluginGenerator.verbFromName("Deploy Staging") == "deploy-staging")
        #expect(CommandPluginGenerator.verbFromName("Run Tests") == "run-tests")
        #expect(CommandPluginGenerator.verbFromName("my-custom-cmd") == "my-custom-cmd")
        #expect(CommandPluginGenerator.verbFromName("Build & Deploy") == "build-deploy")
    }

    @Test("CommandPluginGenerator plugin target name from name")
    func commandPluginGeneratorTargetName() {
        #expect(CommandPluginGenerator.pluginTargetName(from: "Run Locally") == "RunLocallyPlugin")
        #expect(CommandPluginGenerator.pluginTargetName(from: "Deploy Staging") == "DeployStagingPlugin")
        #expect(CommandPluginGenerator.pluginTargetName(from: "Run Tests") == "RunTestsPlugin")
    }

    @Test("CommandPluginGenerator struct name from name")
    func commandPluginGeneratorStructName() {
        #expect(CommandPluginGenerator.structName(from: "Run Locally") == "RunLocallyCommand")
        #expect(CommandPluginGenerator.structName(from: "Deploy Staging") == "DeployStagingCommand")
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
                "Run Locally": CommandConfig(script: "trebuchet dev"),
                "Deploy Staging": CommandConfig(script: "trebuchet deploy --environment staging")
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

        // Verify "Run Locally" plugin content
        let runLocallyContent = try String(
            contentsOfFile: "\(tempDir)/Plugins/RunLocallyPlugin/plugin.swift",
            encoding: .utf8
        )
        #expect(runLocallyContent.contains("import PackagePlugin"))
        #expect(runLocallyContent.contains("struct RunLocallyCommand: CommandPlugin"))
        #expect(runLocallyContent.contains("trebuchet dev"))
        #expect(runLocallyContent.contains("/bin/sh"))

        // Verify "Deploy Staging" plugin content
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
                name: "Run Locally",
                targetName: "RunLocallyPlugin",
                verb: "run-locally",
                script: "trebuchet dev"
            )
        ]

        let snippet = generator.generatePackageSnippet(plugins: plugins)

        #expect(snippet.contains("RunLocallyPlugin"))
        #expect(snippet.contains("run-locally"))
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
#endif
