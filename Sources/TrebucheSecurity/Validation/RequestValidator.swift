// RequestValidator.swift
// Request validation for security and resource limits

import Foundation

/// Request validation errors
public enum ValidationError: Error, Sendable {
    /// Payload exceeds maximum size
    case payloadTooLarge(size: Int, maximum: Int)

    /// Actor ID exceeds maximum length
    case actorIDTooLong(length: Int, maximum: Int)

    /// Method name exceeds maximum length
    case methodNameTooLong(length: Int, maximum: Int)

    /// Malformed request
    case malformed(reason: String)

    /// Invalid characters in field
    case invalidCharacters(field: String)

    /// Custom validation error
    case custom(message: String)
}

extension ValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .payloadTooLarge(let size, let maximum):
            return "Payload size \(size) bytes exceeds maximum \(maximum) bytes"
        case .actorIDTooLong(let length, let maximum):
            return "Actor ID length \(length) exceeds maximum \(maximum)"
        case .methodNameTooLong(let length, let maximum):
            return "Method name length \(length) exceeds maximum \(maximum)"
        case .malformed(let reason):
            return "Malformed request: \(reason)"
        case .invalidCharacters(let field):
            return "Invalid characters in \(field)"
        case .custom(let message):
            return message
        }
    }
}

/// Request validator configuration
public struct ValidationConfiguration: Sendable {
    /// Maximum payload size in bytes (default: 1MB)
    public var maxPayloadSize: Int

    /// Maximum actor ID length (default: 256)
    public var maxActorIDLength: Int

    /// Maximum method name length (default: 128)
    public var maxMethodNameLength: Int

    /// Maximum metadata value length (default: 1024)
    public var maxMetadataValueLength: Int

    /// Allow null bytes in strings
    public var allowNullBytes: Bool

    /// Validate UTF-8 encoding
    public var validateUTF8: Bool

    /// Creates a validation configuration
    public init(
        maxPayloadSize: Int = 1_048_576, // 1MB
        maxActorIDLength: Int = 256,
        maxMethodNameLength: Int = 128,
        maxMetadataValueLength: Int = 1024,
        allowNullBytes: Bool = false,
        validateUTF8: Bool = true
    ) {
        self.maxPayloadSize = maxPayloadSize
        self.maxActorIDLength = maxActorIDLength
        self.maxMethodNameLength = maxMethodNameLength
        self.maxMetadataValueLength = maxMetadataValueLength
        self.allowNullBytes = allowNullBytes
        self.validateUTF8 = validateUTF8
    }

    /// Permissive configuration (larger limits)
    public static let permissive = ValidationConfiguration(
        maxPayloadSize: 10_485_760, // 10MB
        maxActorIDLength: 512,
        maxMethodNameLength: 256
    )

    /// Strict configuration (smaller limits)
    public static let strict = ValidationConfiguration(
        maxPayloadSize: 65_536, // 64KB
        maxActorIDLength: 128,
        maxMethodNameLength: 64
    )

    /// Default configuration (balanced)
    public static let `default` = ValidationConfiguration()
}

/// Request validator
public struct RequestValidator: Sendable {
    /// Configuration
    public let configuration: ValidationConfiguration

    /// Creates a request validator
    /// - Parameter configuration: Validation configuration
    public init(configuration: ValidationConfiguration = .default) {
        self.configuration = configuration
    }

    /// Validate payload size
    /// - Parameter data: Payload data
    /// - Throws: ValidationError if payload is too large
    public func validatePayloadSize(_ data: Data) throws {
        guard data.count <= configuration.maxPayloadSize else {
            throw ValidationError.payloadTooLarge(
                size: data.count,
                maximum: configuration.maxPayloadSize
            )
        }
    }

    /// Validate actor ID
    /// - Parameter actorID: Actor identifier
    /// - Throws: ValidationError if invalid
    public func validateActorID(_ actorID: String) throws {
        guard actorID.count <= configuration.maxActorIDLength else {
            throw ValidationError.actorIDTooLong(
                length: actorID.count,
                maximum: configuration.maxActorIDLength
            )
        }

        try validateString(actorID, field: "actorID")
    }

    /// Validate method name
    /// - Parameter methodName: Method name
    /// - Throws: ValidationError if invalid
    public func validateMethodName(_ methodName: String) throws {
        guard methodName.count <= configuration.maxMethodNameLength else {
            throw ValidationError.methodNameTooLong(
                length: methodName.count,
                maximum: configuration.maxMethodNameLength
            )
        }

        // Method names should be alphanumeric + underscore
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard methodName.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw ValidationError.invalidCharacters(field: "methodName")
        }

        try validateString(methodName, field: "methodName")
    }

    /// Validate metadata value
    /// - Parameters:
    ///   - key: Metadata key
    ///   - value: Metadata value
    /// - Throws: ValidationError if invalid
    public func validateMetadata(key: String, value: String) throws {
        try validateString(key, field: "metadata.key")
        try validateString(value, field: "metadata.value")

        guard value.count <= configuration.maxMetadataValueLength else {
            throw ValidationError.custom(
                message: "Metadata value for '\(key)' exceeds maximum length"
            )
        }
    }

    /// Validate a string for null bytes and UTF-8 encoding
    /// - Parameters:
    ///   - string: String to validate
    ///   - field: Field name for error messages
    /// - Throws: ValidationError if invalid
    private func validateString(_ string: String, field: String) throws {
        // Check for null bytes
        if !configuration.allowNullBytes && string.contains("\0") {
            throw ValidationError.invalidCharacters(field: "\(field) (contains null bytes)")
        }

        // Validate UTF-8 encoding
        if configuration.validateUTF8 {
            guard string.utf8.allSatisfy({ _ in true }) else {
                throw ValidationError.malformed(reason: "\(field) contains invalid UTF-8")
            }
        }
    }

    /// Validate envelope structure
    /// - Parameters:
    ///   - actorID: Actor ID
    ///   - methodName: Method name
    ///   - arguments: Serialized arguments
    /// - Throws: ValidationError if invalid
    public func validateEnvelope(
        actorID: String,
        methodName: String,
        arguments: [Data]
    ) throws {
        // Validate fields
        try validateActorID(actorID)
        try validateMethodName(methodName)

        // Validate total payload size
        let totalSize = arguments.reduce(0) { $0 + $1.count }
        try validatePayloadSize(Data(count: totalSize))

        // Validate each argument
        for (index, arg) in arguments.enumerated() {
            guard arg.count <= configuration.maxPayloadSize else {
                throw ValidationError.malformed(
                    reason: "Argument \(index) exceeds maximum size"
                )
            }
        }
    }
}
