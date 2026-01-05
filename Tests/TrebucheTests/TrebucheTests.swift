import Testing
import Distributed
import Foundation
@testable import Trebuche

// MARK: - Actor ID Tests

@Suite("TrebuchetActorID")
struct ActorIDTests {
    @Test func localActorID() {
        let id = TrebuchetActorID(id: "test-actor")
        #expect(id.isLocal)
        #expect(!id.isRemote)
        #expect(id.endpoint == "test-actor")
    }

    @Test func remoteActorID() {
        let id = TrebuchetActorID(id: "test-actor", host: "localhost", port: 8080)
        #expect(!id.isLocal)
        #expect(id.isRemote)
        #expect(id.endpoint == "test-actor@localhost:8080")
    }

    @Test func parseLocalID() {
        let id = TrebuchetActorID(parsing: "test-actor")
        #expect(id != nil)
        #expect(id?.id == "test-actor")
        #expect(id?.isLocal == true)
    }

    @Test func parseRemoteID() {
        let id = TrebuchetActorID(parsing: "test-actor@example.com:9000")
        #expect(id != nil)
        #expect(id?.id == "test-actor")
        #expect(id?.host == "example.com")
        #expect(id?.port == 9000)
    }
}

// MARK: - Serialization Tests

@Suite("Serialization")
struct SerializationTests {
    @Test func invocationEnvelopeRoundTrip() throws {
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "actor-1", host: "localhost", port: 8080),
            targetIdentifier: "doSomething()",
            genericSubstitutions: [],
            arguments: [Data("hello".utf8)]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(InvocationEnvelope.self, from: data)

        #expect(decoded.callID == envelope.callID)
        #expect(decoded.actorID == envelope.actorID)
        #expect(decoded.targetIdentifier == envelope.targetIdentifier)
        #expect(decoded.arguments.count == 1)
    }

    @Test func responseEnvelopeSuccess() throws {
        let response = ResponseEnvelope.success(
            callID: UUID(),
            result: Data("result".utf8)
        )

        #expect(response.isSuccess)
        #expect(response.errorMessage == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(ResponseEnvelope.self, from: data)

        #expect(decoded.isSuccess)
        #expect(decoded.result == response.result)
    }

    @Test func responseEnvelopeFailure() throws {
        let response = ResponseEnvelope.failure(
            callID: UUID(),
            error: "Something went wrong"
        )

        #expect(!response.isSuccess)
        #expect(response.errorMessage == "Something went wrong")
    }
}

// MARK: - Actor System Tests

@Suite("TrebuchetActorSystem")
struct ActorSystemTests {
    @Test func assignsUniqueIDs() {
        let system = TrebuchetActorSystem()

        let id1 = system.assignID(TestActor.self)
        let id2 = system.assignID(TestActor.self)

        #expect(id1 != id2)
    }
}

// MARK: - Test Helpers

distributed actor TestActor {
    typealias ActorSystem = TrebuchetActorSystem

    distributed func greet(name: String) -> String {
        "Hello, \(name)!"
    }
}
