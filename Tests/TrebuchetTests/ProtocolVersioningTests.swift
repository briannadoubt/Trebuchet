import Testing
import Foundation
@testable import Trebuchet

@Suite("Protocol Versioning Tests")
struct ProtocolVersioningTests {
    // MARK: - InvocationEnvelope Tests

    @Test("InvocationEnvelope includes protocol version")
    func envelopeIncludesVersion() throws {
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test", host: "localhost", port: 8080),
            targetIdentifier: "testMethod",
            protocolVersion: 2,
            genericSubstitutions: [],
            arguments: []
        )

        #expect(envelope.protocolVersion == 2)
    }

    @Test("InvocationEnvelope defaults to current version")
    func envelopeDefaultsToCurrentVersion() throws {
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test", host: "localhost", port: 8080),
            targetIdentifier: "testMethod",
            genericSubstitutions: [],
            arguments: []
        )

        #expect(envelope.protocolVersion == TrebuchetProtocolVersion.current)
    }

    @Test("InvocationEnvelope decodes v1 messages as version 1")
    func envelopeBackwardCompatibleDecoding() throws {
        // Simulate a v1 envelope (without protocolVersion field)
        let v1JSON = """
        {
            "callID": "00000000-0000-0000-0000-000000000001",
            "actorID": {
                "id": "test",
                "host": "localhost",
                "port": 8080
            },
            "targetIdentifier": "testMethod",
            "genericSubstitutions": [],
            "arguments": []
        }
        """

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(InvocationEnvelope.self, from: v1JSON.data(using: .utf8)!)

        #expect(envelope.protocolVersion == TrebuchetProtocolVersion.v1)
        #expect(envelope.targetIdentifier == "testMethod")
    }

    @Test("InvocationEnvelope encodes version for v2 clients")
    func envelopeEncodesVersion() throws {
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test", host: "localhost", port: 8080),
            targetIdentifier: "testMethod",
            protocolVersion: 2,
            genericSubstitutions: [],
            arguments: []
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("protocolVersion"))
        #expect(json.contains("2"))
    }

    // MARK: - Protocol Negotiation Tests

    @Test("ProtocolNegotiator: compatible versions negotiate successfully")
    func negotiatorCompatibleVersions() {
        let negotiator = ProtocolNegotiator(minVersion: 1, maxVersion: 2)

        // Client v1 connects to server v1-2
        let result1 = negotiator.negotiate(with: 1)
        #expect(result1 != nil)
        #expect(result1?.version == 1)
        #expect(result1?.isClientOutdated == false)

        // Client v2 connects to server v1-2
        let result2 = negotiator.negotiate(with: 2)
        #expect(result2 != nil)
        #expect(result2?.version == 2)
        #expect(result2?.isClientOutdated == false)
    }

    @Test("ProtocolNegotiator: newer client uses server's max version")
    func negotiatorNewerClient() {
        let negotiator = ProtocolNegotiator(minVersion: 1, maxVersion: 2)

        // Client v3 connects to server v1-2
        let result = negotiator.negotiate(with: 3)
        #expect(result != nil)
        #expect(result?.version == 2)
        #expect(result?.isServerOutdated == true)
        #expect(result?.isClientOutdated == false)
    }

    @Test("ProtocolNegotiator: older client uses client's version")
    func negotiatorOlderClient() {
        let negotiator = ProtocolNegotiator(minVersion: 2, maxVersion: 3)

        // Client v2 connects to server v2-3
        let result = negotiator.negotiate(with: 2)
        #expect(result != nil)
        #expect(result?.version == 2)
        #expect(result?.isClientOutdated == true)
    }

    @Test("ProtocolNegotiator: incompatible versions fail")
    func negotiatorIncompatibleVersions() {
        let negotiator = ProtocolNegotiator(minVersion: 2, maxVersion: 3)

        // Client v1 is too old for server v2-3
        let result = negotiator.negotiate(with: 1)
        #expect(result == nil)
    }

    @Test("ProtocolNegotiator: supports version check")
    func negotiatorSupportsVersion() {
        let negotiator = ProtocolNegotiator(minVersion: 1, maxVersion: 3)

        #expect(negotiator.supports(version: 1))
        #expect(negotiator.supports(version: 2))
        #expect(negotiator.supports(version: 3))
        #expect(!negotiator.supports(version: 0))
        #expect(!negotiator.supports(version: 4))
    }

    // MARK: - Method Registry Tests

    @Test("MethodRegistry: registers and resolves methods")
    func methodRegistryBasicUsage() async {
        let registry = MethodRegistry()

        let signature = MethodSignature(
            name: "getUser",
            parameterTypes: ["String"],
            returnType: "User",
            version: 1,
            targetIdentifier: "getUser_v1"
        )

        await registry.register(signature)

        let resolved = await registry.resolve(
            identifier: "getUser_v1",
            protocolVersion: 1
        )

        #expect(resolved != nil)
        #expect(resolved?.name == "getUser")
        #expect(resolved?.version == 1)
    }

    @Test("MethodRegistry: resolves newest compatible version")
    func methodRegistryVersionResolution() async {
        let registry = MethodRegistry()

        let v1 = MethodSignature(
            name: "getUser",
            parameterTypes: ["String"],
            returnType: "User",
            version: 1,
            targetIdentifier: "getUser_v1"
        )

        let v2 = MethodSignature(
            name: "getUser",
            parameterTypes: ["String", "Bool"],
            returnType: "DetailedUser",
            version: 2,
            targetIdentifier: "getUser_v1"
        )

        await registry.register([v1, v2])

        // Client v1 gets v1 method
        let resolved1 = await registry.resolve(
            identifier: "getUser_v1",
            protocolVersion: 1
        )
        #expect(resolved1?.version == 1)
        #expect(resolved1?.parameterTypes.count == 1)

        // Client v2 gets v2 method
        let resolved2 = await registry.resolve(
            identifier: "getUser_v1",
            protocolVersion: 2
        )
        #expect(resolved2?.version == 2)
        #expect(resolved2?.parameterTypes.count == 2)

        // Client v3 gets v2 (newest compatible)
        let resolved3 = await registry.resolve(
            identifier: "getUser_v1",
            protocolVersion: 3
        )
        #expect(resolved3?.version == 2)
    }

    @Test("MethodRegistry: handles method redirects")
    func methodRegistryRedirects() async {
        let registry = MethodRegistry()

        let oldSignature = MethodSignature(
            name: "fetchUser",
            parameterTypes: ["String"],
            returnType: "User",
            version: 1,
            targetIdentifier: "fetchUser_v1"
        )

        let newSignature = MethodSignature(
            name: "getUser",
            parameterTypes: ["String"],
            returnType: "User",
            version: 2,
            targetIdentifier: "getUser_v2"
        )

        await registry.register([oldSignature, newSignature])
        await registry.registerRedirect(from: "fetchUser_v1", to: "getUser_v2")

        // Old identifier redirects to new one
        let resolved = await registry.resolve(
            identifier: "fetchUser_v1",
            protocolVersion: 2
        )

        #expect(resolved != nil)
        #expect(resolved?.name == "getUser")
        #expect(resolved?.targetIdentifier == "getUser_v2")
    }

    @Test("MethodRegistry: returns nil for unknown methods")
    func methodRegistryUnknownMethod() async {
        let registry = MethodRegistry()

        let resolved = await registry.resolve(
            identifier: "unknownMethod",
            protocolVersion: 1
        )

        #expect(resolved == nil)
    }

    @Test("MethodRegistry: clears all methods")
    func methodRegistryClear() async {
        let registry = MethodRegistry()

        let signature = MethodSignature(
            name: "test",
            parameterTypes: [],
            returnType: "Void",
            version: 1,
            targetIdentifier: "test"
        )

        await registry.register(signature)
        #expect(await registry.allSignatures().count == 1)

        await registry.clear()
        #expect(await registry.allSignatures().isEmpty)
    }

    // MARK: - Version Constants Tests

    @Test("Protocol version constants are defined correctly")
    func protocolVersionConstants() {
        #expect(TrebuchetProtocolVersion.v1 == 1)
        #expect(TrebuchetProtocolVersion.v2 == 2)
        #expect(TrebuchetProtocolVersion.current == 2)
        #expect(TrebuchetProtocolVersion.minimum == 1)
    }
}
