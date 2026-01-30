# TrebuchetAWS Integration Tests

This directory contains comprehensive integration tests for TrebuchetAWS using LocalStack to simulate AWS services.

## Overview

The test suite validates AWS functionality with real API calls against LocalStack-simulated services:

- **DynamoDB** - Actor state persistence with optimistic locking
- **DynamoDB Streams** - Real-time state change notifications
- **Cloud Map** - Service discovery and registration
- **IAM** - Role and policy management
- **Lambda** - Function deployment (deployment API only)
- **API Gateway WebSocket** - Connection management simulation

## Test Structure

### Test Suites

1. **DynamoDBStateStoreIntegrationTests** (9 tests)
   - Save and load actor state
   - Sequence number auto-increment
   - Delete operations
   - Exists checks
   - Optimistic locking with version checks
   - Concurrent saves
   - Update with transform functions

2. **CloudMapRegistryIntegrationTests** (5 tests)
   - Register and resolve actors
   - Deregister operations
   - List actors with prefix filtering
   - Heartbeat updates

3. **DynamoDBStreamAdapterIntegrationTests** (3 tests)
   - Process INSERT/MODIFY stream events
   - Handle malformed records gracefully

4. **AWSIntegrationWorkflowTests** (3 workflows)
   - Full actor discovery workflow (Cloud Map + DynamoDB)
   - Optimistic locking conflict resolution
   - Multi-region actor coordination

### Test Helpers

**LocalStackTestHelpers.swift** provides:
- `isLocalStackAvailable()` - Availability check for graceful test skipping
- `createAWSClient()` - LocalStack-configured AWS client
- `createStateStore()` - DynamoDB state store factory
- `createRegistry()` - Cloud Map registry factory
- `createProvider()` - AWS provider factory
- `cleanupTable()` - Test cleanup utility
- `waitForTable()` - Table readiness check
- `uniqueActorID()` - Unique actor ID generator for test isolation

## Prerequisites

### Local Development

- Docker and Docker Compose
- Swift 6.0 or later
- LocalStack 3.0

### CI Environment

- GitHub Actions runner with Docker support
- Swift toolchain
- AWS CLI Local (`awscli-local[ver1]`)

## Running Tests Locally

### 1. Start LocalStack

```bash
# Start LocalStack with all AWS services
docker-compose -f docker-compose.localstack.yml up -d

# Verify LocalStack is healthy
curl http://localhost:4566/_localstack/health

# Expected output:
# {
#   "services": {
#     "dynamodb": "running",
#     "servicediscovery": "running",
#     "lambda": "running",
#     "iam": "running",
#     "apigatewayv2": "running"
#   }
# }
```

### 2. Initialize Resources

LocalStack init scripts run automatically on startup. To manually verify:

```bash
# Check DynamoDB tables
docker exec trebuchet-localstack awslocal dynamodb list-tables

# Expected tables:
# - trebuchet-test-state (with DynamoDB Streams)
# - trebuchet-test-connections (with ActorIndex GSI)

# Check Cloud Map namespaces
docker exec trebuchet-localstack awslocal servicediscovery list-namespaces

# Expected namespace: trebuchet-test

# Check IAM roles
docker exec trebuchet-localstack awslocal iam list-roles
```

### 3. Run Tests

```bash
# Run all AWS integration tests
swift test --filter TrebuchetAWSTests

# Run specific test suite
swift test --filter DynamoDBStateStoreIntegrationTests
swift test --filter CloudMapRegistryIntegrationTests
swift test --filter DynamoDBStreamAdapterIntegrationTests
swift test --filter AWSIntegrationWorkflowTests

# Run with verbose output
swift test --filter TrebuchetAWSTests --verbose
```

### 4. Cleanup

```bash
# Stop and remove LocalStack containers
docker-compose -f docker-compose.localstack.yml down -v
```

## Test Architecture

### Graceful Test Skipping

All integration tests use `.enabled(if: await LocalStackTestHelpers.isLocalStackAvailable())` to gracefully skip when LocalStack is unavailable:

```swift
@Suite("DynamoDB State Store Integration Tests",
       .enabled(if: await LocalStackTestHelpers.isLocalStackAvailable()))
struct DynamoDBStateStoreIntegrationTests {
    @Test("Save and load actor state")
    func testSaveAndLoad() async throws {
        // Test implementation
    }
}
```

### Test Isolation

Each test uses unique actor IDs via `LocalStackTestHelpers.uniqueActorID()` to prevent conflicts between parallel test runs:

```swift
let actorId = LocalStackTestHelpers.uniqueActorID() // "test-actor-<UUID>"
let actorId = LocalStackTestHelpers.uniqueActorID(prefix: "custom") // "custom-<UUID>"
```

### Resource Cleanup

Tests use defer blocks to ensure cleanup even on failure:

```swift
let client = LocalStackTestHelpers.createAWSClient()
defer { try? client.syncShutdown() }

// Test logic...

try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
```

### Testing Framework

All tests use **Swift Testing framework** (`import Testing`) with:
- `@Suite` for test organization
- `@Test` for individual test cases
- `#expect()` for assertions
- `Issue.record()` for custom failures

**DO NOT use XCTest** (`import XCTest`, `XCTestCase`, etc.)

## Troubleshooting

### LocalStack Not Starting

```bash
# Check LocalStack logs
docker-compose -f docker-compose.localstack.yml logs

# Common issues:
# - Port 4566 already in use
# - Docker daemon not running
# - Insufficient memory (LocalStack needs ~2GB)
```

### Init Scripts Not Running

```bash
# Manually run init scripts
docker exec trebuchet-localstack sh -c "cd /etc/localstack/init/ready.d && ./01-setup-tables.sh"
docker exec trebuchet-localstack sh -c "cd /etc/localstack/init/ready.d && ./02-setup-iam.sh"

# Check script permissions
ls -la Tests/TrebuchetAWSTests/localstack-init/
# Should show -rwxr-xr-x (executable)
```

### Tables Not Created

```bash
# Check if DynamoDB is running
curl http://localhost:4566/_localstack/health | jq '.services.dynamodb'

# Manually create tables
docker exec trebuchet-localstack awslocal dynamodb create-table \
  --table-name trebuchet-test-state \
  --attribute-definitions AttributeName=actorId,AttributeType=S \
  --key-schema AttributeName=actorId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES
```

### Tests Timing Out

```bash
# Increase wait timeout in LocalStackTestHelpers
# Default is 30 seconds, may need more on slow machines

# Check LocalStack resource usage
docker stats trebuchet-localstack
```

### CI Failures

Common GitHub Actions issues:

1. **LocalStack health check failing**
   - Increase `health-start-period` in workflow YAML
   - Add longer wait time in "Wait for LocalStack" step

2. **Init scripts not found**
   - Verify paths in workflow YAML
   - Check file permissions in repository

3. **AWS credentials not set**
   - Ensure `AWS_ACCESS_KEY_ID=test` and `AWS_SECRET_ACCESS_KEY=test` in environment
   - LocalStack accepts any credentials, but they must be present

## LocalStack Limitations

### What Works

- ✅ DynamoDB table operations (CRUD, streams)
- ✅ Cloud Map service registration/discovery
- ✅ IAM role and policy creation
- ✅ Lambda function deployment API
- ✅ API Gateway WebSocket endpoint creation

### What Doesn't Work

- ❌ Lambda function execution (code doesn't actually run)
- ❌ API Gateway WebSocket message sending (must be simulated)
- ❌ IAM policy evaluation (simplified in LocalStack)
- ❌ Cross-region replication (LocalStack is single-region)
- ❌ AWS-managed encryption keys (KMS simulation is basic)

### Workarounds

For features that don't work in LocalStack:

1. **Lambda execution** - Test deployment API only, use unit tests for handler logic
2. **WebSocket messages** - Manually create mock events in tests
3. **IAM policies** - Test policy creation, not enforcement
4. **Cross-region** - Simulate with different ports/hosts in metadata

## Integration with PostgreSQL Tests

This test suite follows the same pattern as PostgreSQL integration tests:

1. **Docker Compose** - Service container with health checks
2. **Availability Check** - `isLocalStackAvailable()` for graceful skipping
3. **Init Scripts** - Automatic resource setup on container start
4. **Cleanup Utilities** - Helper functions for test isolation
5. **CI Workflow** - GitHub Actions with service containers

## Contributing

When adding new integration tests:

1. **Use LocalStackTestHelpers** for consistency
2. **Add graceful skipping** with `.enabled(if:)` trait
3. **Use unique actor IDs** for isolation
4. **Clean up resources** in defer blocks
5. **Document LocalStack limitations** for new features
6. **Update this README** with new test suites

## Resources

- [LocalStack Documentation](https://docs.localstack.cloud/)
- [AWS SDK for Swift (Soto)](https://github.com/soto-project/soto)
- [Swift Testing Framework](https://github.com/apple/swift-testing)
- [Trebuchet AWS Module](../../Sources/TrebuchetAWS/)
