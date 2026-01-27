// SerializationCompatibilityTests.swift
// Tests for wire format backward compatibility

import Testing
import Foundation
@testable import Trebuchet

@Suite("Serialization Compatibility Tests")
struct SerializationCompatibilityTests {

    // MARK: - InvocationEnvelope Backward Compatibility

    @Test("Decode InvocationEnvelope without traceContext (old format)")
    func testDecodeOldFormatWithoutTraceContext() throws {
        // Simulate old client that doesn't include traceContext
        let oldFormat = """
        {
            "callID": "123e4567-e89b-12d3-a456-426614174000",
            "actorID": {
                "id": "test-actor",
                "host": "localhost",
                "port": 8080
            },
            "targetIdentifier": "testMethod",
            "genericSubstitutions": [],
            "arguments": []
        }
        """

        let data = oldFormat.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(envelope.callID.uuidString.uppercased() == "123E4567-E89B-12D3-A456-426614174000")
        #expect(envelope.actorID.id == "test-actor")
        #expect(envelope.targetIdentifier == "testMethod")
        #expect(envelope.traceContext == nil)  // Optional field should be nil
    }

    @Test("Decode InvocationEnvelope with traceContext (new format)")
    func testDecodeNewFormatWithTraceContext() throws {
        let newFormat = """
        {
            "callID": "123e4567-e89b-12d3-a456-426614174000",
            "actorID": {
                "id": "test-actor",
                "host": "localhost",
                "port": 8080
            },
            "targetIdentifier": "testMethod",
            "genericSubstitutions": [],
            "arguments": [],
            "traceContext": {
                "traceID": "abc12345-e89b-12d3-a456-426614174000",
                "spanID": "def67890-e89b-12d3-a456-426614174000"
            }
        }
        """

        let data = newFormat.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(envelope.traceContext != nil)
        #expect(envelope.traceContext?.traceID.uuidString.uppercased() == "ABC12345-E89B-12D3-A456-426614174000")
        #expect(envelope.traceContext?.spanID.uuidString.uppercased() == "DEF67890-E89B-12D3-A456-426614174000")
    }

    @Test("Encode InvocationEnvelope without traceContext omits field")
    func testEncodeWithoutTraceContext() throws {
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: [],
            traceContext: nil
        )

        let data = try JSONEncoder().encode(envelope)
        let json = String(data: data, encoding: .utf8)!

        // When nil, traceContext should not appear in JSON
        #expect(!json.contains("traceContext"))
    }

    @Test("Encode InvocationEnvelope with traceContext includes field")
    func testEncodeWithTraceContext() throws {
        let traceContext = TraceContext()

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: [],
            traceContext: traceContext
        )

        let data = try JSONEncoder().encode(envelope)
        let json = String(data: data, encoding: .utf8)!

        // When present, traceContext should appear in JSON
        #expect(json.contains("traceContext"))
        #expect(json.contains(traceContext.traceID.uuidString))
    }

    @Test("Round-trip InvocationEnvelope preserves traceContext")
    func testRoundTripPreservesTraceContext() throws {
        let originalTraceContext = TraceContext(
            traceID: UUID(),
            spanID: UUID()
        )

        let original = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: [],
            traceContext: originalTraceContext
        )

        // Encode and decode
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(decoded.traceContext != nil)
        #expect(decoded.traceContext?.traceID == originalTraceContext.traceID)
        #expect(decoded.traceContext?.spanID == originalTraceContext.spanID)
    }

    @Test("InvocationEnvelope with streamFilter and traceContext")
    func testWithBothOptionalFields() throws {
        let traceContext = TraceContext()
        let streamFilter = StreamFilter.predefined("changed", parameters: ["threshold": "10"])

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: [],
            streamFilter: streamFilter,
            traceContext: traceContext
        )

        // Encode and decode
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(decoded.streamFilter != nil)
        #expect(decoded.streamFilter?.name == "changed")
        #expect(decoded.traceContext != nil)
        #expect(decoded.traceContext?.traceID == traceContext.traceID)
    }

    // MARK: - ResponseEnvelope Compatibility

    @Test("ResponseEnvelope remains unchanged")
    func testResponseEnvelopeUnchanged() throws {
        // ResponseEnvelope should not have changed in Phase 1
        let response = ResponseEnvelope.success(
            callID: UUID(),
            result: Data("test".utf8)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)

        #expect(decoded.isSuccess)
        #expect(decoded.result != nil)
        #expect(decoded.errorMessage == nil)
    }

    // MARK: - Version Compatibility Matrix

    @Test("Old client to new server compatibility")
    func testOldClientToNewServer() throws {
        // Scenario: Client without Phase 1 changes sends to server with Phase 1
        // The client doesn't know about traceContext, so it omits it

        let clientMessage = """
        {
            "callID": "123e4567-e89b-12d3-a456-426614174000",
            "actorID": {"id": "actor-1", "host": "localhost", "port": 8080},
            "targetIdentifier": "oldMethod",
            "genericSubstitutions": [],
            "arguments": []
        }
        """

        let data = clientMessage.data(using: .utf8)!

        // Server (with Phase 1) should decode successfully
        let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(envelope.actorID.id == "actor-1")
        #expect(envelope.traceContext == nil)  // Server handles nil gracefully
    }

    @Test("New client to old server compatibility")
    func testNewClientToOldServer() throws {
        // Scenario: Client with Phase 1 sends to server without Phase 1
        // New client includes traceContext, old server ignores unknown fields

        let traceContext = TraceContext()

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "actor-1"),
            targetIdentifier: "newMethod",
            genericSubstitutions: [],
            arguments: [],
            traceContext: traceContext
        )

        let data = try JSONEncoder().encode(envelope)

        // Simulate old server by decoding into a struct without traceContext
        struct OldInvocationEnvelope: Codable {
            let callID: UUID
            let actorID: TrebuchetActorID
            let targetIdentifier: String
            let genericSubstitutions: [String]
            let arguments: [Data]
            // No traceContext field
        }

        // Old server should decode successfully, ignoring extra field
        let oldDecoded = try JSONDecoder().decode(OldInvocationEnvelope.self, from: data)

        #expect(oldDecoded.actorID.id == "actor-1")
        #expect(oldDecoded.targetIdentifier == "newMethod")
    }
}
