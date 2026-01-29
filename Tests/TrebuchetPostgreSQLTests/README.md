# PostgreSQL Integration Tests

This directory contains integration tests for the TrebuchetPostgreSQL module, including the PostgreSQL state store and LISTEN/NOTIFY stream adapter.

## Running the Tests

### Prerequisites

- Docker and Docker Compose installed
- PostgreSQL tests are automatically skipped if the database is not available

### Starting the Test Database

From the project root, start the PostgreSQL test container:

```bash
docker-compose -f docker-compose.test.yml up -d
```

This will:
- Start a PostgreSQL 16 Alpine container
- Create the `test_trebuchet` database
- Set up the `actor_states` table with proper schema
- Install the trigger function for LISTEN/NOTIFY notifications
- Expose PostgreSQL on `localhost:5432`

### Running the Tests

Once the database is running, execute the tests:

```bash
swift test --filter TrebuchetPostgreSQLTests
```

### Stopping the Test Database

When finished testing:

```bash
docker-compose -f docker-compose.test.yml down
```

To also remove the database volume:

```bash
docker-compose -f docker-compose.test.yml down -v
```

## Test Coverage

The integration tests cover:

- **State Store Operations**:
  - Save and load actor state
  - Sequence number auto-increment
  - Delete operations
  - Existence checks
  - Concurrent access handling

- **Stream Adapter** (LISTEN/NOTIFY):
  - Notification broadcasting
  - Real-time state change notifications
  - Multi-instance synchronization

## Database Configuration

The test database uses these credentials (defined in `docker-compose.test.yml`):

- **Host**: localhost
- **Port**: 5432
- **Database**: test_trebuchet
- **Username**: test
- **Password**: test

## Database Schema

The `setup.sql` file automatically creates:

```sql
-- Actor state table
CREATE TABLE actor_states (
    actor_id VARCHAR(255) PRIMARY KEY,
    state BYTEA NOT NULL,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Performance indices
CREATE INDEX idx_actor_states_updated ON actor_states(updated_at);
CREATE INDEX idx_actor_states_sequence ON actor_states(sequence_number);

-- Notification function and trigger
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

CREATE TRIGGER actor_state_change_trigger
AFTER INSERT OR UPDATE ON actor_states
FOR EACH ROW
EXECUTE FUNCTION notify_actor_state_change();
```

## CI/CD

These integration tests are designed to run locally with Docker Compose. In CI environments without Docker access, the tests will automatically skip with a message indicating PostgreSQL is not available.

## Troubleshooting

### Container won't start

Check if port 5432 is already in use:

```bash
lsof -i :5432
```

If another PostgreSQL instance is running, either stop it or modify the port in `docker-compose.test.yml`.

### Tests fail to connect

Verify the container is healthy:

```bash
docker-compose -f docker-compose.test.yml ps
```

Check the logs:

```bash
docker-compose -f docker-compose.test.yml logs
```

### Schema not initialized

The `setup.sql` script runs automatically when the container first starts. If you need to reinitialize:

```bash
docker-compose -f docker-compose.test.yml down -v
docker-compose -f docker-compose.test.yml up -d
```
