import Testing
import Foundation
@testable import TrebucheCloud
@testable import Trebuche

// MARK: - Cloud Endpoint Tests

@Suite("CloudEndpoint Tests")
struct CloudEndpointTests {
    @Test("AWS Lambda endpoint creation")
    func awsLambdaEndpoint() {
        let endpoint = CloudEndpoint.awsLambda(
            functionArn: "arn:aws:lambda:us-east-1:123456789:function:my-actor",
            region: "us-east-1"
        )

        #expect(endpoint.provider == .aws)
        #expect(endpoint.region == "us-east-1")
        #expect(endpoint.scheme == .lambda)
        #expect(endpoint.identifier.contains("arn:aws:lambda"))
    }

    @Test("Kubernetes endpoint creation")
    func kubernetesEndpoint() {
        let endpoint = CloudEndpoint.kubernetes(
            serviceName: "actor-service",
            namespace: "production",
            port: 8080
        )

        #expect(endpoint.provider == .kubernetes)
        #expect(endpoint.region == "production")
        #expect(endpoint.scheme == .http)
        #expect(endpoint.identifier == "actor-service.production.svc.cluster.local:8080")
    }

    @Test("HTTP endpoint converts to Trebuche Endpoint")
    func httpEndpointConversion() {
        let cloudEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )

        let endpoint = cloudEndpoint.toEndpoint()

        #expect(endpoint != nil)
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 8080)
    }

    @Test("Lambda endpoint does not convert to Trebuche Endpoint")
    func lambdaEndpointNoConversion() {
        let endpoint = CloudEndpoint.awsLambda(
            functionArn: "arn:aws:lambda:us-east-1:123456789:function:test",
            region: "us-east-1"
        )

        #expect(endpoint.toEndpoint() == nil)
    }

    @Test("GCP Cloud Function endpoint uses proper URL format")
    func gcpCloudFunctionEndpoint() {
        let endpoint = CloudEndpoint.gcpCloudFunction(
            name: "my-function",
            project: "my-project",
            region: "us-central1"
        )

        #expect(endpoint.provider == .gcp)
        #expect(endpoint.region == "us-central1")
        #expect(endpoint.scheme == .https)
        // Should be a proper URL, not a resource path
        #expect(endpoint.identifier == "https://us-central1-my-project.cloudfunctions.net/my-function")
        #expect(endpoint.metadata["generation"] == "1")

        // Should convert to a valid Trebuche Endpoint
        let trebucheEndpoint = endpoint.toEndpoint()
        #expect(trebucheEndpoint != nil)
        #expect(trebucheEndpoint?.host == "us-central1-my-project.cloudfunctions.net")
        #expect(trebucheEndpoint?.port == 443)

        // Should have the correct path
        #expect(endpoint.path == "/my-function")
    }

    @Test("GCP Cloud Function direct endpoint uses resource path")
    func gcpCloudFunctionDirectEndpoint() {
        let endpoint = CloudEndpoint.gcpCloudFunctionDirect(
            name: "my-function",
            project: "my-project",
            region: "us-central1"
        )

        #expect(endpoint.scheme == .cloudFunction)
        #expect(endpoint.identifier.contains("projects/my-project"))
        // Direct invocation doesn't convert to HTTP endpoint
        #expect(endpoint.toEndpoint() == nil)
    }

    @Test("HTTPS URL with path parses correctly")
    func httpsUrlWithPath() {
        let endpoint = CloudEndpoint(
            provider: .gcp,
            region: "us-central1",
            identifier: "https://example.cloudfunctions.net/myfunction",
            scheme: .https
        )

        let trebucheEndpoint = endpoint.toEndpoint()
        #expect(trebucheEndpoint?.host == "example.cloudfunctions.net")
        #expect(trebucheEndpoint?.port == 443)
        #expect(endpoint.path == "/myfunction")
    }
}

// MARK: - Service Registry Tests

@Suite("InMemoryRegistry Tests")
struct InMemoryRegistryTests {
    @Test("Register and resolve actor")
    func registerAndResolve() async throws {
        let registry = InMemoryRegistry()
        let endpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )

        try await registry.register(
            actorID: "test-actor",
            endpoint: endpoint,
            metadata: ["type": "TestActor"],
            ttl: nil
        )

        let resolved = try await registry.resolve(actorID: "test-actor")

        #expect(resolved != nil)
        #expect(resolved?.identifier == "localhost:8080")
    }

    @Test("Resolve non-existent actor returns nil")
    func resolveNonExistent() async throws {
        let registry = InMemoryRegistry()
        let resolved = try await registry.resolve(actorID: "non-existent")
        #expect(resolved == nil)
    }

    @Test("Deregister removes actor")
    func deregister() async throws {
        let registry = InMemoryRegistry()
        let endpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )

        try await registry.register(
            actorID: "test-actor",
            endpoint: endpoint,
            metadata: [:],
            ttl: nil
        )

        try await registry.deregister(actorID: "test-actor")

        let resolved = try await registry.resolve(actorID: "test-actor")
        #expect(resolved == nil)
    }

    @Test("List actors with prefix filter")
    func listWithPrefix() async throws {
        let registry = InMemoryRegistry()
        let endpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )

        try await registry.register(actorID: "game-room-1", endpoint: endpoint, metadata: [:], ttl: nil)
        try await registry.register(actorID: "game-room-2", endpoint: endpoint, metadata: [:], ttl: nil)
        try await registry.register(actorID: "lobby", endpoint: endpoint, metadata: [:], ttl: nil)

        let gameRooms = try await registry.list(prefix: "game-room")
        let all = try await registry.list(prefix: nil)

        #expect(gameRooms.count == 2)
        #expect(all.count == 3)
    }

    @Test("Resolve all endpoints for load balancing")
    func resolveAll() async throws {
        let registry = InMemoryRegistry()

        let endpoint1 = CloudEndpoint(provider: .local, region: "local", identifier: "host1:8080", scheme: .http)
        let endpoint2 = CloudEndpoint(provider: .local, region: "local", identifier: "host2:8080", scheme: .http)

        try await registry.register(actorID: "replicated-actor", endpoint: endpoint1, metadata: [:], ttl: nil)
        try await registry.register(actorID: "replicated-actor", endpoint: endpoint2, metadata: [:], ttl: nil)

        let endpoints = try await registry.resolveAll(actorID: "replicated-actor")

        #expect(endpoints.count == 2)
    }
}

// MARK: - Local Development Registry Tests

@Suite("LocalDevelopmentRegistry Tests")
struct LocalDevelopmentRegistryTests {
    @Test("Returns default endpoint for any actor ID")
    func defaultEndpointForAnyActor() async throws {
        let defaultEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )
        let registry = LocalDevelopmentRegistry(defaultEndpoint: defaultEndpoint)

        // Should return default for any actor ID, even unregistered ones
        let endpoint1 = try await registry.resolve(actorID: "actor-1")
        let endpoint2 = try await registry.resolve(actorID: "actor-2")
        let endpoint3 = try await registry.resolve(actorID: "completely-random-name")

        #expect(endpoint1?.identifier == "localhost:8080")
        #expect(endpoint2?.identifier == "localhost:8080")
        #expect(endpoint3?.identifier == "localhost:8080")
    }

    @Test("Specific registration overrides default")
    func specificRegistrationOverridesDefault() async throws {
        let defaultEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )
        let specificEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:9000",
            scheme: .http
        )
        let registry = LocalDevelopmentRegistry(defaultEndpoint: defaultEndpoint)

        try await registry.register(
            actorID: "special-actor",
            endpoint: specificEndpoint,
            metadata: [:],
            ttl: nil
        )

        // Specific actor gets specific endpoint
        let special = try await registry.resolve(actorID: "special-actor")
        #expect(special?.identifier == "localhost:9000")

        // Other actors still get default
        let other = try await registry.resolve(actorID: "other-actor")
        #expect(other?.identifier == "localhost:8080")
    }

    @Test("Deregister falls back to default")
    func deregisterFallsBackToDefault() async throws {
        let defaultEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:8080",
            scheme: .http
        )
        let specificEndpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:9000",
            scheme: .http
        )
        let registry = LocalDevelopmentRegistry(defaultEndpoint: defaultEndpoint)

        try await registry.register(actorID: "actor", endpoint: specificEndpoint, metadata: [:], ttl: nil)
        try await registry.deregister(actorID: "actor")

        // After deregister, should fall back to default (not nil)
        let resolved = try await registry.resolve(actorID: "actor")
        #expect(resolved?.identifier == "localhost:8080")
    }
}

// MARK: - State Store Tests

@Suite("InMemoryStateStore Tests")
struct InMemoryStateStoreTests {
    struct TestState: Codable, Sendable, Equatable {
        var counter: Int
        var name: String
    }

    @Test("Save and load state")
    func saveAndLoad() async throws {
        let store = InMemoryStateStore()
        let state = TestState(counter: 42, name: "Test")

        try await store.save(state, for: "actor-1")
        let loaded = try await store.load(for: "actor-1", as: TestState.self)

        #expect(loaded == state)
    }

    @Test("Load non-existent state returns nil")
    func loadNonExistent() async throws {
        let store = InMemoryStateStore()
        let loaded = try await store.load(for: "non-existent", as: TestState.self)
        #expect(loaded == nil)
    }

    @Test("Delete state")
    func deleteState() async throws {
        let store = InMemoryStateStore()
        let state = TestState(counter: 1, name: "ToDelete")

        try await store.save(state, for: "actor-1")
        try await store.delete(for: "actor-1")

        let exists = try await store.exists(for: "actor-1")
        #expect(!exists)
    }

    @Test("Update state atomically")
    func updateState() async throws {
        let store = InMemoryStateStore()
        let initial = TestState(counter: 0, name: "Counter")

        try await store.save(initial, for: "actor-1")

        let updated = try await store.update(for: "actor-1", as: TestState.self) { current in
            var state = current ?? TestState(counter: 0, name: "New")
            state.counter += 1
            return state
        }

        #expect(updated.counter == 1)

        let loaded = try await store.load(for: "actor-1", as: TestState.self)
        #expect(loaded?.counter == 1)
    }

    @Test("Version increments on save")
    func versionIncrement() async throws {
        let store = InMemoryStateStore()
        let state = TestState(counter: 1, name: "Versioned")

        let v0 = await store.version(for: "actor-1")
        #expect(v0 == 0)

        try await store.save(state, for: "actor-1")
        let v1 = await store.version(for: "actor-1")
        #expect(v1 == 1)

        try await store.save(state, for: "actor-1")
        let v2 = await store.version(for: "actor-1")
        #expect(v2 == 2)
    }
}

// MARK: - Cloud Error Tests

@Suite("CloudError Tests")
struct CloudErrorTests {
    @Test("Error descriptions are meaningful")
    func errorDescriptions() {
        let deployError = CloudError.deploymentFailed(provider: .aws, reason: "Quota exceeded")
        #expect(deployError.description.contains("Amazon Web Services"))
        #expect(deployError.description.contains("Quota exceeded"))

        let notFoundError = CloudError.actorNotFound(actorID: "missing", provider: .gcp)
        #expect(notFoundError.description.contains("missing"))
        #expect(notFoundError.description.contains("Google Cloud Platform"))

        let timeoutError = CloudError.timeout(operation: "invoke", duration: .seconds(30))
        #expect(timeoutError.description.contains("invoke"))
        #expect(timeoutError.description.contains("30"))
    }
}

// MARK: - Function Configuration Tests

@Suite("FunctionConfiguration Tests")
struct FunctionConfigurationTests {
    @Test("Default configuration values")
    func defaultValues() {
        let config = FunctionConfiguration()

        #expect(config.memoryMB == 256)
        #expect(config.concurrency == nil)
        #expect(config.environment.isEmpty)
    }

    @Test("Preset configurations")
    func presets() {
        #expect(FunctionConfiguration.small.memoryMB == 128)
        #expect(FunctionConfiguration.medium.memoryMB == 512)
        #expect(FunctionConfiguration.large.memoryMB == 1024)
        #expect(FunctionConfiguration.xlarge.memoryMB == 2048)
    }
}

// MARK: - Deployment Status Tests

@Suite("DeploymentStatus Tests")
struct DeploymentStatusTests {
    @Test("Only active status is healthy")
    func healthyStatus() {
        #expect(DeploymentStatus.active.isHealthy)
        #expect(!DeploymentStatus.deploying.isHealthy)
        #expect(!DeploymentStatus.updating.isHealthy)
        #expect(!DeploymentStatus.failed(reason: "error").isHealthy)
        #expect(!DeploymentStatus.removing.isHealthy)
        #expect(!DeploymentStatus.removed.isHealthy)
    }
}

// MARK: - Local Deployment Tests

@Suite("LocalDeployment Tests")
struct LocalDeploymentTests {
    @Test("Local deployment creates correct endpoint")
    func deploymentEndpoint() {
        let deployment = LocalDeployment(
            actorID: "test-actor",
            host: "localhost",
            port: 9000,
            actorType: "TestActor"
        )

        #expect(deployment.provider == .local)
        #expect(deployment.identifier == "localhost:9000")
        #expect(deployment.endpoint.scheme == .http)
        #expect(deployment.trebucheEndpoint.host == "localhost")
        #expect(deployment.trebucheEndpoint.port == 9000)
    }
}
