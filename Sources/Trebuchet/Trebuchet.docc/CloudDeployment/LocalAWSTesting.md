# Testing AWS Locally with LocalStack

Test your AWS integrations locally before deploying to production.

## Overview

TrebuchetAWS provides comprehensive LocalStack integration for testing AWS services locally without incurring cloud costs. This enables rapid development and testing of DynamoDB state storage, Cloud Map service discovery, and Lambda invocations.

## Prerequisites

Before running local AWS tests, ensure you have:

1. **Docker and Docker Compose** installed
2. **Swift 6.2 or later** with the Trebuchet package
3. **LocalStack 3.0** (Community Edition or Pro)

```bash
# Verify prerequisites
docker --version
docker-compose --version
swift --version
```

## Quick Start

### 1. Start LocalStack

```bash
# Start LocalStack with AWS services
docker-compose -f docker-compose.localstack.yml up -d

# Verify LocalStack is healthy
curl http://localhost:4566/_localstack/health
```

LocalStack will automatically create:
- DynamoDB tables (`trebuchet-test-state`, `trebuchet-test-connections`)
- IAM roles (`trebuchet-test-lambda-role`)
- Cloud Map namespace (`trebuchet-test`) - requires LocalStack Pro

### 2. Run Integration Tests

```bash
# Run all AWS integration tests
swift test --filter TrebuchetAWSTests

# Run specific test suite
swift test --filter DynamoDBStateStoreIntegrationTests
```

### 3. Cleanup

```bash
# Stop and remove LocalStack containers
docker-compose -f docker-compose.localstack.yml down -v
```

## Available Test Suites

### DynamoDB State Store (9 tests)

Tests actor state persistence with optimistic locking:

```bash
swift test --filter DynamoDBStateStoreIntegrationTests
```

Test coverage includes:
- Save and load actor state
- Sequence number auto-increment
- Delete operations
- Exists checks
- Optimistic locking with version checks
- Concurrent saves to different actors
- Update operations with transform functions
- Loading non-existent actors

### Cloud Map Registry (5 tests)

Tests service discovery operations - **requires LocalStack Pro**:

```bash
swift test --filter CloudMapRegistryIntegrationTests
```

Test coverage includes:
- Register and resolve actor endpoints
- Resolve non-existent actors
- Deregister operations
- List actors with prefix filter
- Heartbeat updates

> Note: Cloud Map tests are disabled by default in LocalStack Community Edition. Enable them by switching to LocalStack Pro.

### AWS Integration Workflows (3 tests)

End-to-end multi-service workflows - **requires LocalStack Pro**:

```bash
swift test --filter AWSIntegrationWorkflowTests
```

Test coverage includes:
- Actor discovery workflow (Cloud Map + DynamoDB)
- Optimistic locking conflict prevention
- Multi-region actor coordination

## LocalStack Service Support

### Community Edition (Free)

LocalStack Community Edition supports:
- ✅ **DynamoDB** - Full table operations and streams
- ✅ **Lambda** - Function deployment API
- ✅ **IAM** - Role and policy creation
- ✅ **API Gateway** - WebSocket endpoint creation

### Pro Edition (Paid)

LocalStack Pro adds:
- ✅ **Cloud Map (ServiceDiscovery)** - Full service registry operations
- ✅ **Enhanced Lambda** - Function execution
- ✅ **Advanced API Gateway** - Message sending

## Testing Your Own Code

### Using LocalStack Test Helpers

```swift
import Testing
import TrebuchetAWS
@testable import TrebuchetAWSTests

@Suite("My AWS Integration Tests")
struct MyAWSTests {
    @Test("Custom state store test")
    func testCustomStateStore() async throws {
        // Check LocalStack availability
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())

        // Create AWS client configured for LocalStack
        let client = LocalStackTestHelpers.createAWSClient()
        defer { try? await client.shutdown() }

        // Create state store
        let stateStore = LocalStackTestHelpers.createStateStore(client: client)

        // Use unique actor IDs for test isolation
        let actorId = LocalStackTestHelpers.uniqueActorID(prefix: "my-test")

        // Your test logic...
        let state = MyActorState(value: 42)
        try await stateStore.save(state, for: actorId)

        let loaded = try await stateStore.load(for: actorId, as: MyActorState.self)
        #expect(loaded?.value == 42)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
    }
}
```

### Test Isolation Best Practices

1. **Use unique actor IDs** - Prevents conflicts between parallel tests:
   ```swift
   let actorId = LocalStackTestHelpers.uniqueActorID()
   ```

2. **Clean up resources** - Use defer blocks for guaranteed cleanup:
   ```swift
   let client = LocalStackTestHelpers.createAWSClient()
   defer { try? await client.shutdown() }
   ```

3. **Check availability** - Gracefully skip when LocalStack unavailable:
   ```swift
   try #require(await LocalStackTestHelpers.isLocalStackAvailable())
   ```

## Docker Compose Configuration

The `docker-compose.localstack.yml` file configures LocalStack with:

```yaml
services:
  localstack:
    image: localstack/localstack:3.0
    ports:
      - "4566:4566"  # LocalStack gateway
    environment:
      - SERVICES=lambda,dynamodb,dynamodbstreams,servicediscovery,iam,apigatewayv2
      - AWS_DEFAULT_REGION=us-east-1
      - AWS_ACCESS_KEY_ID=test
      - AWS_SECRET_ACCESS_KEY=test
    volumes:
      - ./Tests/TrebuchetAWSTests/localstack-init:/etc/localstack/init/ready.d
```

Init scripts in `localstack-init/` automatically create required AWS resources on startup.

## Continuous Integration

The GitHub Actions workflow `.github/workflows/localstack-tests.yml` runs integration tests automatically:

- Starts LocalStack as a service container
- Initializes AWS resources with init scripts
- Runs all TrebuchetAWS integration tests
- Reports results and uploads test artifacts

View the workflow for CI integration examples.

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

### Tables Not Created

```bash
# Verify tables exist
docker exec trebuchet-localstack awslocal dynamodb list-tables

# Manually create if needed
docker exec trebuchet-localstack awslocal dynamodb create-table \
  --table-name trebuchet-test-state \
  --attribute-definitions AttributeName=actorId,AttributeType=S \
  --key-schema AttributeName=actorId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### Tests Timing Out

LocalStack startup can take 30-60 seconds. Increase timeout in `LocalStackTestHelpers.waitForTable()` if needed.

### Cloud Map Tests Failing

Cloud Map (ServiceDiscovery) requires LocalStack Pro. Community Edition returns 501 errors. Either:
- Upgrade to LocalStack Pro
- Disable Cloud Map tests (they're disabled by default)

## See Also

- <doc:DeployingToAWS>
- <doc:AWSConfiguration>
- ``DynamoDBStateStore``
- ``CloudMapRegistry``
