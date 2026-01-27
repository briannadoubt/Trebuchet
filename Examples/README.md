# Local Distributed Examples

## Quick Start: Run Distributed Actors Locally

### 1. Simple Two-Node Setup

Run two separate terminals:

**Terminal 1 - Server Node:**
```bash
swift run TrebucheDemo server --port 9000
```

**Terminal 2 - Client Node:**
```bash
swift run TrebucheDemo client --host localhost --port 9000
```

### 2. Multi-Node with LocalProvider

See the integration tests for working examples:
```bash
swift test --filter "Client-Server Integration"
```

These tests spin up:
- Server on random port
- Client connecting to it
- Remote actor calls
- All locally, no AWS

### 3. With PostgreSQL State (Most Realistic)

**Start PostgreSQL:**
```bash
docker run --name trebuche-postgres \
  -e POSTGRES_PASSWORD=trebuche \
  -e POSTGRES_USER=trebuche \
  -e POSTGRES_DB=trebuche \
  -p 5432:5432 \
  -d postgres:16-alpine
```

**Run multiple instances sharing state:**
```bash
# Terminal 1
PORT=9000 POSTGRES_HOST=localhost swift run TrebucheDemo

# Terminal 2  
PORT=9001 POSTGRES_HOST=localhost swift run TrebucheDemo

# Both share state via PostgreSQL!
```

### 4. Docker Compose (Full Simulation)

```bash
docker-compose up
```

This runs:
- 3 actor instances
- PostgreSQL for shared state
- Simulates multi-machine deployment locally

## What's Testable Locally?

✅ **Everything except AWS-specific features:**

- Multi-node actor calls (WebSocket)
- State persistence (PostgreSQL)
- State streaming (PostgreSQL LISTEN/NOTIFY)
- Rate limiting (in-memory)
- Authentication (API keys, JWT parsing)
- Authorization (RBAC policies)
- Metrics (in-memory collector)
- Tracing (console exporter)
- Logging (console/JSON formatters)
- All middleware

❌ **AWS-Only (for production):**

- CloudWatch metrics
- X-Ray tracing
- API Gateway WebSocket
- DynamoDB state/streams
- Lambda deployment

## Key Insight

**Your actors are cloud-agnostic!** Develop locally with:
- `LocalProvider` - runs actors on different ports
- `PostgreSQLStateStore` - shared state
- `InMemoryCollector` - metrics

Deploy to production by swapping to:
- `AWSProvider` - runs actors in Lambda
- `DynamoDBStateStore` - AWS state
- `CloudWatchReporter` - AWS metrics

**The actor code doesn't change!**
