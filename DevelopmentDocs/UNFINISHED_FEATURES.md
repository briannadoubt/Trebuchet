# Unfinished Features & Integration Roadmap

**Date:** 2026-01-28
**Status:** Planning Document
**Purpose:** Systematic completion of unfinished features and integrations

---

## Strategic Decisions

### ✅ DECISION: Use Soto SDK for AWS Integration (2026-01-28)

**Decision:** Integrate Soto SDK despite build time cost rather than maintaining manual HTTP implementations.

**Rationale:**
- Battle-tested code with comprehensive AWS API coverage
- Automatic handling of request signing, retries, and error handling
- Type-safe Swift APIs for all AWS services
- Community support and regular updates
- Build time is a one-time cost; maintenance burden is forever

**Implementation Approach:**
- Use SotoCodeGenerator build plugin to generate only required services
- Services: DynamoDB, ServiceDiscovery (CloudMap), CloudWatch, Lambda, APIGatewayManagementAPI
- Configuration: `soto.config.json` for selective service generation
- Testing: LocalStack for local AWS simulation

**Status:** ✅ Package.swift updated, configuration created, ready for implementation

**See:** `Documentation/SOTO_INTEGRATION_EXAMPLE.md` for code examples

---

## Executive Summary

This document catalogs all unfinished, partially implemented, and unintegrated features discovered in the Trebuchet codebase. Rather than removing incomplete work, this roadmap provides a systematic path to completion.

**Key Metrics:**
- 7 major feature areas requiring completion
- 12+ specific integration points
- 3 critical path items blocking cloud deployment
- 2 duplicate implementations needing consolidation

---

## Priority Classification

### 🔴 Critical Path (Blocks Core Functionality)

Features that prevent documented capabilities from working at all.

### 🟡 High Value (Completes Major Features)

Features that would significantly enhance production readiness.

### 🟢 Enhancement (Improves User Experience)

Features that add polish and additional capabilities.

### 🔵 Architectural (Reduces Technical Debt)

Features that improve maintainability and consistency.

---

## Feature Catalog

## 1. AWS SDK Integration 🔴 CRITICAL PATH

**Status:** Documented but completely non-functional
**Impact:** All AWS cloud deployment features are stubs
**Effort:** Large (3-4 weeks)

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| DynamoDB State Store | `TrebuchetAWS/DynamoDBStateStore.swift:267` | "Would use AWS SDK (Soto)" |
| CloudMap Registry | `TrebuchetAWS/CloudMapRegistry.swift:192` | "Would use AWS SDK (Soto)" |
| AWS Provider | `TrebuchetAWS/AWSProvider.swift:29-44` | Returns placeholder deployments |
| CloudWatch Reporter | `TrebuchetObservability/Metrics/CloudWatchReporter.swift:44,132` | Only prints to console |
| Stream Processor | `TrebuchetAWS/StreamProcessorHandler.swift:82,146` | Uses in-memory stubs |

### What's Missing

1. **Dependency Integration**
   - Add `soto` (AWS SDK for Swift) to Package.swift
   - Add `soto-dynamodb`, `soto-servicediscovery`, `soto-cloudwatch`

2. **DynamoDB Integration** (`DynamoDBStateStore.swift`)
   - Replace mock client with real `DynamoDB` client
   - Implement actual `putItem`, `getItem`, `updateItem`, `deleteItem` calls
   - Add conditional check for optimistic locking
   - Handle AWS-specific errors and retry logic

3. **CloudMap Integration** (`CloudMapRegistry.swift`)
   - Replace mock client with real `ServiceDiscovery` client
   - Implement `registerInstance`, `deregisterInstance`, `discoverInstances`
   - Handle service namespace creation/lookup
   - Implement health check configuration

4. **CloudWatch Integration** (`CloudWatchReporter.swift`)
   - Replace mock client with real `CloudWatch` client
   - Implement `putMetricData` batching
   - Add namespace and dimension mapping
   - Handle rate limits and throttling

5. **Lambda Deployment** (`AWSProvider.swift`)
   - Implement actual Lambda function creation/updates
   - Add IAM role management
   - Configure API Gateway integration
   - Set up environment variables and VPC config

### Implementation Path

**Phase 1: Foundation (Week 1)**
- Add Soto dependencies to Package.swift
- Create AWS client initialization patterns
- Set up credential management (environment variables, IAM roles)

**Phase 2: State Store (Week 2)**
- Implement DynamoDB operations in `DynamoDBStateStore`
- Add integration tests with LocalStack
- Handle conditional updates for versioning

**Phase 3: Service Discovery (Week 2-3)**
- Implement CloudMap registry operations
- Add caching layer (already present, just wire up)
- Test multi-instance discovery

**Phase 4: Observability & Deployment (Week 3-4)**
- Wire up CloudWatch metrics
- Complete Lambda deployment in `AWSProvider`
- End-to-end deployment testing

**Phase 5: Production Hardening (Week 4)**
- Error handling and retries
- Rate limiting and backoff
- Documentation and examples

### Testing Strategy

- Use LocalStack for local AWS simulation
- Add integration test suite for each AWS service
- Create end-to-end deployment test
- Document AWS setup requirements

### Dependencies

- External: Soto SDK
- Internal: None (leaf-level implementation)

---

## 2. CloudGateway Invocation Routing ✅ COMPLETE

**Status:** ✅ Implemented and tested
**Completed:** 2026-01-28
**Impact:** RPC calls in cloud environments now fully functional

### Implementation Summary

**Changes Made:**

1. **CloudGateway.swift (Sources/TrebuchetCloud/Gateway/CloudGateway.swift)**
   - Implemented full `process()` method for programmatic invocation (lines 444-485)
   - Changed access levels from `private` to `internal` for: `actorSystem`, `registry`, `exposedActors`, `middlewareChain`, `executeInvocation()`
   - Added comprehensive documentation for the process() API

2. **CloudClient.swift (Sources/TrebuchetAWS/CloudClient.swift)**
   - Removed placeholder extension (moved to CloudGateway.swift in TrebuchetCloud module)
   - Left comment indicating code location

3. **Test Coverage (Tests/TrebuchetCloudTests/TrebuchetCloudTests.swift)**
   - Added CloudGatewayTests suite with 2 tests
   - Test 1: Actor not found error handling
   - Test 2: Middleware chain integration
   - Note: Successful method invocation tested via handleMessage() in integration tests

**Features Implemented:**

- ✅ Actor resolution from CloudGateway.exposedActors registry
- ✅ Actor not found error handling
- ✅ Method execution via executeDistributedTarget
- ✅ Response envelope creation (success/failure)
- ✅ Full middleware chain integration
- ✅ Error handling and logging
- ✅ Trace context support

**Known Limitations:**

- Direct unit testing of successful invocations is complex due to Swift's distributed actor method name mangling
- The process() method shares implementation with handleMessage(), which has full integration test coverage
- For testing, use TrebuchetClient to generate properly-formatted InvocationEnvelopes

---

## 3. Security Middleware Integration ✅ COMPLETE

**Status:** ✅ Implemented and wired up
**Completed:** 2026-01-28 (as part of Task #2)
**Impact:** Security features fully functional

### Implementation Summary

All middleware implementations exist and are complete:
- `TrebuchetSecurity/Middleware/AuthenticationMiddleware.swift` ✅ Complete
- `TrebuchetSecurity/Middleware/AuthorizationMiddleware.swift` ✅ Complete
- `TrebuchetSecurity/Middleware/RateLimitingMiddleware.swift` ✅ Complete
- `TrebuchetSecurity/Middleware/ValidationMiddleware.swift` ✅ Complete
- `TrebuchetCloud/Gateway/TracingMiddleware.swift` ✅ Complete

**Wired Up:** CloudGateway invokes MiddlewareChain in both entry points:
- `handleMessage()` - Line 242: `middlewareChain.execute(envelope, actor, context)`
- `process()` - Line 471: `middlewareChain.execute(envelope, actor, context)`

### Integration Points

**CloudGateway.swift:**
```swift
// Line 242 (handleMessage)
let response = try await middlewareChain.execute(
    envelope,
    actor: actor,
    context: context
) { envelope, context in
    try await self.executeInvocation(envelope, on: actor)
}

// Line 471 (process)
let response = try await middlewareChain.execute(
    envelope,
    actor: actor,
    context: context
) { envelope, context in
    try await self.executeInvocation(envelope, on: actor)
}
```

### Test Coverage

✅ **13 middleware integration tests** all passing:
- AuthenticationMiddleware (valid/invalid credentials)
- AuthorizationMiddleware (allow/deny)
- RateLimitingMiddleware (within/over limit)
- ValidationMiddleware (valid/invalid/oversized requests)
- TracingMiddleware (span creation/export)
- Empty chain execution
- Chain ordering
- Full stack integration

Test suite: `TrebuchetCloudTests/MiddlewareIntegrationTests.swift`

### Usage

Middleware is configured through `CloudGateway.Configuration`:

```swift
let gateway = CloudGateway(configuration: .init(
    host: "0.0.0.0",
    port: 8080,
    middlewares: [
        AuthenticationMiddleware(provider: apiKeyAuth),
        AuthorizationMiddleware(policy: rbacPolicy),
        RateLimitingMiddleware(limiter: tokenBucket),
        ValidationMiddleware(validator: requestValidator),
        TracingMiddleware(exporter: spanExporter)
    ]
))
```

---

## 4. Stream Resumption ✅ COMPLETED

**Status:** Core infrastructure implemented and tested
**Completed:** January 28, 2026
**Branch:** `feature/stream-resumption`

### What Was Completed

1. **Stream ID Infrastructure** ✅
   - Modified `TrebuchetActorSystem.remoteCallStream()` to return `(streamID: UUID, stream: AsyncStream<Res>)` instead of just the stream
   - Updated `ObservedActor.startStreaming()` to capture real streamID from actor system
   - Fixed placeholder UUID() usage - now uses real stream IDs from the system

2. **Resume Envelope Protocol** ✅
   - Added `TrebuchetClient.resumeStream()` method to send StreamResumeEnvelope
   - Implemented `StreamRegistry.createResumedStream()` to create streams with specific streamIDs
   - Implemented `ObservedActor.attemptStreamResume()` to handle reconnection with checkpoint
   - Client sends StreamResumeEnvelope with checkpoint on reconnect
   - Sequence number tracking continues across reconnections

3. **Server Replay Logic** ✅ (Already Existed)
   - `WebSocketLambdaHandler.handleStreamResume()` already implements full replay logic
   - Checks for buffered data and replays from checkpoint
   - Falls back to fresh StreamStartEnvelope if buffer expired
   - ServerStreamBuffer handles buffering with TTL

4. **Client State Reconciliation** ✅
   - ObservedActor tracks sequence numbers with StreamCheckpoint
   - Resumed streams continue from last sequence
   - Falls back to fresh stream on resume errors
   - Maintains checkpoint across reconnections

### Implementation Summary

**Files Modified:**
- `Sources/Trebuchet/ActorSystem/TrebuchetActorSystem.swift` - Return streamID from remoteCallStream()
- `Sources/Trebuchet/ActorSystem/StreamRegistry.swift` - Added createResumedStream() method
- `Sources/Trebuchet/Client/TrebuchetClient.swift` - Added resumeStream() method
- `Sources/Trebuchet/SwiftUI/ObservedActor.swift` - Implemented attemptStreamResume()

**Tests Added:**
- `testCreateResumedStream()` - Verifies creating stream with specific streamID
- `testStreamResumptionFlow()` - Tests full disconnect/reconnect/resume flow
- `testStreamBufferedDataRetrieval()` - Tests buffer catch-up on resumption

**All 22 streaming tests pass**, including the 3 new stream resumption tests.

### Architecture

When a client reconnects:
1. `ObservedActor` detects connection state change from disconnected → connected
2. If a checkpoint exists, calls `attemptStreamResume(checkpoint:)`
3. Creates a new local stream with the checkpoint's streamID via `StreamRegistry.createResumedStream()`
4. Sends `StreamResumeEnvelope` to server via `TrebuchetClient.resumeStream()`
5. Server (WebSocketLambdaHandler) receives resume request
6. Server replays buffered `StreamDataEnvelope`s from checkpoint, or sends fresh `StreamStartEnvelope` if buffer expired
7. Client's `StreamRegistry.handleStreamData()` yields data to resumed stream
8. ObservedActor continues updating state and tracking sequence numbers

### Remaining Work

**For Production:**
- End-to-end integration testing with real server
- Performance testing with various buffer sizes
- Metrics for resume success/failure rates
- Documentation for users on stream resumption behavior

**Known Limitations:**
- Sequence tracking assumes no gaps (increments by 1)
- No sequence number reconciliation from StreamDataEnvelope (data stream doesn't include metadata)
- Buffer TTL is fixed (could be configurable per stream)

---

## 5. PostgreSQL Stream Adapter 🔵 ARCHITECTURAL

**Status:** Duplicate implementations, both incomplete
**Impact:** Multi-instance actor synchronization via PostgreSQL unavailable
**Effort:** Medium (1 week)

### Duplicate Implementations

**Implementation 1: Core Module**
- **File:** `Trebuchet/ActorSystem/PostgreSQLStreamAdapter.swift`
- **Type:** Design specification with stub
- **Lines:** 176 lines of documentation and example code
- **Status:** `PostgreSQLStreamAdapterStub` that does nothing

**Implementation 2: PostgreSQL Module**
- **File:** `TrebuchetPostgreSQL/PostgreSQLStreamAdapter.swift`
- **Type:** Partial implementation
- **Lines:** 223 lines with actual logic
- **Status:** LISTEN/NOTIFY integration missing (line 211)

### What's Missing

1. **PostgresNIO Integration** (Implementation 2)
   - Wire up LISTEN/NOTIFY handlers
   - Connect notification callbacks to stream continuations
   - Handle connection loss and reconnection

2. **Implementation Consolidation**
   - Decide which version to keep (recommend Implementation 2)
   - Remove stub from core module
   - Move functionality to TrebuchetPostgreSQL module

3. **Multi-Instance Coordination**
   - Test with multiple server instances
   - Verify state changes propagate correctly
   - Handle race conditions and ordering

### Implementation Path

**Phase 1: Choose Implementation (Day 1)**
- Decision: Keep TrebuchetPostgreSQL version (more complete)
- Remove stub from Trebuchet core module
- Document PostgreSQL as optional dependency

**Phase 2: Complete LISTEN/NOTIFY (Days 2-4)**
- Implement notification handler in PostgreSQLStreamAdapter
- Wire up to PostgresNIO notification system
- Handle connection pooling and reconnection

**Phase 3: Testing (Days 4-5)**
- Set up test PostgreSQL instance
- Test multi-instance stream propagation
- Test failure scenarios (DB down, network partition)

**Phase 4: Documentation (Days 6-7)**
- Document PostgreSQL setup requirements
- Add deployment guide for multi-instance streaming
- Create example configurations

### Testing Strategy

- Docker Compose with multiple server instances + PostgreSQL
- Test NOTIFY delivery under load
- Test behavior when PostgreSQL is unavailable
- Benchmark performance vs DynamoDB Streams

### Dependencies

- Requires: PostgresNIO (already in Package.swift)
- Optional: Only needed for multi-instance deployments with PostgreSQL

### Decision Points

**Question 1:** Do we need multi-instance streaming with PostgreSQL?
- **Yes:** Complete implementation 2, remove implementation 1
- **No:** Remove both implementations, rely on DynamoDB Streams for AWS

**Question 2:** Should this be in core or separate module?
- **Current:** Separate TrebuchetPostgreSQL module ✅ Correct approach
- **Action:** Remove stub from core Trebuchet module

---

## 6. TCP Transport 🟢 ENHANCEMENT

**Status:** Enum exists, implementation is fatalError
**Impact:** Only WebSocket transport available
**Effort:** Medium (1 week)

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| Client | `Trebuchet/Client/TrebuchetClient.swift:44` | `fatalError("TCP transport not yet implemented")` |
| Server | `Trebuchet/Server/TrebuchetServer.swift:66` | `fatalError("TCP transport not yet implemented")` |

### What's Missing

1. **TCP Server Implementation**
   - SwiftNIO TCP bootstrap
   - Custom framing protocol (length-prefixed messages)
   - Connection management

2. **TCP Client Implementation**
   - SwiftNIO client bootstrap
   - Connection pooling
   - Reconnection logic

3. **Protocol Design**
   - Message framing (vs WebSocket which has built-in framing)
   - Binary protocol efficiency
   - Backpressure handling

### Implementation Path

**Phase 1: Protocol Design (Days 1-2)**
- Define message framing (e.g., 4-byte length prefix + payload)
- Design connection handshake
- Plan error handling

**Phase 2: Server Implementation (Days 3-4)**
- SwiftNIO TCP server bootstrap
- Message decoder/encoder pipeline
- Connection lifecycle management

**Phase 3: Client Implementation (Days 5-6)**
- SwiftNIO TCP client bootstrap
- Connection pooling and reuse
- Automatic reconnection

**Phase 4: Testing (Day 7)**
- Client-server integration tests
- Load testing vs WebSocket
- Network partition scenarios

### Testing Strategy

- Compare performance with WebSocket
- Test under high connection count
- Test message ordering guarantees
- Test backpressure handling

### Decision Points

**Question:** Is TCP transport needed?
- **WebSocket Advantages:** Built-in framing, browser compatibility, HTTP upgrade
- **TCP Advantages:** Lower overhead, simpler protocol, better for server-to-server
- **Use Cases:** Microservice mesh, high-throughput actor systems

**Recommendation:** Implement if targeting server-to-server deployments; otherwise WebSocket is sufficient.

---

## 7. WebSocket Lambda Handler RPC Execution ✅ COMPLETE

**Status:** ✅ Implemented and tested
**Completed:** 2026-01-28
**Impact:** Non-streaming RPC calls via API Gateway WebSocket now fully functional

### Implementation Summary

**File:** `TrebuchetAWS/WebSocketLambdaHandler.swift:244-260`

**Before:**
```swift
private func handleRPCInvocation(...) async throws -> APIGatewayWebSocketResponse {
    // TODO: Execute RPC through CloudGateway when handleInvocation is implemented
    // For now, return a simple acknowledgment

    let response = ResponseEnvelope(
        callID: invocation.callID,
        result: Data(),
        errorMessage: nil
    )
    // ...
}
```

**After:**
```swift
private func handleRPCInvocation(...) async throws -> APIGatewayWebSocketResponse {
    // Execute RPC through CloudGateway
    let response = await gateway.process(invocation)
    // ...
}
```

### Changes Made

1. **WebSocketLambdaHandler.swift (line 248)**
   - Replaced dummy response with `await gateway.process(invocation)`
   - Removed TODO comment
   - RPC invocations now execute actual actor methods

2. **Test Coverage**
   - Added `testHandleRPCInvocation()` test in WebSocketTests.swift
   - Tests full RPC flow: invocation → CloudGateway.process() → actor method → response
   - Verifies correct result encoding and WebSocket transmission

### Integration

WebSocket Lambda Handler now provides complete support for:
- ✅ Connection lifecycle ($connect, $disconnect)
- ✅ **Non-streaming RPC calls** (via CloudGateway.process())
- ✅ Streaming invocations (with StreamStart/StreamData/StreamEnd)
- ✅ Stream resumption (with buffered data replay)

All invocation types route through CloudGateway with full middleware support (authentication, authorization, rate limiting, validation, tracing).

---

## 8. DynamoDB Streams Processor 🟡 HIGH VALUE

**Status:** Placeholder for "Phase 12"
**Impact:** WebSocket streaming via DynamoDB Streams doesn't work
**Effort:** Medium (1 week)

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| Stream Handler | `TrebuchetAWS/WebSocketLambdaHandler.swift:238` | "Phase 12" comment |
| Processor | `TrebuchetAWS/StreamProcessorHandler.swift` | Uses in-memory stubs |

### What's Missing

1. **DynamoDB Streams Integration**
   - Lambda trigger on DynamoDB stream events
   - Parse stream records (INSERT, MODIFY, REMOVE)
   - Extract actor ID and state changes

2. **WebSocket Broadcast**
   - Look up active WebSocket connections for actor
   - Send StreamDataEnvelope to all subscribed clients
   - Handle connection failures gracefully

3. **Connection Management**
   - DynamoDB-based connection storage (exists, needs integration)
   - API Gateway Management API for sending messages
   - Clean up stale connections

### Implementation Path

**Phase 1: DynamoDB Streams Setup (Days 1-2)**
- Configure DynamoDB table with streams enabled
- Create Lambda function triggered by stream
- Parse stream records into state changes

**Phase 2: Connection Storage (Days 3-4)**
- Integrate DynamoDBConnectionStorage (already exists)
- Store connection mappings (actorID -> connectionIDs)
- Implement cleanup on disconnect

**Phase 3: WebSocket Broadcasting (Days 5-6)**
- Use APIGatewayConnectionSender (already exists)
- Send state updates to all connections
- Handle send failures (remove stale connections)

**Phase 4: End-to-End Testing (Day 7)**
- Test with multiple clients subscribed to same actor
- Test rapid state changes (batching/debouncing?)
- Test at scale (100+ concurrent connections)

### Testing Strategy

- LocalStack for DynamoDB Streams simulation
- Mock API Gateway Management API
- Load testing with artillery or similar
- Test connection lifecycle (connect, subscribe, disconnect)

### Dependencies

- Requires: Task #1 (AWS SDK integration) for DynamoDB and API Gateway clients
- Enables: Real-time streaming in AWS Lambda deployments

---

## 9. CloudWatch Metrics Implementation 🟢 ENHANCEMENT

**Status:** Prints to console only
**Impact:** No production metrics in AWS deployments
**Effort:** Small (2-3 days)

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| CloudWatch Reporter | `TrebuchetObservability/Metrics/CloudWatchReporter.swift:44,132` | Placeholder implementation |

### What's Missing

This is part of AWS SDK integration (Task #1). The logic exists for metric collection and batching; just needs real CloudWatch API calls.

```swift
// Currently:
private func sendBatch(_ batch: [Metric]) async {
    #if DEBUG
    print("Would send \(batch.count) metrics to CloudWatch")
    #endif
}

// Should be:
private func sendBatch(_ batch: [Metric]) async throws {
    let metricData = batch.map { convertToCloudWatchMetric($0) }
    try await cloudWatchClient.putMetricData(.init(
        namespace: namespace,
        metricData: metricData
    ))
}
```

### Implementation Path

**Day 1:** CloudWatch Client Integration
- Add CloudWatch client initialization
- Implement metric conversion to CloudWatch format
- Handle dimensions and units

**Day 2:** Error Handling
- Retry logic for throttling
- Batch size limits (20 metrics per request)
- Fallback to console logging on failure

**Day 3:** Testing
- Mock CloudWatch API
- Test batching logic
- Test different metric types (counter, gauge, histogram)

### Dependencies

- Requires: Task #1 (AWS SDK integration) for CloudWatch client
- Enhances: Production observability

---

## 10. Deprecated API Cleanup 🔵 ARCHITECTURAL

**Status:** Marked deprecated but still present
**Impact:** Code clutter, maintenance burden
**Effort:** Trivial (1 hour)

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| JWT Authenticator | `TrebuchetSecurity/Authentication/JWTAuthenticator.swift:72,78` | Deprecated methods |
| SwiftUI Modifiers | `Trebuchet/SwiftUI/TrebuchetViewModifiers.swift:56` | Deprecated modifier variant |

### What to Remove

1. **JWTAuthenticator deprecated methods**
   - Keep new renamed versions
   - Remove old methods
   - Update any internal callers

2. **SwiftUI deprecated modifiers**
   - Keep new `.trebuchet(transport:reconnectionPolicy:autoConnect:)` signature
   - Remove old signature
   - Update documentation

### Implementation Path

**Action Items:**
1. Search for any callers of deprecated APIs
2. Update callers to use new APIs
3. Remove deprecated methods
4. Update CHANGELOG for breaking change

**Timing:** Do this in next major version (0.3.0 or 1.0.0)

---

## Implementation Roadmap

### Phase 0: Foundation & Planning (Week 1)

**Goal:** Set up infrastructure for completion work

- [ ] Review and approve this roadmap
- [ ] Set up AWS LocalStack for testing
- [ ] Set up PostgreSQL test environment
- [ ] Create feature flags for experimental work
- [ ] Establish testing strategy for each component

### Phase 1: Critical Path - Cloud Deployment (Weeks 2-5)

**Goal:** Make cloud deployment actually work

**Week 2: AWS SDK Foundation**
- [ ] Task #1 Phase 1-2: Add Soto dependencies and implement DynamoDB
- [ ] Task #2 Phase 1-2: Actor resolution and method invocation
- [ ] Task #3: Wire up security middleware (quick win)

**Week 3: Service Discovery & Routing**
- [ ] Task #1 Phase 3: CloudMap integration
- [ ] Task #2 Phase 3: Middleware integration in CloudGateway
- [ ] Task #7: WebSocket Lambda handler (dependent on Task #2)

**Week 4: Observability & Deployment**
- [ ] Task #1 Phase 4: CloudWatch metrics and Lambda deployment
- [ ] Task #2 Phase 4: Error handling and production hardening
- [ ] Task #9: CloudWatch metrics implementation

**Week 5: Production Hardening**
- [ ] Task #1 Phase 5: AWS error handling and retries
- [ ] End-to-end deployment testing
- [ ] Documentation and deployment guides

**Deliverable:** Fully functional AWS Lambda deployment

### Phase 2: Streaming Reliability (Weeks 6-7)

**Goal:** Make streaming production-ready

**Week 6: Stream Resumption**
- [ ] Task #4 Phase 1-2: Stream ID infrastructure and resume protocol
- [ ] Task #4 Phase 3-4: Server replay and client reconciliation
- [ ] Testing with network interruptions

**Week 7: DynamoDB Streams**
- [ ] Task #8 Phase 1-2: DynamoDB Streams and connection storage
- [ ] Task #8 Phase 3-4: WebSocket broadcasting and testing
- [ ] Load testing at scale

**Deliverable:** Reliable streaming with resumption and multi-client broadcasting

### Phase 3: Multi-Instance Coordination (Week 8)

**Goal:** Enable horizontal scaling

**Week 8: PostgreSQL Streams**
- [ ] Task #5 Phase 1: Consolidate implementations
- [ ] Task #5 Phase 2-3: Complete LISTEN/NOTIFY and testing
- [ ] Task #5 Phase 4: Documentation
- [ ] Compare PostgreSQL vs DynamoDB Streams performance

**Deliverable:** Choice of PostgreSQL or DynamoDB for multi-instance streaming

### Phase 4: Enhancements (Week 9)

**Goal:** Additional transport options and polish

**Week 9: TCP Transport & Cleanup**
- [ ] Task #6: TCP transport implementation (if desired)
- [ ] Task #10: Remove deprecated APIs
- [ ] Performance benchmarking (WebSocket vs TCP)
- [ ] Documentation updates

**Deliverable:** Full transport flexibility and clean codebase

---

## Success Metrics

### Completion Criteria

Each feature area should meet these criteria before being marked complete:

1. **Implementation Complete**
   - No TODO/FIXME comments remaining
   - No placeholder/stub code
   - All error cases handled

2. **Tests Pass**
   - Unit tests for core logic
   - Integration tests with real/mocked services
   - End-to-end scenario tests

3. **Documentation Updated**
   - API documentation complete
   - Usage examples provided
   - Deployment guides updated

4. **Performance Validated**
   - Benchmarks meet targets
   - No memory leaks
   - Scales to expected load

### Tracking Progress

Update this document with checkboxes as work progresses:
- ✅ Complete
- 🏗️ In Progress
- ⏸️ Blocked
- ❌ Cancelled

---

## Risk Mitigation

### Technical Risks

1. **AWS SDK Breaking Changes**
   - **Risk:** Soto SDK API changes
   - **Mitigation:** Pin to specific version, test before upgrading

2. **Performance Degradation**
   - **Risk:** Middleware overhead, stream buffering memory
   - **Mitigation:** Benchmark each phase, set performance budgets

3. **Stream Resumption Complexity**
   - **Risk:** Race conditions, data loss
   - **Mitigation:** Extensive testing, formal verification of protocol

### Project Risks

1. **Scope Creep**
   - **Risk:** Adding features beyond documented scope
   - **Mitigation:** Stick to this roadmap, defer new features

2. **Priority Conflicts**
   - **Risk:** New urgent features interrupt completion work
   - **Mitigation:** Allocate dedicated time for completion work

3. **Testing Infrastructure**
   - **Risk:** Inadequate test environments
   - **Mitigation:** Set up LocalStack, PostgreSQL, load testing early

---

## Open Questions

These decisions will shape the implementation approach:

### Strategy Questions

1. **AWS Commitment**
   - Are we fully committed to AWS, or exploring other platforms?
   - Should we prioritize AWS completion or add Fly.io/Railway/GCP?

2. **Streaming Backend**
   - PostgreSQL LISTEN/NOTIFY or DynamoDB Streams?
   - Can we support both, or should we choose one?

3. **Transport Priority**
   - Is TCP transport needed, or is WebSocket sufficient?
   - What are the target deployment patterns?

### Technical Questions

1. **Stream Resumption**
   - What's acceptable buffer duration? (5 min? 1 hour?)
   - How do we handle expired buffers gracefully?

2. **Middleware Performance**
   - What's acceptable middleware overhead? (<1ms? <10ms?)
   - Should middleware be optional/configurable?

3. **Multi-Instance Coordination**
   - How do we handle split-brain scenarios?
   - What consistency guarantees do we need?

---

## Next Steps

1. **Review this document** - Validate findings and prioritization
2. **Make strategic decisions** - Answer open questions
3. **Approve roadmap** - Commit to phased implementation
4. **Begin Phase 0** - Set up testing infrastructure
5. **Execute systematically** - Work through phases in order

---

## Appendix: File Reference

Complete list of files requiring changes:

### AWS Integration
- `Sources/TrebuchetAWS/DynamoDBStateStore.swift`
- `Sources/TrebuchetAWS/CloudMapRegistry.swift`
- `Sources/TrebuchetAWS/AWSProvider.swift`
- `Sources/TrebuchetAWS/StreamProcessorHandler.swift`
- `Sources/TrebuchetAWS/WebSocketLambdaHandler.swift`
- `Sources/TrebuchetAWS/CloudClient.swift`
- `Sources/TrebuchetObservability/Metrics/CloudWatchReporter.swift`

### CloudGateway
- `Sources/TrebuchetCloud/Gateway/CloudGateway.swift`

### Streaming
- `Sources/Trebuchet/SwiftUI/ObservedActor.swift`
- `Sources/Trebuchet/Server/TrebuchetServer.swift`
- `Sources/Trebuchet/ActorSystem/StreamRegistry.swift`

### PostgreSQL
- `Sources/Trebuchet/ActorSystem/PostgreSQLStreamAdapter.swift` (remove)
- `Sources/TrebuchetPostgreSQL/PostgreSQLStreamAdapter.swift` (complete)

### Transport
- `Sources/Trebuchet/Client/TrebuchetClient.swift`
- `Sources/Trebuchet/Server/TrebuchetServer.swift`

### Cleanup
- `Sources/TrebuchetSecurity/Authentication/JWTAuthenticator.swift`
- `Sources/Trebuchet/SwiftUI/TrebuchetViewModifiers.swift`

---

**Document Version:** 1.0
**Last Updated:** 2026-01-28
**Next Review:** After Phase 0 completion
