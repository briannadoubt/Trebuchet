# Protocol Versioning

Support multiple protocol versions simultaneously for backward-compatible deployments.

## Overview

Protocol versioning allows servers to handle requests from clients running different versions of your code. This enables gradual rollouts where old and new clients coexist without breaking changes.

## The Problem

Without protocol versioning:

```swift
// Server v1
distributed func getUser(id: String) -> User

// Deploy server v2 with breaking change
distributed func getUser(id: String, includePrivate: Bool) -> DetailedUser

// ❌ All v1 clients break immediately!
```

## The Solution: Protocol Negotiation

Each request includes a protocol version. Servers support multiple versions simultaneously:

```swift
@Trebuchet
distributed actor UserService {
    // Keep old method for v1 clients
    @available(*, deprecated, renamed: "getUserV2")
    distributed func getUser(id: String) -> User {
        // Call new method with defaults
        return try await getUserV2(id: id, includePrivate: false)
    }

    // New method for v2+ clients
    distributed func getUserV2(id: String, includePrivate: Bool) -> DetailedUser {
        // New implementation
    }
}
```

## Protocol Versions

### Current Versions

- **v1**: Initial protocol (2025)
- **v2**: Adds protocol versioning and backward compatibility (2026)

```swift
TrebuchetProtocolVersion.v1      // 1
TrebuchetProtocolVersion.v2      // 2
TrebuchetProtocolVersion.current // 2
TrebuchetProtocolVersion.minimum // 1
```

### InvocationEnvelope

Every RPC call includes a `protocolVersion` field:

```swift
let envelope = InvocationEnvelope(
    callID: UUID(),
    actorID: actorID,
    targetIdentifier: "getUser",
    protocolVersion: 2,
    genericSubstitutions: [],
    arguments: [...]
)
```

Clients automatically set this to their build version. Servers negotiate the highest mutually supported version.

## Protocol Negotiation

### Server Setup

Configure supported versions:

```swift
let actorSystem = TrebuchetActorSystem()

// Support v1 and v2
let negotiator = ProtocolNegotiator(
    minVersion: 1,
    maxVersion: 2
)
```

### Negotiation Flow

1. Client sends request with `protocolVersion: 2`
2. Server checks: `min(clientVersion, serverMax) >= serverMin`
3. If compatible, use negotiated version
4. If incompatible, reject with error

```swift
let result = negotiator.negotiate(with: clientVersion)

if let protocol = result {
    print("Using protocol v\(protocol.version)")
    if protocol.isClientOutdated {
        print("Warning: Client should upgrade")
    }
} else {
    // Incompatible - reject request
}
```

## Method Versioning

### Approach 1: Separate Methods (Recommended)

Keep old and new methods side by side:

```swift
// v1 method (deprecated but functional)
@available(*, deprecated, renamed: "getUserV2")
distributed func getUser(id: String) -> User {
    return try await getUserV2(id: id, includePrivate: false)
}

// v2 method
distributed func getUserV2(id: String, includePrivate: Bool) -> DetailedUser {
    // New implementation
}
```

### Approach 2: Default Parameters

Add parameters with defaults:

```swift
// Works for both v1 and v2 clients
distributed func getUser(
    id: String,
    includePrivate: Bool = false  // New parameter with default
) -> User {
    // Implementation
}
```

### Approach 3: Method Registry

For complex scenarios, use the method registry:

```swift
let registry = MethodRegistry()

// Register v1 signature
await registry.register(MethodSignature(
    name: "getUser",
    parameterTypes: ["String"],
    returnType: "User",
    version: 1,
    targetIdentifier: "getUser_v1"
))

// Register v2 signature
await registry.register(MethodSignature(
    name: "getUser",
    parameterTypes: ["String", "Bool"],
    returnType: "DetailedUser",
    version: 2,
    targetIdentifier: "getUser_v2"
))

// Resolve at runtime
let signature = await registry.resolve(
    identifier: "getUser",
    protocolVersion: clientVersion
)
```

## Gradual Rollout Strategy

### Week 1: Deploy v1.1 with Both Methods

```swift
@Trebuchet
distributed actor UserService {
    distributed func getUser(id: String) -> User {
        // Old behavior
    }

    distributed func getUserV2(id: String, includePrivate: Bool) -> DetailedUser {
        // New behavior
    }
}
```

Deploy to production. Both old and new clients work.

### Week 2-4: Monitor and Migrate

- Monitor v1 method usage: decreasing
- Monitor v2 method usage: increasing
- Send deprecation warnings to v1 clients

### Week 5+: Remove Old Method

Once v1 usage drops to near-zero:

```swift
@Trebuchet
distributed actor UserService {
    distributed func getUser(id: String, includePrivate: Bool) -> DetailedUser {
        // Rename v2 → v1, remove old implementation
    }
}
```

## Backward Compatibility

### Reading Old Messages

v2 servers can read v1 client messages:

```swift
// InvocationEnvelope decodes missing protocolVersion as v1
public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    // Default to v1 if not present
    protocolVersion = try container.decodeIfPresent(
        UInt32.self,
        forKey: .protocolVersion
    ) ?? TrebuchetProtocolVersion.v1

    // ... decode other fields
}
```

### Writing Compatible Messages

v2 servers writing to v1 clients:

```swift
// Check negotiated protocol version
if negotiatedVersion == 1 {
    // Use v1 response format
    return User(id: id, name: name)
} else {
    // Use v2 response format
    return DetailedUser(id: id, name: name, privateData: data)
}
```

## Deprecation Workflow

### Step 1: Mark as Deprecated

```swift
@available(*, deprecated, renamed: "getUserV2")
distributed func getUser(id: String) -> User {
    return try await getUserV2(id: id, includePrivate: false)
}
```

Compiler warnings guide developers to migrate.

### Step 2: Add Removal Date

```swift
@available(*, deprecated, message: "Use getUserV2 instead. Will be removed after 2026-06-01.")
distributed func getUser(id: String) -> User {
    return try await getUserV2(id: id, includePrivate: false)
}
```

### Step 3: Runtime Warnings (Optional)

```swift
distributed func getUser(id: String) -> User {
    logger.warning("getUser() is deprecated, use getUserV2()")
    return try await getUserV2(id: id, includePrivate: false)
}
```

### Step 4: Remove

After grace period, remove the old method entirely.

## Migration Examples

### Example 1: Adding a Parameter

```swift
// Before (v1)
distributed func createUser(name: String) -> User

// After (v1.1 - both methods)
distributed func createUser(name: String) -> User {
    return try await createUser(name: name, email: nil)
}

distributed func createUser(name: String, email: String?) -> User {
    // Implementation
}

// After (v2.0 - old method removed)
distributed func createUser(name: String, email: String?) -> User {
    // Implementation
}
```

### Example 2: Changing Return Type

```swift
// Before (v1)
distributed func getStats() -> Stats

// After (v1.1 - adapter layer)
distributed func getStats() -> Stats {
    return try await getDetailedStats().toLegacyFormat()
}

distributed func getDetailedStats() -> DetailedStats {
    // New implementation
}
```

### Example 3: Renaming Methods

```swift
let registry = MethodRegistry()

// Register redirect
await registry.registerRedirect(
    from: "fetchUser",  // Old name
    to: "getUser"       // New name
)

// Old clients calling "fetchUser" → routed to "getUser"
```

## Testing

### Test Version Negotiation

```swift
func testNegotiation() async {
    let negotiator = ProtocolNegotiator(minVersion: 1, maxVersion: 2)

    // v1 client → v1
    let result1 = negotiator.negotiate(with: 1)
    XCTAssertEqual(result1?.version, 1)

    // v3 client → v2 (server max)
    let result3 = negotiator.negotiate(with: 3)
    XCTAssertEqual(result3?.version, 2)
    XCTAssertTrue(result3?.isServerOutdated == true)
}
```

### Test Backward Compatibility

```swift
func testV1ClientWithV2Server() async throws {
    let server = TrebuchetServer(transport: .webSocket(port: 8080))
    let actor = UserService(actorSystem: server.actorSystem)
    await server.expose(actor, as: "users")

    // Simulate v1 client request (no protocolVersion field)
    let v1Envelope = """
    {
        "callID": "...",
        "actorID": {...},
        "targetIdentifier": "getUser",
        "arguments": [...]
    }
    """

    let response = try await server.handleRequest(v1Envelope)

    // Should succeed with v1-compatible response
    XCTAssertNotNil(response)
}
```

## Best Practices

### 1. Use Semantic Versioning

- **Major**: Breaking changes (v1 → v2)
- **Minor**: New features, backward compatible (v1.1 → v1.2)
- **Patch**: Bug fixes (v1.1.1 → v1.1.2)

### 2. Maintain Compatibility for 6+ Months

Give clients time to upgrade before removing old methods.

### 3. Monitor Method Usage

Track which protocol versions are in use:

```swift
logger.info("Method called", metadata: [
    "method": "getUser",
    "protocolVersion": String(envelope.protocolVersion)
])
```

### 4. Test with Old Clients

Keep old client versions for testing:

```bash
# Test v2 server with v1 client
./test-scripts/run-v1-client.sh --server localhost:8080
```

### 5. Document Breaking Changes

```markdown
# Changelog

## v2.0.0 (2026-03-01)

### Breaking Changes
- `getUser(id:)` now requires `includePrivate` parameter
- `Stats` replaced with `DetailedStats`

### Migration Guide
- Update calls to `getUser(id: "123")` → `getUser(id: "123", includePrivate: false)`
- Handle new fields in `DetailedStats`
```

## See Also

- ``TrebuchetProtocolVersion``
- ``ProtocolNegotiator``
- ``MethodRegistry``
- ``InvocationEnvelope``
