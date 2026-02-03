# Configuration

Configure SurrealDB connections for development and production environments.

## Overview

``SurrealDBConfiguration`` provides flexible configuration options for connecting to SurrealDB, with support for environment variables, custom authentication, and connection pooling.

## Configuration Methods

### Development Configuration

Use the default development settings:

```swift
let config = SurrealDBConfiguration.development()
```

This provides:
- URL: `ws://localhost:8000/rpc`
- Namespace: `development`
- Database: `development`
- Root authentication (root/root)
- 30-second timeout
- Auto-reconnect enabled

### Environment Variables

Load configuration from environment variables:

```swift
let config = try SurrealDBConfiguration.fromEnvironment()
```

Supported environment variables:
- `SURREALDB_URL` - WebSocket or HTTP endpoint (required)
- `SURREALDB_NAMESPACE` - Namespace name (required)
- `SURREALDB_DATABASE` - Database name (required)
- `SURREALDB_USERNAME` - Authentication username (required)
- `SURREALDB_PASSWORD` - Authentication password (required)
- `SURREALDB_TIMEOUT` - Connection timeout in seconds (optional, default: 30)

### Custom Configuration

Create a custom configuration:

```swift
let config = SurrealDBConfiguration(
    url: "ws://surrealdb.example.com:8000/rpc",
    namespace: "production",
    database: "myapp",
    auth: .database(
        namespace: "production",
        database: "myapp",
        username: "app_user",
        password: "secure_password"
    ),
    timeout: 60,
    reconnectOnFailure: true,
    maxReconnectAttempts: 5
)
```

## Authentication Types

SurrealDB supports four authentication types via ``SurrealDBAuth``:

### Root Authentication

Full server access (use only in development):

```swift
.root(username: "root", password: "root")
```

### Namespace Authentication

Namespace-level access:

```swift
.namespace(
    namespace: "production",
    username: "ns_admin",
    password: "ns_password"
)
```

### Database Authentication

Database-level access (recommended for production):

```swift
.database(
    namespace: "production",
    database: "myapp",
    username: "app_user",
    password: "app_password"
)
```

### Record Access

Row-level security with custom access methods:

```swift
.recordAccess(
    namespace: "production",
    database: "myapp",
    access: "user_access",
    parameters: ["user_id": "12345"]
)
```

## CloudGateway Integration

Use the CloudGateway extensions for seamless integration:

### From Environment

```swift
let gateway = try await CloudGateway.withSurrealDBFromEnvironment()
try await gateway.expose(MyActor(actorSystem: gateway.system, db: gateway.db))
```

### With Configuration

```swift
let config = SurrealDBConfiguration(...)
let gateway = try await CloudGateway.withSurrealDB(configuration: config)
```

### Direct Parameters

```swift
let gateway = try await CloudGateway.withSurrealDB(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp"
)
```

## Connection Pooling

For high-throughput scenarios, use ``SurrealDBConnectionPool``:

```swift
let pool = SurrealDBConnectionPool(
    configuration: config,
    maxConnections: 10
)

let users = try await pool.withConnection { db in
    try await db.query(User.self)
}

// Clean up when done
await pool.shutdown()
```

## Validation

Configuration is automatically validated:

```swift
do {
    try config.validate()
} catch ConfigurationError.invalidURL {
    print("Invalid SurrealDB URL")
} catch ConfigurationError.invalidNamespace {
    print("Namespace cannot be empty")
}
```

## Creating SurrealDB Clients

Create clients from configuration:

```swift
// Create a new client
let db = try await config.createClient()

// Or use the shared client pattern
let db = try await config.createSharedClient()
```

## Best Practices

1. **Use environment variables** in production for security
2. **Use database-level authentication** for production apps
3. **Enable reconnection** for resilient connections
4. **Use connection pooling** for high-throughput scenarios
5. **Validate configuration** before deployment

## See Also

- ``SurrealDBConfiguration``
- ``SurrealDBAuth``
- ``SurrealDBConnectionPool``
- ``CloudGateway``
