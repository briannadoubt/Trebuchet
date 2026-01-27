# Deploying to Fly.io

Deploy your Trebuchet actors to Fly.io for a simple, cost-effective production deployment.

## Why Fly.io?

- ✅ **Simple**: One command deployment
- ✅ **Cheap**: $0-5/month for most apps
- ✅ **Fast**: Global edge locations
- ✅ **WebSocket-native**: No API Gateway needed
- ✅ **Built-in PostgreSQL**: Optional state storage

## Prerequisites

Install the Fly.io CLI:

```bash
# macOS/Linux
curl -L https://fly.io/install.sh | sh

# Or with Homebrew
brew install flyctl

# Login
fly auth login
```

## Quick Start

### 1. Create `trebuchet.yaml`

```yaml
name: my-game-server
version: "1"

defaults:
  provider: fly
  region: ord  # Chicago - use your nearest region
  memory: 512

actors:
  GameRoom:
    memory: 512
  Lobby:
    memory: 256
```

### 2. Deploy

```bash
trebuchet deploy --provider fly

# Output:
# Discovering actors...
#   ✓ GameRoom
#   ✓ Lobby
#
# Generating Fly.io configuration...
#   ✓ Generated fly.toml
#   ✓ Generated Dockerfile
#   ✓ Generated .dockerignore
#
# Creating Fly.io app 'my-game-server'...
#   ✓ App created
#
# Deploying to Fly.io...
#   Building and pushing Docker image...
#   ✓ Deployed successfully
#
# 🚀 Deployment successful!
#
#   App:      my-game-server
#   URL:      https://my-game-server.fly.dev
#   Region:   ord
#   Status:   running
#
# Ready! Connect with:
#   wss://my-game-server.fly.dev
```

That's it! Your actors are now running on Fly.io.

## With PostgreSQL State

If your actors need persistent state:

```yaml
name: my-game-server
version: "1"

defaults:
  provider: fly
  region: ord
  memory: 512

actors:
  GameRoom:
    memory: 512
    stateful: true  # Enables state persistence

state:
  type: postgresql  # Use PostgreSQL for state storage
```

Deploy:

```bash
trebuchet deploy --provider fly

# The CLI will:
# 1. Create a PostgreSQL database
# 2. Attach it to your app
# 3. Set DATABASE_URL environment variable
# 4. Your actors can now use saveState() and loadState()
```

## Regions

Available regions:

| Code | Region | Location |
|------|--------|----------|
| `ord` | Chicago | US Central |
| `iad` | Ashburn | US East |
| `lax` | Los Angeles | US West |
| `ewr` | New Jersey | US East |
| `lhr` | London | Europe |
| `fra` | Frankfurt | Europe |
| `ams` | Amsterdam | Europe |
| `syd` | Sydney | Australia |
| `sin` | Singapore | Asia |
| `nrt` | Tokyo | Asia |

Choose the region closest to your users.

## Scaling

### Vertical Scaling (More Memory)

Update `trebuchet.yaml`:

```yaml
defaults:
  memory: 1024  # Increase to 1GB
```

Redeploy:

```bash
trebuchet deploy --provider fly
```

### Horizontal Scaling (More Instances)

```bash
# Scale to 3 instances
fly scale count 3 --app my-game-server

# Autoscale based on load
fly autoscale set min=1 max=5 --app my-game-server
```

### Multi-Region (Global)

```bash
# Add regions
fly regions add lax syd fra --app my-game-server

# Scale per region
fly scale count 2 --region lax --app my-game-server
fly scale count 2 --region syd --app my-game-server
fly scale count 2 --region fra --app my-game-server
```

Now you have 6 instances across 3 continents!

## Costs

### Free Tier

- 3 shared-cpu-1x VMs (256MB RAM each)
- Perfect for testing and small apps
- No credit card required

### Paid Pricing

| Resource | Price |
|----------|-------|
| shared-cpu-1x (256MB) | $1.94/month |
| shared-cpu-1x (512MB) | $3.88/month |
| shared-cpu-1x (1GB) | $7.75/month |
| PostgreSQL (1GB) | Free |
| PostgreSQL (10GB) | $0.15/GB/month |
| Bandwidth | $0.02/GB (first 100GB free) |

**Typical costs:**
- Small app (1 instance, 512MB): **$3.88/month**
- Medium app (3 instances, 512MB): **$11.64/month**
- Large app (5 instances, 1GB, PostgreSQL): **$40/month**

Compare to AWS Lambda: **$15-50/month** for similar load

## Monitoring

### View Logs

```bash
# Tail logs in real-time
fly logs --app my-game-server

# Filter by instance
fly logs --app my-game-server --instance 123456
```

### Check Status

```bash
# App status
fly status --app my-game-server

# Metrics
fly dashboard metrics --app my-game-server
```

### Web Dashboard

Open the web dashboard:

```bash
fly dashboard --app my-game-server
```

## Troubleshooting

### Check App Health

```bash
fly checks list --app my-game-server
```

### SSH into Instance

```bash
fly ssh console --app my-game-server
```

### Restart App

```bash
fly apps restart my-game-server
```

### View Deployment History

```bash
fly releases --app my-game-server
```

### Rollback

```bash
# Rollback to previous version
fly releases rollback --app my-game-server
```

## Undeploying

Remove everything:

```bash
trebuchet undeploy

# Or manually
fly apps destroy my-game-server
```

## Example: Complete Setup

```yaml
# trebuchet.yaml
name: distributed-game
version: "1"

defaults:
  provider: fly
  region: ord
  memory: 512

actors:
  GameLobby:
    memory: 256

  GameRoom:
    memory: 512
    stateful: true

  PlayerStats:
    memory: 256
    stateful: true

state:
  type: postgresql

observability:
  logging:
    level: info
  metrics:
    enabled: true

security:
  authentication:
    type: apikey
  rateLimiting:
    requestsPerSecond: 100
```

Deploy:

```bash
trebuchet deploy --provider fly
```

Result:
- 3 actor types running
- PostgreSQL for stateful actors
- Logging and metrics enabled
- API key authentication
- Rate limiting at 100 req/sec
- **Total cost: ~$5/month**

## Comparison: Fly.io vs AWS Lambda

| Feature | Fly.io | AWS Lambda |
|---------|--------|------------|
| **Deployment** | `trebuchet deploy` | `trebuchet deploy` |
| **Cost** | $3-10/month | $15-50/month |
| **Cold starts** | None (always warm) | 100-500ms |
| **WebSocket** | Native | Via API Gateway |
| **State** | PostgreSQL local | DynamoDB |
| **Complexity** | Low | High |
| **Best for** | Always-on apps | Bursty workloads |

## Next Steps

- <doc:PostgreSQLConfiguration> - Configure PostgreSQL for state persistence
- See TrebuchetSecurity module for authentication (JWT and API keys)
- See TrebuchetObservability module for metrics and monitoring
- <doc:AWSWebSocketStreaming> - Multi-region deployment patterns
