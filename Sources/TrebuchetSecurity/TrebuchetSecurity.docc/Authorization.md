# Authorization

Control access to actors and methods with role-based access control (RBAC).

## Overview

After authentication establishes **who** a user is, authorization determines **what** they can do. TrebuchetSecurity provides flexible role-based access control (RBAC) for distributed actors.

Key features:
- **Role-based policies**: Grant access based on user roles
- **Wildcard patterns**: Match actor types and methods with `*`
- **Predefined rules**: Common patterns like admin-only, read-only access
- **Extensible**: Implement custom authorization policies

## Basic RBAC

Role-Based Access Control (RBAC) maps roles to permissions.

### Quick Example

```swift
import TrebuchetSecurity

// Define access rules
let policy = RoleBasedPolicy(rules: [
    // Admins can do anything
    .init(role: "admin", actorType: "*", method: "*"),

    // Users can only read
    .init(role: "user", actorType: "*", method: "get*"),

    // Workers can invoke GameRoom
    .init(role: "worker", actorType: "GameRoom", method: "*")
])

// Check authorization
let action = Action(actorType: "GameRoom", method: "join")
let resource = Resource(type: "game", id: "room-123")

let allowed = try await policy.authorize(
    principal,
    action: action,
    resource: resource
)

if allowed {
    // Process request
} else {
    throw AuthorizationError.accessDenied
}
```

## Authorization Components

### Action

Represents what is being done:

```swift
public struct Action {
    public let actorType: String  // e.g., "GameRoom"
    public let method: String     // e.g., "join"
}

let action = Action(actorType: "GameRoom", method: "join")
```

### Resource

Represents what is being accessed:

```swift
public struct Resource {
    public let type: String                    // e.g., "game"
    public let id: String?                     // e.g., "room-123"
    public let attributes: [String: String]    // Custom attributes
}

let resource = Resource(
    type: "game",
    id: "room-123",
    attributes: ["region": "us-east-1"]
)
```

### Principal

The authenticated user (from authentication):

```swift
let principal = Principal(
    id: "user-456",
    type: .user,
    roles: ["user", "premium"]
)
```

## Access Rules

Rules define role-to-permission mappings.

### Rule Structure

```swift
public struct Rule {
    public let role: String          // Required role
    public let actorType: String     // Actor type pattern (* for all)
    public let method: String        // Method pattern (* for all)
    public let resourceType: String? // Resource type pattern (optional)
}
```

### Simple Rules

```swift
// Admin has full access to everything
.init(role: "admin", actorType: "*", method: "*")

// User can access all actors but only read methods
.init(role: "user", actorType: "*", method: "get*")

// Worker can invoke any method on GameRoom
.init(role: "worker", actorType: "GameRoom", method: "*")
```

### Pattern Matching

Rules support wildcard patterns:

```swift
// Prefix matching: methods starting with "get"
.init(role: "user", actorType: "*", method: "get*")

// Suffix matching: methods ending with "Status"
.init(role: "monitor", actorType: "*", method: "*Status")

// Exact match: specific actor and method
.init(role: "admin", actorType: "AdminPanel", method: "reset")

// Wildcard: all actors and methods
.init(role: "admin", actorType: "*", method: "*")
```

### Resource Type Filtering

```swift
// Limit access to specific resource types
.init(
    role: "moderator",
    actorType: "ChatRoom",
    method: "*",
    resourceType: "public-chat"  // Only public chat rooms
)
```

## Predefined Rules

Common patterns are available as static properties:

```swift
// Admin has full access
.adminFullAccess
// Equivalent to:
// .init(role: "admin", actorType: "*", method: "*")

// User can only read
.userReadOnly
// Equivalent to:
// .init(role: "user", actorType: "*", method: "get*")

// Service can invoke any method
.serviceInvoke
// Equivalent to:
// .init(role: "service", actorType: "*", method: "*")
```

### Using Predefined Rules

```swift
let policy = RoleBasedPolicy(rules: [
    .adminFullAccess,
    .userReadOnly,
    .serviceInvoke
])
```

## Predefined Policies

Complete policies for common scenarios:

```swift
// Admin-only access
let adminOnly = RoleBasedPolicy.adminOnly

// Admins get full access, users get read-only
let adminUserRead = RoleBasedPolicy.adminUserRead
```

## Policy Configuration

### Deny by Default

By default, requests are denied if no rule matches:

```swift
let policy = RoleBasedPolicy(
    rules: [...],
    denyByDefault: true  // Default
)
```

### Allow by Default

Allow requests that don't match any rule (rarely recommended):

```swift
let policy = RoleBasedPolicy(
    rules: [...],
    denyByDefault: false  // Allow if no rule matches
)
```

## Complete Example

### Multi-Role Game Server

```swift
import TrebuchetSecurity

// Define comprehensive access policy
let gamePolicy = RoleBasedPolicy(rules: [
    // Admins can do everything
    .init(role: "admin", actorType: "*", method: "*"),

    // Players can join and leave games
    .init(role: "player", actorType: "GameRoom", method: "join"),
    .init(role: "player", actorType: "GameRoom", method: "leave"),
    .init(role: "player", actorType: "GameRoom", method: "getState"),

    // Premium players can create private rooms
    .init(role: "premium", actorType: "GameRoom", method: "create"),

    // Moderators can kick players
    .init(role: "moderator", actorType: "GameRoom", method: "kick"),
    .init(role: "moderator", actorType: "GameRoom", method: "ban"),

    // All authenticated users can view lobbies
    .init(role: "user", actorType: "Lobby", method: "get*"),

    // Services can perform health checks
    .init(role: "service", actorType: "*", method: "health")
])

// Use in authorization middleware
let authzMiddleware = AuthorizationMiddleware(policy: gamePolicy)
```

### Dynamic Authorization

Check authorization at runtime:

```swift
// User with premium role
let premium = Principal(
    id: "user-123",
    type: .user,
    roles: ["player", "premium"]
)

// Try to create a private room
let createAction = Action(actorType: "GameRoom", method: "create")
let roomResource = Resource(type: "game")

let canCreate = try await gamePolicy.authorize(
    premium,
    action: createAction,
    resource: roomResource
)

print(canCreate) // true (has premium role)

// Regular user (no premium)
let regular = Principal(
    id: "user-456",
    type: .user,
    roles: ["player"]
)

let canCreate2 = try await gamePolicy.authorize(
    regular,
    action: createAction,
    resource: roomResource
)

print(canCreate2) // false (no premium role)
```

## Custom Authorization Policies

Implement ``AuthorizationPolicy`` for advanced logic:

```swift
import TrebuchetSecurity

/// Time-based access policy
actor TimeBasedPolicy: AuthorizationPolicy {
    let allowedHours: ClosedRange<Int>

    init(allowedHours: ClosedRange<Int>) {
        self.allowedHours = allowedHours
    }

    func authorize(
        _ principal: Principal,
        action: Action,
        resource: Resource
    ) async throws -> Bool {
        // Get current hour
        let hour = Calendar.current.component(.hour, from: Date())

        // Check if within allowed hours
        guard allowedHours.contains(hour) else {
            return false
        }

        // Additional role-based checks
        return principal.hasRole("admin") || principal.hasRole("user")
    }
}

// Use time-based policy
let businessHours = TimeBasedPolicy(allowedHours: 9...17)
```

### Attribute-Based Access Control (ABAC)

```swift
actor AttributePolicy: AuthorizationPolicy {
    func authorize(
        _ principal: Principal,
        action: Action,
        resource: Resource
    ) async throws -> Bool {
        // Resource owner can always access
        if resource.id == principal.id {
            return true
        }

        // Same organization can read
        if action.method.hasPrefix("get"),
           let principalOrg = principal.attributes["organization"],
           let resourceOrg = resource.attributes["organization"],
           principalOrg == resourceOrg {
            return true
        }

        // Admins can do anything
        return principal.hasRole("admin")
    }
}
```

### Composite Policies

Combine multiple policies:

```swift
actor CompositePolicy: AuthorizationPolicy {
    let policies: [AuthorizationPolicy]
    let requireAll: Bool

    init(policies: [AuthorizationPolicy], requireAll: Bool = false) {
        self.policies = policies
        self.requireAll = requireAll
    }

    func authorize(
        _ principal: Principal,
        action: Action,
        resource: Resource
    ) async throws -> Bool {
        if requireAll {
            // AND: All policies must allow
            for policy in policies {
                guard try await policy.authorize(principal, action: action, resource: resource) else {
                    return false
                }
            }
            return true
        } else {
            // OR: At least one policy must allow
            for policy in policies {
                if try await policy.authorize(principal, action: action, resource: resource) {
                    return true
                }
            }
            return false
        }
    }
}

// Combine time-based and role-based policies
let composite = CompositePolicy(policies: [
    TimeBasedPolicy(allowedHours: 9...17),
    RoleBasedPolicy.adminOnly
], requireAll: false)
```

## Integration with CloudGateway

Use authorization middleware to protect actors:

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Create authorization policy
let policy = RoleBasedPolicy(rules: [
    .adminFullAccess,
    .userReadOnly
])

// Create middleware
let authzMiddleware = AuthorizationMiddleware(policy: policy)

// Configure gateway
let gateway = CloudGateway(configuration: .init(
    middleware: [
        authMiddleware,   // Authenticate first
        authzMiddleware   // Then authorize
    ],
    stateStore: stateStore,
    registry: registry
))
```

The middleware automatically:
1. Extracts the `Principal` from the authentication context
2. Creates `Action` from the invocation (actor type + method)
3. Creates `Resource` from the actor identity
4. Checks policy and denies unauthorized requests

## Error Handling

```swift
do {
    let allowed = try await policy.authorize(principal, action: action, resource: resource)

    if !allowed {
        throw AuthorizationError.accessDenied
    }

    // Process request
} catch AuthorizationError.accessDenied {
    return .forbidden("Access denied")
} catch AuthorizationError.evaluationFailed(let reason) {
    return .internalServerError("Policy error: \(reason)")
}
```

## Best Practices

### Principle of Least Privilege

Grant minimum necessary permissions:

```swift
// ❌ Too broad
.init(role: "user", actorType: "*", method: "*")

// ✅ Specific and minimal
.init(role: "user", actorType: "GameRoom", method: "join")
.init(role: "user", actorType: "GameRoom", method: "leave")
.init(role: "user", actorType: "Lobby", method: "get*")
```

### Explicit Deny

Use `denyByDefault: true` (the default) to ensure accidental access is prevented:

```swift
let policy = RoleBasedPolicy(
    rules: [...],
    denyByDefault: true  // Deny anything not explicitly allowed
)
```

### Audit Access

Log authorization decisions for security monitoring:

```swift
let allowed = try await policy.authorize(principal, action: action, resource: resource)

logger.info("Authorization", metadata: [
    "principal": principal.id,
    "action": "\(action.actorType).\(action.method)",
    "resource": resource.id ?? "N/A",
    "allowed": "\(allowed)"
])
```

### Test Policies

Verify rules work as expected:

```swift
func testAdminAccess() async throws {
    let admin = Principal(id: "admin-1", type: .user, roles: ["admin"])
    let action = Action(actorType: "GameRoom", method: "delete")

    let allowed = try await policy.authorize(admin, action: action, resource: resource)
    XCTAssertTrue(allowed)
}

func testUserDenied() async throws {
    let user = Principal(id: "user-1", type: .user, roles: ["user"])
    let action = Action(actorType: "GameRoom", method: "delete")

    let allowed = try await policy.authorize(user, action: action, resource: resource)
    XCTAssertFalse(allowed)
}
```

## See Also

- <doc:Authentication> - Verify identities with JWT and API keys
- <doc:RateLimiting> - Prevent abuse
- <doc:RequestValidation> - Validate request payloads
