# PostgreSQL State Storage

Configure PostgreSQL for reliable actor state persistence and multi-instance synchronization.

## Overview

The TrebuchetPostgreSQL module provides production-ready PostgreSQL integration for:

- **State Persistence**: Store actor state with ACID guarantees
- **Sequence Tracking**: Automatic optimistic locking support
- **Multi-Instance Sync**: Real-time state synchronization via LISTEN/NOTIFY
- **Connection Pooling**: Efficient connection management with NIO

## Why PostgreSQL?

- ✅ **ACID Transactions**: Reliable state persistence
- ✅ **Optimistic Locking**: Sequence-based conflict resolution
- ✅ **LISTEN/NOTIFY**: Built-in pub/sub for state changes
- ✅ **Mature Ecosystem**: Battle-tested with extensive tooling
- ✅ **Cost Effective**: Free and open source

Compare to other state stores:

| Feature | PostgreSQL | DynamoDB | Redis |
|---------|-----------|----------|-------|
| **Transactions** | ✅ ACID | ❌ Limited | ❌ None |
| **Cost** | Free | Pay per request | Pay per hour |
| **Pub/Sub** | ✅ LISTEN/NOTIFY | ❌ Streams only | ✅ Pub/Sub |
| **Consistency** | ✅ Strong | ⚠️ Eventual | ⚠️ Eventual |

## Database Setup

### 1. Install PostgreSQL

#### macOS

```bash
# Using Homebrew
brew install postgresql@16
brew services start postgresql@16

# Or using Postgres.app
# Download from: https://postgresapp.com
```

#### Linux (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install postgresql-16
sudo systemctl start postgresql
```

#### Docker

```bash
docker run -d \
  --name trebuchet-postgres \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=trebuchet \
  -p 5432:5432 \
  postgres:16-alpine
```

### 2. Create Database

```bash
# Connect to PostgreSQL
psql -U postgres

# Create database
CREATE DATABASE trebuchet;

# Connect to the database
\c trebuchet
```

### 3. Create Schema

```sql
-- Create actor_states table
CREATE TABLE actor_states (
    actor_id VARCHAR(255) PRIMARY KEY,
    state BYTEA NOT NULL,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX idx_actor_states_updated ON actor_states(updated_at);
CREATE INDEX idx_actor_states_sequence ON actor_states(sequence_number);

-- Create notification function for LISTEN/NOTIFY
CREATE OR REPLACE FUNCTION notify_actor_state_change()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('actor_state_changes',
        json_build_object(
            'actorID', NEW.actor_id,
            'sequenceNumber', NEW.sequence_number,
            'timestamp', EXTRACT(EPOCH FROM NEW.updated_at)
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to send notifications on state changes
CREATE TRIGGER actor_state_change_trigger
AFTER INSERT OR UPDATE ON actor_states
FOR EACH ROW
EXECUTE FUNCTION notify_actor_state_change();
```

### 4. Verify Setup

```sql
-- Check table exists
SELECT * FROM actor_states LIMIT 1;

-- Test trigger
INSERT INTO actor_states (actor_id, state, sequence_number)
VALUES ('test-actor', '\x00', 0);

-- Check notification (in separate connection, run: LISTEN actor_state_changes)
-- You should see: Asynchronous notification "actor_state_changes" received
```

## Swift Integration

### Basic Configuration

```swift
import TrebuchetPostgreSQL

// Initialize state store
let stateStore = try await PostgreSQLStateStore(
    host: "localhost",
    port: 5432,
    database: "trebuchet",
    username: "postgres",
    password: "password"
)

// Save actor state
try await stateStore.save(myState, for: "actor-123")

// Load actor state
let state = try await stateStore.load(for: "actor-123", as: MyState.self)

// Delete actor state
try await stateStore.delete(for: "actor-123")
```

### With Environment Variables

```swift
import Foundation
import TrebuchetPostgreSQL

// Read from environment
let stateStore = try await PostgreSQLStateStore(
    host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
    port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432")!,
    database: ProcessInfo.processInfo.environment["POSTGRES_DATABASE"] ?? "trebuchet",
    username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "postgres",
    password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"]
)
```

### Connection String (Recommended)

```swift
// Using connection string
let connectionString = "postgresql://user:password@localhost:5432/trebuchet"
let stateStore = try await PostgreSQLStateStore(connectionString: connectionString)
```

## Stateful Actors

Use PostgreSQL with stateful distributed actors:

```swift
import Trebuchet
import TrebuchetCloud
import TrebuchetPostgreSQL

@Trebuchet
distributed actor GameRoom: StatefulStreamingActor {
    typealias PersistentState = GameState

    @StreamedState var state = GameState()
    let stateStore: ActorStateStore

    var persistentState: GameState {
        get { state }
        set { state = newValue }
    }

    init(actorSystem: TrebuchetActorSystem, stateStore: ActorStateStore) async {
        self.actorSystem = actorSystem
        self.stateStore = stateStore

        // Load state from PostgreSQL
        if let saved = try? await stateStore.load(for: id.id, as: GameState.self) {
            self.state = saved
        }
    }

    distributed func updateScore(player: String, points: Int) async throws {
        // Transform and persist state atomically
        try await transformState(store: stateStore) { currentState in
            var newState = currentState
            newState.scores[player, default: 0] += points
            return newState
        }
        // State is now persisted to PostgreSQL AND streamed to clients!
    }
}
```

## Multi-Instance Synchronization

Use PostgreSQL LISTEN/NOTIFY to synchronize state across multiple actor instances:

```swift
import TrebuchetPostgreSQL

// Create stream adapter
let adapter = try await PostgreSQLStreamAdapter(
    host: "localhost",
    database: "trebuchet",
    username: "postgres",
    channel: "actor_state_changes"  // Default channel
)

// Start listening for state changes
let notificationStream = try await adapter.start()

// Process notifications
Task {
    for await change in notificationStream {
        print("Actor \(change.actorID) updated to sequence \(change.sequenceNumber)")

        // Reload actor state from PostgreSQL
        if let actor = actorCache[change.actorID] {
            try await actor.reloadState()
        }
    }
}
```

### How It Works

1. **Actor A** updates state → saves to PostgreSQL
2. PostgreSQL **trigger fires** → sends NOTIFY
3. **All instances** listening on channel receive notification
4. **Actor instances** reload state from PostgreSQL
5. **Clients** receive streaming updates from their local instance

```
┌─────────┐              ┌──────────────┐              ┌─────────┐
│Instance1│─────save────▶│ PostgreSQL   │◀────load─────│Instance2│
│ Actor A │              │              │              │ Actor A │
└─────────┘              │ LISTEN/NOTIFY│              └─────────┘
     │                   └──────┬───────┘                    ▲
     │                          │                            │
     └──────────notifies────────┴────────notifies────────────┘
```

## CloudGateway Integration

Use PostgreSQL state store with CloudGateway:

```swift
import TrebuchetCloud
import TrebuchetPostgreSQL

// Initialize PostgreSQL state store
let stateStore = try await PostgreSQLStateStore(
    connectionString: "postgresql://localhost/trebuchet"
)

// Initialize stream adapter for multi-instance sync
let streamAdapter = try await PostgreSQLStreamAdapter(
    connectionString: "postgresql://localhost/trebuchet"
)

// Configure gateway
let gateway = CloudGateway(configuration: .init(
    stateStore: stateStore,
    registry: registry
))

// Start processing state change notifications
Task {
    let notifications = try await streamAdapter.start()
    for await change in notifications {
        // Reload affected actors
        await gateway.reloadActor(id: change.actorID)
    }
}
```

## Production Configuration

### Connection Pooling

```swift
import NIOPosix

// Create shared event loop group
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 4)

// Share across multiple state stores
let stateStore = try await PostgreSQLStateStore(
    host: "localhost",
    database: "trebuchet",
    username: "postgres",
    password: "password",
    eventLoopGroup: eventLoopGroup  // Shared pool
)
```

### Custom Table Name

```swift
let stateStore = try await PostgreSQLStateStore(
    host: "localhost",
    database: "trebuchet",
    username: "postgres",
    password: "password",
    tableName: "my_custom_actor_states"  // Custom table
)
```

### TLS/SSL Connection

```swift
import PostgresNIO

// Configure TLS
let configuration = PostgresConnection.Configuration(
    host: "production.postgres.example.com",
    port: 5432,
    username: "app",
    password: "secure-password",
    database: "trebuchet",
    tls: .require(try .init(configuration: .clientDefault))
)

let stateStore = try await PostgreSQLStateStore(configuration: configuration)
```

## Deployment Configurations

### Local Development

```yaml
# trebuchet.yaml
state:
  type: postgresql
  host: localhost
  port: 5432
  database: trebuchet_dev
  username: postgres
  password: password
```

### Docker Compose

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: trebuchet
      POSTGRES_USER: trebuchet
      POSTGRES_PASSWORD: secure-password
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./schema.sql:/docker-entrypoint-initdb.d/schema.sql

  app:
    image: my-trebuchet-app
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DATABASE: trebuchet
      POSTGRES_USER: trebuchet
      POSTGRES_PASSWORD: secure-password
    depends_on:
      - postgres

volumes:
  postgres-data:
```

### AWS RDS

```yaml
# trebuchet.yaml
state:
  type: postgresql
  host: trebuchet.abc123.us-east-1.rds.amazonaws.com
  port: 5432
  database: trebuchet
  username: admin
  # Password from AWS Secrets Manager
```

### Fly.io PostgreSQL

```yaml
# trebuchet.yaml
name: my-game-server
version: "1"

state:
  type: postgresql
  # Fly.io auto-injects DATABASE_URL
  connectionString: ${DATABASE_URL}

actors:
  GameRoom:
    stateful: true
    memory: 512
```

Deploy with PostgreSQL:

```bash
# Create Fly.io PostgreSQL database
fly postgres create trebuchet-db --region ord

# Attach to your app
fly postgres attach trebuchet-db --app my-game-server

# Deploy (DATABASE_URL is automatically set)
trebuchet deploy --provider fly
```

## Monitoring

### Check Table Size

```sql
SELECT
    pg_size_pretty(pg_total_relation_size('actor_states')) AS total_size,
    COUNT(*) AS actor_count
FROM actor_states;
```

### Active Listeners

```sql
SELECT
    pid,
    usename,
    application_name,
    state,
    query
FROM pg_stat_activity
WHERE query LIKE '%LISTEN%';
```

### State Updates Per Second

```sql
SELECT
    COUNT(*) / EXTRACT(EPOCH FROM (NOW() - pg_postmaster_start_time())) AS updates_per_sec
FROM actor_states;
```

### Slow Queries

```sql
SELECT
    query,
    calls,
    mean_exec_time,
    max_exec_time
FROM pg_stat_statements
WHERE query LIKE '%actor_states%'
ORDER BY mean_exec_time DESC
LIMIT 10;
```

## Troubleshooting

### Connection Refused

```
Error: connection refused at localhost:5432
```

**Solutions:**
- Ensure PostgreSQL is running: `pg_isready`
- Check port: `netstat -an | grep 5432`
- Verify pg_hba.conf allows connections

### Authentication Failed

```
Error: password authentication failed for user "postgres"
```

**Solutions:**
- Verify username and password
- Check pg_hba.conf authentication method
- Try: `psql -U postgres -W`

### Notifications Not Received

```
Warning: LISTEN/NOTIFY not working
```

**Solutions:**
- Verify trigger exists: `\d actor_states`
- Check function exists: `\df notify_actor_state_change`
- Test manually: `INSERT INTO actor_states ...` (in one session) and `LISTEN actor_state_changes` (in another)

### High Connection Count

```
Error: too many clients already
```

**Solutions:**
- Use connection pooling with shared EventLoopGroup
- Increase `max_connections` in postgresql.conf
- Use PgBouncer for connection pooling

## Best Practices

### Use Connection Pooling

```swift
// ✅ Share EventLoopGroup across stores
let pool = MultiThreadedEventLoopGroup(numberOfThreads: 4)
let store1 = try await PostgreSQLStateStore(..., eventLoopGroup: pool)
let store2 = try await PostgreSQLStateStore(..., eventLoopGroup: pool)

// ❌ Create separate pools
let store1 = try await PostgreSQLStateStore(...)  // Creates its own pool
let store2 = try await PostgreSQLStateStore(...)  // Creates another pool
```

### Enable Connection Limits

```sql
-- Limit connections per database
ALTER DATABASE trebuchet CONNECTION LIMIT 100;

-- Limit connections per user
ALTER USER trebuchet CONNECTION LIMIT 50;
```

### Partition Large Tables

For >1M actors, partition by actor ID prefix:

```sql
CREATE TABLE actor_states (
    actor_id VARCHAR(255),
    state BYTEA NOT NULL,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
) PARTITION BY HASH (actor_id);

CREATE TABLE actor_states_p0 PARTITION OF actor_states
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);

CREATE TABLE actor_states_p1 PARTITION OF actor_states
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);

-- ... more partitions
```

### Regular Vacuuming

```sql
-- Enable autovacuum
ALTER TABLE actor_states SET (autovacuum_enabled = true);

-- Manual vacuum
VACUUM ANALYZE actor_states;
```

## See Also

- <doc:DeployingToAWS> - Deploy to AWS Lambda with RDS
- <doc:FlyDeployment> - Deploy to Fly.io with managed PostgreSQL
- <doc:AdvancedStreaming> - Multi-instance state synchronization
