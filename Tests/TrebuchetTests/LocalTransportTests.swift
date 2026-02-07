//===----------------------------------------------------------------------===//
//
// This source file is part of the Trebuchet open source project
//
// Copyright (c) 2024 Trebuchet project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import Distributed
@testable import Trebuchet

// Test actors at module scope (macros can't be applied to local types)
@Trebuchet
distributed actor LocalTestCounter {
    var count: Int = 0

    distributed func increment() -> Int {
        count += 1
        return count
    }

    distributed func getValue() -> Int {
        return count
    }
}

@Trebuchet
distributed actor LocalTestGreeter {
    distributed func greet(name: String) -> String {
        return "Hello, \(name)!"
    }
}

@Trebuchet
distributed actor LocalTestDataStore {
    var data: [String: String] = [:]

    distributed func set(key: String, value: String) {
        data[key] = value
    }

    distributed func get(key: String) -> String? {
        return data[key]
    }
}

struct LocalTestData: Codable, Sendable {
    let items: [String]
}

@Trebuchet
distributed actor LocalTestDataProcessor {
    distributed func process(_ data: LocalTestData) -> Int {
        return data.items.count
    }
}

@Trebuchet
distributed actor LocalTestServiceA {
    distributed func getName() -> String { "ServiceA" }
}

@Trebuchet
distributed actor LocalTestServiceB {
    distributed func getName() -> String { "ServiceB" }
}

@Trebuchet
distributed actor LocalTestActorWithID {
    distributed func getId() -> TrebuchetActorID {
        return self.id
    }
}

@Suite("Local Transport Tests")
struct LocalTransportTests {

    @Test("Local transport basic connection")
    func testBasicConnection() async throws {
        let client = TrebuchetClient(transport: .local)

        // Connect should succeed immediately (no-op for local transport)
        try await client.connect()

        // Connection succeeded without errors
        #expect(true)
    }

    @Test("Local transport actor invocation")
    func testActorInvocation() async throws {
        // Use shared local transport
        let server = LocalTransport.shared.server
        let client = TrebuchetClient(transport: .local)

        // Expose actor on server
        let counter = LocalTestCounter(actorSystem: server.actorSystem)
        await server.expose(counter, as: "counter-test")

        // Connect client
        try await client.connect()

        // Resolve actor
        let remoteCounter = try client.resolve(LocalTestCounter.self, id: "counter-test")

        // Test invocation
        let value1 = try await remoteCounter.increment()
        #expect(value1 == 1)

        let value2 = try await remoteCounter.increment()
        #expect(value2 == 2)

        let finalValue = try await remoteCounter.getValue()
        #expect(finalValue == 2)
    }

    @Test("TrebuchetLocal unified API")
    func testTrebuchetLocalAPI() async throws {
        let local = await TrebuchetLocal()

        // Expose actor
        let actor = LocalTestGreeter(actorSystem: local.actorSystem)
        await local.expose(actor, as: "greeter-test")

        // Resolve actor
        let resolved = try local.resolve(LocalTestGreeter.self, id: "greeter-test")

        // Invoke method
        let greeting = try await resolved.greet(name: "World")
        #expect(greeting == "Hello, World!")
    }

    @Test("TrebuchetLocal factory pattern")
    func testFactoryPattern() async throws {
        let local = await TrebuchetLocal()

        // Use factory pattern to create and expose
        let store = await local.expose("store-test") { actorSystem in
            LocalTestDataStore(actorSystem: actorSystem)
        }

        // Use the exposed actor directly
        try await store.set(key: "name", value: "Alice")
        let value = try await store.get(key: "name")
        #expect(value == "Alice")

        // Also resolve it by ID
        let resolved = try local.resolve(LocalTestDataStore.self, id: "store-test")
        let resolvedValue = try await resolved.get(key: "name")
        #expect(resolvedValue == "Alice")
    }

    @Test("Local transport zero serialization overhead")
    func testZeroSerializationOverhead() async throws {
        let local = await TrebuchetLocal()

        let processor = LocalTestDataProcessor(actorSystem: local.actorSystem)
        await local.expose(processor, as: "processor-test")

        let resolved = try local.resolve(LocalTestDataProcessor.self, id: "processor-test")

        // Create large payload
        let largeData = LocalTestData(items: Array(repeating: "test", count: 10000))

        // Measure time
        let start = ContinuousClock.now
        let result = try await resolved.process(largeData)
        let duration = ContinuousClock.now - start

        #expect(result == 10000)

        // Local transport should be very fast (< 100ms even for large payloads)
        #expect(duration < .milliseconds(100))
    }

    @Test("Multiple actors on local transport")
    func testMultipleActors() async throws {
        let local = await TrebuchetLocal()

        let serviceA = LocalTestServiceA(actorSystem: local.actorSystem)
        let serviceB = LocalTestServiceB(actorSystem: local.actorSystem)

        await local.expose(serviceA, as: "service-a-test")
        await local.expose(serviceB, as: "service-b-test")

        let resolvedA = try local.resolve(LocalTestServiceA.self, id: "service-a-test")
        let resolvedB = try local.resolve(LocalTestServiceB.self, id: "service-b-test")

        let nameA = try await resolvedA.getName()
        let nameB = try await resolvedB.getName()

        #expect(nameA == "ServiceA")
        #expect(nameB == "ServiceB")
    }

    @Test("Local transport endpoint configuration")
    func testEndpointConfiguration() {
        let config = TransportConfiguration.local

        // Verify endpoint is set to "local:0"
        #expect(config.endpoint.host == "local")
        #expect(config.endpoint.port == 0)

        // Verify TLS is disabled
        #expect(config.tlsEnabled == false)
        #expect(config.tlsConfiguration == nil)
    }

    @Test("Local actor ID format")
    func testLocalActorID() async throws {
        let local = await TrebuchetLocal()

        let actor = LocalTestActorWithID(actorSystem: local.actorSystem)
        await local.expose(actor, as: "test-id")

        let actorID = try await actor.getId()

        // Verify the actor ID is local (no host/port)
        #expect(actorID.isLocal)
    }
}
