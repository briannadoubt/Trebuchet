# Request Validation

Protect your distributed actors from malformed requests and resource exhaustion.

## Overview

Request validation provides defense against:

- **Oversized payloads**: Prevent memory exhaustion attacks
- **Malformed envelopes**: Reject invalid requests early
- **Invalid characters**: Detect injection attempts
- **Resource limits**: Enforce reasonable constraints

The ``RequestValidator`` checks requests before they're processed, providing a security layer that complements authentication and authorization.

## Basic Usage

```swift
import TrebuchetSecurity

let validator = RequestValidator()

// Validate individual fields
try validator.validateActorID("game-room-123")
try validator.validateMethodName("join")
try validator.validatePayloadSize(data)

// Validate complete envelope
try validator.validateEnvelope(
    actorID: "game-room-1",
    methodName: "join",
    arguments: [playerData, teamData]
)
```

## Validation Rules

### Payload Size Limits

Prevent memory exhaustion by limiting payload sizes:

```swift
let validator = RequestValidator(
    configuration: .init(maxPayloadSize: 1_048_576) // 1MB
)

// Validate data
let data = Data(count: 2_000_000) // 2MB
do {
    try validator.validatePayloadSize(data)
} catch ValidationError.payloadTooLarge(let size, let maximum) {
    print("Payload \(size) bytes exceeds \(maximum) bytes")
}
```

### Actor ID Validation

Actor IDs must be reasonable length and contain valid characters:

```swift
// Valid actor IDs
try validator.validateActorID("game-room-123")
try validator.validateActorID("user-abc-def")
try validator.validateActorID("lobby")

// Invalid: too long
let longID = String(repeating: "a", count: 500)
try validator.validateActorID(longID)  // Throws actorIDTooLong

// Invalid: null bytes
try validator.validateActorID("game\0room")  // Throws invalidCharacters
```

### Method Name Validation

Method names must be alphanumeric with underscores only:

```swift
// Valid method names
try validator.validateMethodName("join")
try validator.validateMethodName("getPlayers")
try validator.validateMethodName("get_room_state")
try validator.validateMethodName("method123")

// Invalid: special characters
try validator.validateMethodName("join-room")   // Throws invalidCharacters
try validator.validateMethodName("get.players") // Throws invalidCharacters
try validator.validateMethodName("kick!")       // Throws invalidCharacters
try validator.validateMethodName("join room")   // Throws invalidCharacters
```

### Metadata Validation

Metadata keys and values have length limits:

```swift
try validator.validateMetadata(key: "userId", value: "123")
try validator.validateMetadata(key: "region", value: "us-east-1")

// Invalid: value too long
let longValue = String(repeating: "a", count: 2000)
try validator.validateMetadata(key: "data", value: longValue)  // Throws
```

### Envelope Validation

Validate complete envelopes before processing:

```swift
// Validates actor ID, method name, and total payload size
try validator.validateEnvelope(
    actorID: "game-room-1",
    methodName: "join",
    arguments: [
        Data("player1".utf8),
        Data("team-red".utf8)
    ]
)
```

The envelope validator checks:
- Actor ID length and characters
- Method name format
- Total argument size
- Individual argument sizes

## Configuration

### Preset Configurations

```swift
// Default: balanced limits (1MB payload, 256 char actor ID)
let validator = RequestValidator(configuration: .default)

// Permissive: larger limits for trusted environments
let validator = RequestValidator(configuration: .permissive)

// Strict: smaller limits for public APIs
let validator = RequestValidator(configuration: .strict)
```

### Custom Configuration

```swift
let config = ValidationConfiguration(
    maxPayloadSize: 2_097_152,      // 2MB
    maxActorIDLength: 512,           // 512 characters
    maxMethodNameLength: 256,        // 256 characters
    maxMetadataValueLength: 2048,    // 2KB
    allowNullBytes: false,           // Reject null bytes
    validateUTF8: true              // Ensure valid UTF-8
)

let validator = RequestValidator(configuration: config)
```

## Validation Errors

All validation errors are ``ValidationError`` with descriptive messages:

```swift
do {
    try validator.validatePayloadSize(data)
} catch let error as ValidationError {
    switch error {
    case .payloadTooLarge(let size, let maximum):
        response.status = .payloadTooLarge
        response.body = "Payload \(size) bytes exceeds limit of \(maximum) bytes"

    case .actorIDTooLong(let length, let maximum):
        response.status = .badRequest
        response.body = "Actor ID length \(length) exceeds \(maximum)"

    case .methodNameTooLong(let length, let maximum):
        response.status = .badRequest
        response.body = "Method name length \(length) exceeds \(maximum)"

    case .malformed(let reason):
        response.status = .badRequest
        response.body = "Malformed request: \(reason)"

    case .invalidCharacters(let field):
        response.status = .badRequest
        response.body = "Invalid characters in \(field)"

    case .custom(let message):
        response.status = .badRequest
        response.body = message
    }
}
```

## Security Considerations

### Null Byte Injection

By default, null bytes are rejected to prevent null byte injection attacks:

```swift
// Rejected by default
try validator.validateActorID("actor\0id")

// Allow if needed (not recommended)
let config = ValidationConfiguration(allowNullBytes: true)
let validator = RequestValidator(configuration: config)
```

### UTF-8 Validation

Ensures all strings are valid UTF-8 to prevent encoding attacks:

```swift
// Valid UTF-8 (including Unicode)
try validator.validateActorID("hello-世界")  // ✓

// Invalid UTF-8 would be rejected
```

### Method Name Restrictions

Only alphanumeric characters and underscores prevent:
- Path traversal attempts
- Command injection
- Special character exploits

```swift
// Blocked patterns
try validator.validateMethodName("../../../etc/passwd")  // ✗
try validator.validateMethodName("rm -rf /")             // ✗
try validator.validateMethodName("method; DROP TABLE")   // ✗
```

## Integration with CloudGateway

Validation will be integrated into CloudGateway in Phase 1.5:

```swift
let gateway = CloudGateway(configuration: .init(
    security: .init(
        validation: .strict  // Use strict validation for public APIs
    )
))

// Gateway automatically validates all incoming requests
```

## Best Practices

### 1. Validate Early

Validate requests as early as possible:

```swift
func handleRequest(_ envelope: InvocationEnvelope) async throws {
    // Validate FIRST, before any processing
    try validator.validateEnvelope(
        actorID: envelope.actorID.id,
        methodName: envelope.targetIdentifier,
        arguments: envelope.arguments
    )

    // Then authenticate, authorize, etc.
    let principal = try await authenticate(envelope)
    try await authorize(principal, envelope)

    // Finally process
    return try await process(envelope)
}
```

### 2. Choose Appropriate Limits

Set limits based on your use case:

```swift
// Internal microservices: permissive
let internalValidator = RequestValidator(configuration: .permissive)

// Public API: strict
let publicValidator = RequestValidator(configuration: .strict)

// File upload endpoint: custom large payload
let uploadValidator = RequestValidator(configuration: .init(
    maxPayloadSize: 10_485_760  // 10MB
))
```

### 3. Provide Clear Errors

Include limits in error messages so clients know constraints:

```swift
catch ValidationError.payloadTooLarge(let size, let maximum) {
    throw APIError.badRequest(
        "Payload size \(size) bytes exceeds maximum \(maximum) bytes"
    )
}
```

### 4. Log Validation Failures

Track validation failures for security monitoring:

```swift
catch let error as ValidationError {
    await logger.warning("Validation failed", metadata: [
        "error": error.description,
        "actorID": envelope.actorID.id,
        "clientIP": request.remoteAddress
    ])
    throw error
}
```

### 5. Test with Malformed Input

Test your validators with intentionally bad input:

```swift
@Test("Validator rejects oversized payload")
func testOversizedPayload() throws {
    let validator = RequestValidator(configuration: .init(
        maxPayloadSize: 1024
    ))

    let hugePayload = Data(count: 1_000_000)
    #expect(throws: ValidationError.self) {
        try validator.validatePayloadSize(hugePayload)
    }
}
```

## Performance

Validation is designed to be fast:

- **Payload size**: O(1) - just checks `data.count`
- **Actor ID**: O(n) - scans for null bytes
- **Method name**: O(n) - validates character set
- **Envelope**: O(n) - sum of field validations

For typical requests (<100KB), validation overhead is negligible (<1ms).

## Topics

### Validator

- ``RequestValidator``
- ``ValidationConfiguration``

### Errors

- ``ValidationError``

### Configuration Presets

- ``ValidationConfiguration/default``
- ``ValidationConfiguration/permissive``
- ``ValidationConfiguration/strict``
