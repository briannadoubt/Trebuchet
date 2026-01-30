import Testing
import Foundation
@testable import TrebuchetAWS
@testable import TrebuchetCloud

@Suite("Cloud Map Registry Integration Tests")
struct CloudMapRegistryIntegrationTests {

    init() async throws {
        // Skip all tests if LocalStack is not available
        guard await LocalStackTestHelpers.isLocalStackAvailable() else {
            throw TestSkipError()
        }
    }

    @Test("Register and resolve actor endpoint")
    func testRegisterAndResolve() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Register actor
        let endpoint = CloudEndpoint(
            provider: .aws,
            region: "us-east-1",
            identifier: "arn:aws:lambda:us-east-1:123:function:test",
            scheme: .lambda,
            metadata: ["type": "GameRoom"]
        )
        try await registry.register(
            actorID: actorId,
            endpoint: endpoint,
            metadata: ["version": "1.0"],
            ttl: nil
        )

        // Resolve actor
        let resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved != nil)
        #expect(resolved?.provider == .aws)
        #expect(resolved?.region == "us-east-1")
        #expect(resolved?.scheme == .lambda)

        try await client.shutdown()
    }

    @Test("Resolve returns nil for non-existent actor")
    func testResolveNonExistent() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        let resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved == nil)

        try await client.shutdown()
    }

    @Test("Deregister removes actor")
    func testDeregister() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Register actor
        let endpoint = CloudEndpoint(
            provider: .aws,
            region: "us-east-1",
            identifier: "arn:aws:lambda:us-east-1:123:function:test",
            scheme: .lambda
        )
        try await registry.register(
            actorID: actorId,
            endpoint: endpoint,
            metadata: [:],
            ttl: nil
        )

        // Verify registered
        var resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved != nil)

        // Deregister
        try await registry.deregister(actorID: actorId)

        // Verify removed
        resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved == nil)

        try await client.shutdown()
    }

    @Test("List actors with prefix filter")
    func testListActors() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let prefix = "list-test-\(UUID().uuidString.prefix(8))"

        // Register multiple actors with same prefix
        for i in 0..<3 {
            let actorId = "\(prefix)-actor-\(i)"
            let endpoint = CloudEndpoint(
                provider: .aws,
                region: "us-east-1",
                identifier: "arn:aws:lambda:us-east-1:123:function:test-\(i)",
                scheme: .lambda
            )
            try await registry.register(
                actorID: actorId,
                endpoint: endpoint,
                metadata: [:],
                ttl: nil
            )
        }

        // List actors with prefix
        let actors = try await registry.list(prefix: prefix)
        #expect(actors.count >= 3)

        // Verify all registered actors are in the list
        for i in 0..<3 {
            let actorId = "\(prefix)-actor-\(i)"
            #expect(actors.contains(actorId))
        }

        // Cleanup
        for i in 0..<3 {
            let actorId = "\(prefix)-actor-\(i)"
            try? await registry.deregister(actorID: actorId)
        }

        try await client.shutdown()
    }

    @Test("Heartbeat updates registration")
    func testHeartbeat() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Register actor
        let endpoint = CloudEndpoint(
            provider: .aws,
            region: "us-east-1",
            identifier: "arn:aws:lambda:us-east-1:123:function:test",
            scheme: .lambda
        )
        try await registry.register(
            actorID: actorId,
            endpoint: endpoint,
            metadata: [:],
            ttl: nil
        )

        // Send heartbeat
        try await registry.heartbeat(actorID: actorId)

        // Verify still registered
        let resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved != nil)

        // Cleanup
        try? await registry.deregister(actorID: actorId)

        try await client.shutdown()
    }
}
