import Testing
@testable import Trebuchet

@Trebuchet
public distributed actor SystemCats {
    public init(actorSystem: TrebuchetRuntime) {
        self.actorSystem = actorSystem
    }

    distributed func ping() -> String {
        "meow"
    }
}

@Trebuchet
public distributed actor SystemDogs {
    public init(actorSystem: TrebuchetRuntime) {
        self.actorSystem = actorSystem
    }

    distributed func ping() -> String {
        "woof"
    }
}

struct BasicPetsSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .expose(as: "cats")
                .deploy(.aws(region: "us-east-1", lambda: AWSLambdaOptions(memory: 1024)))

            SystemDogs.self
                .expose(as: "dogs")
                .deploy(.fly(app: "pets-edge", region: "iad"))
        }
        .network(.public)
    }
}

struct InlineWinsSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .expose(as: "cats")
                .deploy(.aws(region: "us-east-1", lambda: AWSLambdaOptions(memory: 1024)))

            SystemDogs.self
                .expose(as: "dogs")
                .deploy(.aws(lambda: AWSLambdaOptions(memory: 512)))
        }
    }

    @DeploymentsBuilder
    var deployments: some Deployments {
        Environment("production") {
            ClusterSelector("edge")
                .deploy(.aws(region: "us-west-2", lambda: AWSLambdaOptions(memory: 2048, timeout: 45)))
        }
    }
}

struct InvalidSelectorSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .expose(as: "cats")
        }
    }

    @DeploymentsBuilder
    var deployments: some Deployments {
        Environment("production") {
            Actor("missing")
                .deploy(.aws(region: "us-west-2"))
        }
    }
}

struct DuplicateExposeSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .expose(as: "pets")
            SystemDogs.self
                .expose(as: "pets")
        }
    }
}

struct DynamicPrefixSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .dynamic(prefix: "cat-") { runtime, _ in
                    SystemCats(actorSystem: runtime)
                }
                .expose(as: "cats")

            SystemDogs.self
                .expose(as: "dogs")
        }
    }
}

struct DuplicateDynamicPrefixSystem: System {
    var topology: some Topology {
        Cluster("edge") {
            SystemCats.self
                .dynamic(prefix: "pet-") { runtime, _ in
                    SystemCats(actorSystem: runtime)
                }
                .expose(as: "cats")

            SystemDogs.self
                .dynamic(prefix: "pet-") { runtime, _ in
                    SystemDogs(actorSystem: runtime)
                }
                .expose(as: "dogs")
        }
    }
}

@Suite("System DSL")
struct SystemDSLTests {
    @Test("System descriptor captures actors and cluster metadata")
    func descriptorCapturesActors() throws {
        let descriptor = try BasicPetsSystem.descriptor()

        #expect(descriptor.systemName.contains("BasicPetsSystem"))
        #expect(descriptor.actors.count == 2)

        let actorNames = Set(descriptor.actors.map(\.exposeName))
        #expect(actorNames == Set(["cats", "dogs"]))

        for actor in descriptor.actors {
            #expect(actor.clusterPath == ["edge"])
            #expect(actor.network == .public)
        }
    }

    @Test("Inline deployment values override deployments block conflicts")
    func inlineOverridesDeploymentBlock() throws {
        let plan = try InlineWinsSystem.deploymentPlan(provider: "aws", environment: "production")

        let cats = try #require(plan.actors.first(where: { $0.exposeName == "cats" }))
        #expect(cats.aws?.region == "us-east-1")
        #expect(cats.aws?.memory == 1024)
        #expect(cats.aws?.timeout == 45)

        #expect(plan.warnings.contains(where: { $0.contains("cats") && $0.contains("region") }))
        #expect(plan.warnings.contains(where: { $0.contains("cats") && $0.contains("memory") }))
    }

    @Test("Deployments block fills missing inline values")
    func deploymentsFillMissingValues() throws {
        let plan = try InlineWinsSystem.deploymentPlan(provider: "aws", environment: "production")

        let dogs = try #require(plan.actors.first(where: { $0.exposeName == "dogs" }))
        #expect(dogs.aws?.memory == 512)
        #expect(dogs.aws?.timeout == 45)
        #expect(dogs.aws?.region == "us-west-2")
    }

    @Test("Invalid deployment selectors fail validation")
    func invalidSelectorFailsValidation() {
        do {
            _ = try InvalidSelectorSystem.descriptor()
            Issue.record("Expected invalid selector to fail descriptor build.")
        } catch let error as TrebuchetError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("Expected TrebuchetError.invalidConfiguration but got: \(error)")
                return
            }
            #expect(message.contains("matched no actors"))
            #expect(message.contains("Actor(\"missing\")"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Duplicate expose names fail validation")
    func duplicateExposeFailsValidation() {
        do {
            _ = try DuplicateExposeSystem.descriptor()
            Issue.record("Expected duplicate expose name to fail descriptor build.")
        } catch let error as TrebuchetError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("Expected TrebuchetError.invalidConfiguration but got: \(error)")
                return
            }
            #expect(message.contains("Duplicate actor expose name detected"))
            #expect(message.contains("pets"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Dynamic prefix registration compiles and preserves actor descriptor shape")
    func dynamicPrefixDescriptorShape() throws {
        let descriptor = try DynamicPrefixSystem.descriptor()
        #expect(descriptor.actors.count == 2)
        #expect(descriptor.actors.map(\.exposeName) == ["cats", "dogs"])
    }

    @Test("Duplicate dynamic prefixes fail validation")
    func duplicateDynamicPrefixFailsValidation() {
        do {
            _ = try DuplicateDynamicPrefixSystem.descriptor()
            Issue.record("Expected duplicate dynamic prefix to fail descriptor build.")
        } catch let error as TrebuchetError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("Expected TrebuchetError.invalidConfiguration but got: \(error)")
                return
            }
            #expect(message.contains("Duplicate dynamic actor prefix"))
            #expect(message.contains("pet-"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
