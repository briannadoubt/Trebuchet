// ValidationTests.swift
// Tests for request validation

import Testing
import Foundation
@testable import TrebucheSecurity

@Suite("Request Validation Tests")
struct ValidationTests {

    // MARK: - Payload Size Tests

    @Test("RequestValidator allows valid payload size")
    func testValidPayloadSize() throws {
        let validator = RequestValidator()

        // 1KB payload should be fine (default max is 1MB)
        let data = Data(count: 1024)
        try validator.validatePayloadSize(data)
    }

    @Test("RequestValidator rejects oversized payload")
    func testOversizedPayload() throws {
        let validator = RequestValidator(
            configuration: .init(maxPayloadSize: 1024)
        )

        // 2KB payload should be rejected
        let data = Data(count: 2048)

        do {
            try validator.validatePayloadSize(data)
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch let error as ValidationError {
            if case .payloadTooLarge(let size, let maximum) = error {
                #expect(size == 2048)
                #expect(maximum == 1024)
            } else {
                #expect(Bool(false), "Expected payloadTooLarge error")
            }
        }
    }

    // MARK: - Actor ID Tests

    @Test("RequestValidator allows valid actor ID")
    func testValidActorID() throws {
        let validator = RequestValidator()

        try validator.validateActorID("game-room-123")
        try validator.validateActorID("user-abc-def")
        try validator.validateActorID("a")
    }

    @Test("RequestValidator rejects long actor ID")
    func testLongActorID() throws {
        let validator = RequestValidator(
            configuration: .init(maxActorIDLength: 10)
        )

        let longID = String(repeating: "a", count: 20)

        do {
            try validator.validateActorID(longID)
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch let error as ValidationError {
            if case .actorIDTooLong(let length, let maximum) = error {
                #expect(length == 20)
                #expect(maximum == 10)
            } else {
                #expect(Bool(false), "Expected actorIDTooLong error")
            }
        }
    }

    @Test("RequestValidator rejects actor ID with null bytes")
    func testActorIDWithNullBytes() throws {
        let validator = RequestValidator()

        let idWithNull = "game\0room"

        do {
            try validator.validateActorID(idWithNull)
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    // MARK: - Method Name Tests

    @Test("RequestValidator allows valid method name")
    func testValidMethodName() throws {
        let validator = RequestValidator()

        try validator.validateMethodName("join")
        try validator.validateMethodName("getPlayers")
        try validator.validateMethodName("get_room_state")
        try validator.validateMethodName("method123")
    }

    @Test("RequestValidator rejects long method name")
    func testLongMethodName() throws {
        let validator = RequestValidator(
            configuration: .init(maxMethodNameLength: 10)
        )

        let longMethod = String(repeating: "a", count: 20)

        do {
            try validator.validateMethodName(longMethod)
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch let error as ValidationError {
            if case .methodNameTooLong(let length, let maximum) = error {
                #expect(length == 20)
                #expect(maximum == 10)
            } else {
                #expect(Bool(false), "Expected methodNameTooLong error")
            }
        }
    }

    @Test("RequestValidator rejects method name with special characters")
    func testMethodNameWithSpecialCharacters() throws {
        let validator = RequestValidator()

        let invalidMethods = [
            "join-room",  // hyphen
            "get.players", // dot
            "kick!",       // exclamation
            "join room",   // space
            "get@room"     // at symbol
        ]

        for method in invalidMethods {
            do {
                try validator.validateMethodName(method)
                #expect(Bool(false), "Should have rejected '\(method)'")
            } catch is ValidationError {
                // Expected
            }
        }
    }

    // MARK: - Metadata Tests

    @Test("RequestValidator allows valid metadata")
    func testValidMetadata() throws {
        let validator = RequestValidator()

        try validator.validateMetadata(key: "userId", value: "123")
        try validator.validateMetadata(key: "region", value: "us-east-1")
    }

    @Test("RequestValidator rejects long metadata value")
    func testLongMetadataValue() throws {
        let validator = RequestValidator(
            configuration: .init(maxMetadataValueLength: 10)
        )

        let longValue = String(repeating: "a", count: 20)

        do {
            try validator.validateMetadata(key: "test", value: longValue)
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    // MARK: - Envelope Validation Tests

    @Test("RequestValidator allows valid envelope")
    func testValidEnvelope() throws {
        let validator = RequestValidator()

        try validator.validateEnvelope(
            actorID: "game-room-1",
            methodName: "join",
            arguments: [
                Data("player1".utf8),
                Data("team-red".utf8)
            ]
        )
    }

    @Test("RequestValidator rejects envelope with invalid actor ID")
    func testEnvelopeWithInvalidActorID() throws {
        let validator = RequestValidator(
            configuration: .init(maxActorIDLength: 5)
        )

        do {
            try validator.validateEnvelope(
                actorID: "very-long-actor-id",
                methodName: "join",
                arguments: []
            )
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    @Test("RequestValidator rejects envelope with invalid method")
    func testEnvelopeWithInvalidMethod() throws {
        let validator = RequestValidator()

        do {
            try validator.validateEnvelope(
                actorID: "game-1",
                methodName: "invalid-method!",
                arguments: []
            )
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    @Test("RequestValidator rejects envelope with oversized arguments")
    func testEnvelopeWithOversizedArguments() throws {
        let validator = RequestValidator(
            configuration: .init(maxPayloadSize: 100)
        )

        let largeArg = Data(count: 200)

        do {
            try validator.validateEnvelope(
                actorID: "game-1",
                methodName: "join",
                arguments: [largeArg]
            )
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    @Test("RequestValidator rejects envelope with total size exceeded")
    func testEnvelopeWithTotalSizeExceeded() throws {
        let validator = RequestValidator(
            configuration: .init(maxPayloadSize: 100)
        )

        // Each argument is small, but total exceeds limit
        let args = [
            Data(count: 40),
            Data(count: 40),
            Data(count: 40)
        ]

        do {
            try validator.validateEnvelope(
                actorID: "game-1",
                methodName: "join",
                arguments: args
            )
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    // MARK: - Configuration Tests

    @Test("ValidationConfiguration presets")
    func testValidationConfigurationPresets() {
        // Default
        let defaultConfig = ValidationConfiguration.default
        #expect(defaultConfig.maxPayloadSize == 1_048_576) // 1MB
        #expect(defaultConfig.maxActorIDLength == 256)
        #expect(defaultConfig.maxMethodNameLength == 128)

        // Permissive
        let permissive = ValidationConfiguration.permissive
        #expect(permissive.maxPayloadSize == 10_485_760) // 10MB
        #expect(permissive.maxActorIDLength == 512)
        #expect(permissive.maxMethodNameLength == 256)

        // Strict
        let strict = ValidationConfiguration.strict
        #expect(strict.maxPayloadSize == 65_536) // 64KB
        #expect(strict.maxActorIDLength == 128)
        #expect(strict.maxMethodNameLength == 64)
    }

    // MARK: - Error Description Tests

    @Test("ValidationError descriptions")
    func testValidationErrorDescriptions() {
        let error1 = ValidationError.payloadTooLarge(size: 2000, maximum: 1000)
        #expect(error1.description.contains("2000"))
        #expect(error1.description.contains("1000"))

        let error2 = ValidationError.actorIDTooLong(length: 300, maximum: 256)
        #expect(error2.description.contains("300"))
        #expect(error2.description.contains("256"))

        let error3 = ValidationError.malformed(reason: "test reason")
        #expect(error3.description.contains("test reason"))

        let error4 = ValidationError.invalidCharacters(field: "methodName")
        #expect(error4.description.contains("methodName"))
    }

    // MARK: - Allow Null Bytes Configuration

    @Test("RequestValidator with null bytes allowed")
    func testAllowNullBytes() throws {
        let validator = RequestValidator(
            configuration: .init(allowNullBytes: true)
        )

        // Should be allowed when configured
        try validator.validateActorID("actor\0id")
    }

    // MARK: - UTF-8 Validation

    @Test("RequestValidator validates UTF-8")
    func testUTF8Validation() throws {
        let validator = RequestValidator(
            configuration: .init(validateUTF8: true)
        )

        // Valid UTF-8 should be fine
        try validator.validateActorID("hello-世界")
        try validator.validateMethodName("method_123")
    }

    @Test("RequestValidator with UTF-8 validation disabled")
    func testUTF8ValidationDisabled() throws {
        let validator = RequestValidator(
            configuration: .init(validateUTF8: false)
        )

        // Should allow any string
        try validator.validateActorID("any-string")
    }
}
