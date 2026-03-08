# Deploying to AWS

Deploy your distributed actors to AWS Lambda with the trebuchet CLI.

Canonical workflow: deploy from a System executable Swift package (`trebuchet deploy <system-package-path> --product <SystemExecutable> ...`).
Any `trebuchet.yaml` snippets in this page are legacy migration examples.

## Overview

Trebuchet provides a streamlined deployment experience for AWS Lambda, similar to frameworks like Vercel or AWS Amplify. The CLI handles:

- Actor discovery in your codebase
- Cross-compilation for Lambda (arm64)
- Terraform generation for AWS infrastructure
- Automated deployment

## Prerequisites

Before deploying, ensure you have:

1. **AWS CLI** configured with appropriate credentials
2. **Docker** installed (for cross-compilation)
3. **Terraform** installed (for infrastructure management)

```bash
# Verify prerequisites
aws sts get-caller-identity
docker --version
terraform --version
```

## Quick Start

### 1. Prepare Your System Package

Define your topology and deployment settings in your `System` executable Swift package (for example `./Server`) and choose the executable product (for example `AuraSystem`).

### 2. Preview Deployment

```bash
trebuchet deploy ./Server --product AuraSystem --provider aws --region us-east-1 --dry-run --verbose
```

Output:
```
Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Dry run - would deploy:
  Provider: aws
  Region: us-east-1
  State Table: my-game-server-actor-state
  Namespace: my-game-server

  Actor: GameRoom
    Memory: 1024 MB
    Timeout: 30s
    Isolated: false
```

### 3. Deploy

```bash
trebuchet deploy ./Server --product AuraSystem --provider aws --region us-east-1
```

Output:
```
Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Building for Lambda (arm64)...
  ✓ Package built (14.2 MB)

Deploying to AWS...
  ✓ Lambda: arn:aws:lambda:us-east-1:123456789012:function:my-game-actors
  ✓ API Gateway: https://abc123.execute-api.us-east-1.amazonaws.com
  ✓ DynamoDB: my-game-server-actor-state
  ✓ CloudMap: my-game-server namespace

Ready! Actors can discover each other automatically.
```

## AWS Resources Created

The deployment creates:

| Resource | Purpose |
|----------|---------|
| Lambda Function | Hosts your actors |
| Lambda Function URL | HTTP endpoint for invocations |
| DynamoDB Table | Actor state persistence |
| CloudMap Namespace | Service discovery |
| IAM Role | Lambda execution permissions |
| CloudWatch Log Group | Logging |

## Invoking Actors

### From External Clients

```swift
import Trebuchet

let client = TrebuchetClient(transport: .https(
    host: "abc123.execute-api.us-east-1.amazonaws.com"
))
try await client.connect()

let room = try client.resolve(GameRoom.self, id: "game-room")
let state = try await room.join(player: me)
```

### From Other Lambda Functions

```swift
import TrebuchetAWS

let client = TrebuchetCloudClient.aws(
    region: "us-east-1",
    namespace: "my-game-server"
)

let lobby = try await client.resolve(Lobby.self, id: "lobby")
let players = try await lobby.getPlayers()
```

## Configuration Options

### Actor Configuration

```yaml
actors:
  GameRoom:
    memory: 1024        # Memory in MB (128-10240)
    timeout: 60         # Timeout in seconds (1-900)
    stateful: true      # Enable state persistence
    isolated: true      # Run in dedicated Lambda
    environment:        # Environment variables
      LOG_LEVEL: debug
```

### Environment Overrides

```yaml
environments:
  production:
    region: us-west-2
    memory: 2048
  staging:
    region: us-east-1
```

Deploy to a specific environment:

```bash
trebuchet deploy --environment production
```

## Managing Deployments

### Check Status

```bash
trebuchet status --verbose
```

### Undeploy

```bash
trebuchet undeploy
```

## Terraform Customization

The generated Terraform is in `.trebuchet/terraform/`. You can customize it:

```bash
# View generated Terraform
cat .trebuchet/terraform/main.tf

# Apply with custom variables
cd .trebuchet/terraform
terraform apply -var="lambda_memory=2048"
```

## VPC Configuration

For actors that need VPC access (e.g., RDS, ElastiCache):

```hcl
# terraform.tfvars
vpc_id = "vpc-12345678"
subnet_ids = ["subnet-a1b2c3d4", "subnet-e5f6g7h8"]
security_group_ids = ["sg-12345678"]
```

## Cost Considerations

AWS Lambda pricing is based on:
- **Requests**: $0.20 per 1M requests
- **Duration**: $0.0000166667 per GB-second

DynamoDB uses on-demand pricing:
- **Read**: $0.25 per million reads
- **Write**: $1.25 per million writes

## See Also

- <doc:AWSConfiguration>
- ``AWSProvider``
- ``DynamoDBStateStore``
- ``CloudMapRegistry``
