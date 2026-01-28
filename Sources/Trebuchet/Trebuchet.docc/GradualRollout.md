# Gradual Rollout Strategy

Deploy new versions safely with zero downtime and zero dropped requests.

## Overview

Gradual rollouts allow you to deploy new versions of your actors incrementally, monitoring for issues before full deployment. Combined with state versioning and protocol versioning, you can achieve true zero-downtime deployments.

## Prerequisites

Before deploying:

1. **State Versioning**: Prevent concurrent write conflicts
2. **Protocol Versioning**: Handle mixed client/server versions
3. **Graceful Shutdown**: Drain requests before stopping instances

## Deployment Strategies

### Strategy 1: Blue-Green Deployment

Deploy new version alongside old, then switch traffic:

```bash
# Phase 1: Deploy green (new version)
trebuchet deploy --environment green --version 2.0.0

# Phase 2: Test green
curl https://green.example.com/health
# {"status":"healthy","inflightRequests":0}

# Phase 3: Switch traffic
aws elbv2 modify-target-group --target-group-arn ... --targets green

# Phase 4: Monitor for issues
watch -n 5 'curl https://api.example.com/metrics'

# Phase 5: Shutdown blue (old version)
trebuchet undeploy --environment blue
```

**Pros**:
- Instant rollback (switch back to blue)
- Full testing before switching

**Cons**:
- 2x infrastructure cost during deployment
- All-or-nothing switch

### Strategy 2: Rolling Deployment

Replace instances one by one:

```bash
# Phase 1: Deploy to 20% of instances
trebuchet deploy --canary-percent 20

# Phase 2: Monitor metrics
watch 'curl https://api.example.com/metrics | jq .error_rate'

# Phase 3: Increase to 50%
trebuchet deploy --canary-percent 50

# Phase 4: Full deployment
trebuchet deploy --canary-percent 100
```

**Pros**:
- Gradual risk exposure
- Cost-effective (no extra instances)

**Cons**:
- Mixed versions run simultaneously
- Rollback requires redeployment

### Strategy 3: Canary Deployment

Route small percentage of traffic to new version:

```bash
# Phase 1: Deploy canary
trebuchet deploy --canary --traffic-percent 5

# Phase 2: Monitor canary metrics
curl https://canary.example.com/health

# Phase 3: Increase traffic
trebuchet deploy --traffic-percent 25
trebuchet deploy --traffic-percent 50
trebuchet deploy --traffic-percent 100

# Phase 4: Promote canary to prod
trebuchet promote-canary
```

**Pros**:
- Minimal blast radius
- Real production traffic testing

**Cons**:
- Complex routing logic
- Requires traffic-splitting infrastructure

## Graceful Shutdown Process

### Server Shutdown Lifecycle

```swift
let server = TrebuchetServer(transport: .webSocket(port: 8080))

// Start server
try await server.run()

// On SIGTERM...
await server.gracefulShutdown(timeout: .seconds(30))
```

Graceful shutdown flow:

1. **Draining Phase** (0-30s)
   - Stop accepting new requests
   - Health check returns "draining"
   - Load balancer stops routing traffic
   - Existing requests continue

2. **Completion Phase** (until timeout)
   - Wait for in-flight requests to finish
   - Monitor: `await server.healthStatus()`

3. **Forced Cleanup** (at timeout)
   - Cancel remaining requests
   - Clean up streams
   - Close connections

### Health Check Integration

```swift
// Health check endpoint
app.get("/health") { req async in
    let status = await server.healthStatus()

    return Response(
        status: status.isHealthy ? .ok : .serviceUnavailable,
        body: try JSONEncoder().encode(status)
    )
}
```

Load balancer configuration:

```yaml
# AWS ALB target group
HealthCheckPath: /health
HealthCheckIntervalSeconds: 5
HealthyThresholdCount: 2
UnhealthyThresholdCount: 2
Matcher:
  HttpCode: 200  # Only route to "healthy" instances
```

When draining:
- Returns HTTP 503 with `{"status":"draining"}`
- Load balancer marks unhealthy and stops routing
- Existing connections remain open

## Monitoring During Rollout

### Key Metrics

```swift
// Track protocol versions
logger.info("Request received", metadata: [
    "protocolVersion": String(envelope.protocolVersion),
    "serverVersion": "2.0.0"
])

// Track version conflicts
do {
    try await store.saveIfVersion(...)
} catch ActorStateError.versionConflict(let expected, let actual) {
    metrics.incrementCounter("state.version_conflicts", tags: [
        "actorID": actorID
    ])
}

// Track in-flight requests
let stats = await server.inflightTracker.statistics()
metrics.recordGauge("server.inflight_requests", value: Double(stats.totalRequests))
```

### Dashboard Queries

```promql
# Error rate by version
rate(trebuchet_errors_total{version="2.0.0"}[5m])

# Version conflict rate
rate(trebuchet_state_version_conflicts_total[5m])

# Request latency by protocol version
histogram_quantile(0.95,
  rate(trebuchet_request_duration_seconds_bucket{protocol_version="2"}[5m])
)

# In-flight requests during shutdown
trebuchet_inflight_requests{instance=~"shutting-down-.*"}
```

### Alerts

```yaml
# High version conflict rate
alert: HighStateConflicts
expr: rate(trebuchet_state_version_conflicts_total[5m]) > 10
annotations:
  summary: "High state version conflicts"
  description: "{{ $value }} conflicts/sec - may indicate deployment issue"

# Protocol version incompatibility
alert: UnsupportedProtocolVersion
expr: trebuchet_protocol_errors_total{reason="unsupported_version"} > 0
annotations:
  summary: "Clients using unsupported protocol version"

# Prolonged draining
alert: ServerStuckDraining
expr: trebuchet_server_state{state="draining"} > 60
annotations:
  summary: "Server draining for >60s"
  description: "In-flight requests not completing"
```

## Example Deployments

### Example 1: Adding Required Parameter

**Scenario**: Add `includeArchived` parameter to `getProjects()`.

**Week 1 - Deploy v1.1 (Additive)**:

```swift
@Trebuchet
distributed actor ProjectService {
    // Old method (v1 compatibility)
    @available(*, deprecated, renamed: "getProjects(includeArchived:)")
    distributed func getProjects() -> [Project] {
        return try await getProjects(includeArchived: false)
    }

    // New method
    distributed func getProjects(includeArchived: Bool) -> [Project] {
        // Implementation
    }
}
```

Deploy with rolling update:
```bash
trebuchet deploy --version 1.1.0 --strategy rolling
```

**Week 2-4 - Monitor**:
```bash
# Check v1 method usage (should decrease)
curl https://api.example.com/metrics | jq '.methods."getProjects()".calls'

# Check v2 method usage (should increase)
curl https://api.example.com/metrics | jq '.methods."getProjects(includeArchived:)".calls'
```

**Week 5 - Deploy v2.0 (Breaking)**:

```swift
@Trebuchet
distributed actor ProjectService {
    // Only new method remains
    distributed func getProjects(includeArchived: Bool) -> [Project] {
        // Implementation
    }
}
```

Deploy:
```bash
trebuchet deploy --version 2.0.0 --strategy canary --traffic-percent 10
# Monitor for errors
trebuchet deploy --traffic-percent 100
```

### Example 2: Changing State Schema

**Scenario**: Add `createdAt` field to user state.

**Before (v1)**:

```swift
struct UserState: Codable, Sendable {
    var name: String
    var email: String
}
```

**Migration (v1.1)**:

```swift
struct UserState: Codable, Sendable {
    var name: String
    var email: String
    var createdAt: Date?  // Optional for backward compatibility

    // Migration logic
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decode(String.self, forKey: .email)

        // Default for old states
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
```

Deploy v1.1:
```bash
trebuchet deploy --version 1.1.0
```

All new user states will have `createdAt`. Old states get it on first write.

**After Migration (v2.0)**:

```swift
struct UserState: Codable, Sendable {
    var name: String
    var email: String
    var createdAt: Date  // Now required

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decode(String.self, forKey: .email)

        // Still handle missing field for safety
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
```

### Example 3: Distributed → Monolith Migration

**Scenario**: Consolidate multiple actor instances into single monolith.

**Phase 1 - Add State Versioning**:

Ensure all writes use optimistic locking:

```swift
distributed func updateProfile(name: String, store: ActorStateStore) async throws {
    try await updateStateSafely(store: store) { current in
        var state = current ?? UserState()
        state.name = name
        return state
    }
}
```

**Phase 2 - Deploy Monolith**:

```bash
# Deploy new monolith instances
trebuchet deploy --environment monolith --instances 3

# Route 10% of traffic to monolith
aws elbv2 modify-rule --rule-arn ... --conditions 'Weight=10'
```

**Phase 3 - Monitor Version Conflicts**:

```bash
# Should see some conflicts as distributed + monolith run together
curl https://api.example.com/metrics | jq '.state_version_conflicts'
```

**Phase 4 - Increase Traffic**:

```bash
# Gradually increase
aws elbv2 modify-rule ... 'Weight=50'
aws elbv2 modify-rule ... 'Weight=100'
```

**Phase 5 - Shutdown Distributed**:

```bash
trebuchet undeploy --environment distributed
```

## Rollback Procedures

### Immediate Rollback

If critical issues detected:

```bash
# Blue-green: Switch back
aws elbv2 modify-target-group --targets blue

# Rolling: Redeploy previous version
trebuchet deploy --version 1.9.0 --force

# Canary: Stop canary traffic
trebuchet deploy --traffic-percent 0
```

### State Rollback

If new version corrupted state:

1. **Stop all new instances**:
   ```bash
   trebuchet undeploy --version 2.0.0
   ```

2. **Restore from backup**:
   ```bash
   aws dynamodb restore-table-from-backup \
     --target-table-name actor-states \
     --backup-arn arn:aws:dynamodb:...:backup/...
   ```

3. **Redeploy old version**:
   ```bash
   trebuchet deploy --version 1.9.0
   ```

## Checklist

Before deploying:

- [ ] State versioning implemented for all writes
- [ ] Protocol versioning configured
- [ ] Graceful shutdown tested
- [ ] Health check endpoint configured
- [ ] Monitoring dashboards updated
- [ ] Alerts configured
- [ ] Rollback procedure documented
- [ ] Database backups verified
- [ ] Load balancer health checks configured
- [ ] Staged rollout percentages planned

During deployment:

- [ ] Monitor error rates
- [ ] Monitor version conflicts
- [ ] Monitor protocol versions
- [ ] Check health status
- [ ] Verify in-flight requests draining
- [ ] Watch for slow/stuck requests

After deployment:

- [ ] Verify all instances updated
- [ ] Check for orphaned instances
- [ ] Monitor for 24 hours
- [ ] Update runbooks
- [ ] Document any issues

## See Also

- <doc:StateVersioning>
- <doc:ProtocolVersioning>
- ``TrebuchetServer/gracefulShutdown(timeout:)``
- ``HealthStatus``
