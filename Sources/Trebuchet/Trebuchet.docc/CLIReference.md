# Trebuchet CLI Reference

Complete reference for the `trebuchet` command-line interface.

## Overview

The `trebuchet` CLI provides tools for developing, deploying, and managing distributed actors. It supports local development servers, cloud deployment, server generation, and Swift Package Command Plugin generation.

## Commands

### init

Initialize a new Trebuchet configuration file.

```bash
trebuchet init --name my-project --provider aws
```

**Options:**
- `--name` - Project name (required)
- `--provider` - Cloud provider (`aws`, `fly`, `gcp`, `azure`)
- `--region` - Default deployment region

**Generates:** `trebuchet.yaml` configuration file with default settings

**Example Output:**
```yaml
name: my-project
version: "1"

defaults:
  provider: aws
  region: us-east-1
  memory: 512
  timeout: 30

actors: {}

commands:
  runLocally:
    title: "Run Locally"
    script: trebuchet dev
```

### dev

Run actors locally for development.

```bash
trebuchet dev --port 8080 --host localhost --verbose
```

**Options:**
- `--port` - Server port (default: 8080)
- `--host` - Server host (default: localhost)
- `--verbose` / `-v` - Enable verbose output
- `--local` - Path to local Trebuchet for development

**Behavior:**
1. Discovers actors in your codebase using SwiftSyntax
2. Generates a local development server package
3. Builds and runs the server
4. Exposes actors over WebSocket

**Server Output:**
```
Starting local development server...
Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Building server...
✓ Build succeeded

Server running on ws://localhost:8080
Dynamic actor creation enabled
Press Ctrl+C to stop
```

### deploy

Deploy actors to a cloud provider.

```bash
trebuchet deploy --provider aws --region us-east-1
```

**Options:**
- `--provider` - Cloud provider (`aws`, `fly`, `gcp`, `azure`)
- `--region` - Deployment region
- `--dry-run` - Preview deployment without executing
- `--verbose` / `-v` - Enable verbose output

**Process:**
1. Discovers actors in your codebase
2. Cross-compiles for target platform (e.g., arm64 for Lambda)
3. Generates infrastructure configuration (Terraform for AWS)
4. Deploys actors and supporting services

### status

Check deployment status.

```bash
trebuchet status
```

Shows current deployment information including:
- Deployed actors
- Cloud provider and region
- Infrastructure resources
- Endpoint URLs

### undeploy

Remove deployed infrastructure.

```bash
trebuchet undeploy
```

**Warning:** This command destroys cloud resources. Use with caution.

### generate server

Generate a standalone server package.

```bash
trebuchet generate server --output ./my-server
```

**Options:**
- `--output` - Output directory (default: current directory)
- `--config` - Path to `trebuchet.yaml` (default: `./trebuchet.yaml`)
- `--verbose` / `-v` - Enable verbose output

**Generates:**
- `Package.swift` - Swift Package manifest
- `Sources/` - Server source code
- `README.md` - Usage instructions

**Use Cases:**
- Customizing server deployment
- Integrating with existing infrastructure
- Version control for server code

### generate commands

Generate Swift Package Command Plugins from `trebuchet.yaml` commands.

```bash
trebuchet generate commands --output . --verbose
```

**Options:**
- `--output` - Output directory for plugins (default: current directory)
- `--config` - Path to `trebuchet.yaml` (default: `./trebuchet.yaml`)
- `--verbose` / `-v` - Enable verbose output
- `--force` - Force regeneration even if plugins exist

**Process:**
1. Reads `commands` section from `trebuchet.yaml`
2. Generates plugin targets in `Plugins/` directory
3. Creates `Package.swift` integration snippet

**Example Configuration:**
```yaml
commands:
  runLocally:
    title: "Run Locally"
    script: trebuchet dev
  deployStaging:
    title: "Deploy Staging"
    script: trebuchet deploy --environment staging --verbose
  runTests:
    title: "Run Tests"
    script: swift test
```

**Generated Structure:**
```
Plugins/
├── RunLocallyPlugin/
│   └── plugin.swift
├── DeployStagingPlugin/
│   └── plugin.swift
└── RunTestsPlugin/
    └── plugin.swift
```

**Usage After Generation:**

Add the generated plugins to your `Package.swift`:

```swift
// Products
.plugin(
    name: "RunLocallyPlugin",
    targets: ["RunLocallyPlugin"]
),

// Targets
.plugin(
    name: "RunLocallyPlugin",
    capability: .command(
        intent: .custom(
            verb: "runLocally",
            description: "Run Locally"
        ),
        permissions: [
            .writeToPackageDirectory(
                reason: "Execute command: trebuchet dev"
            ),
        ]
    )
),
```

Run commands with:
```bash
swift package runLocally
swift package deployStaging
swift package runTests
```

**Command Plugin Features:**
- Inherits stdio for interactive use
- Sets `TREBUCHET_PACKAGE_DIR` environment variable
- Proper exit code propagation
- Works in both SPM and Xcode workflows

### run

Execute a command defined in `trebuchet.yaml`.

```bash
trebuchet run runLocally
```

**Arguments:**
- Command verb (as defined in `trebuchet.yaml` commands section)

**Options:**
- `--config` - Path to `trebuchet.yaml` (default: `./trebuchet.yaml`)

**Behavior:**
- Executes the shell script associated with the command
- Passes through stdio for interactive use
- Sets `TREBUCHET_PACKAGE_DIR` environment variable
- Propagates exit codes

**Example:**
```bash
# With this in trebuchet.yaml:
# commands:
#   runLocally:
#     title: "Run Locally"
#     script: trebuchet dev --verbose

trebuchet run runLocally
# Equivalent to: trebuchet dev --verbose
```

**Error Handling:**
```bash
$ trebuchet run unknownCommand
Unknown command: 'unknownCommand'

Available commands:
  runLocally (Run Locally) → trebuchet dev
  deployStaging (Deploy Staging) → trebuchet deploy --environment staging
```

## Configuration File

The `trebuchet.yaml` file configures your project:

### Basic Structure

```yaml
name: my-project
version: "1"

# Optional: Customize package generation
packageName: "MyCustomServer"
outputDirectory: "TrebuchetServer"

# Default settings for all actors
defaults:
  provider: aws
  region: us-east-1
  memory: 512
  timeout: 30

# Actor-specific configuration
actors:
  GameRoom:
    memory: 1024
    stateful: true
  Lobby:
    memory: 256

# State storage configuration
state:
  type: dynamodb
  tableName: my-project-state

# Service discovery configuration
discovery:
  type: cloudmap
  namespace: my-project

# Custom commands (generates plugins)
commands:
  runLocally:
    title: "Run Locally"
    script: trebuchet dev
  deployStaging:
    title: "Deploy Staging"
    script: trebuchet deploy --environment staging
```

### Commands Section

The `commands` section defines custom commands that can:
1. Be executed with `trebuchet run <verb>`
2. Generate Swift Package Command Plugins with `trebuchet generate commands`

**Command Definition:**
- **Key (verb):** Used for CLI invocation (e.g., `runLocally`)
- **title:** Human-readable display name
- **script:** Shell command to execute

**Verb Naming:**
- Use camelCase (e.g., `runLocally`, `deployStaging`)
- Must be valid Swift identifiers
- Converted to plugin target names (e.g., `RunLocallyPlugin`)

## Environment Variables

The CLI and generated plugins set:

- `TREBUCHET_PACKAGE_DIR` - Path to the package root directory

## Common Workflows

### Local Development

```bash
# Initialize project
trebuchet init --name my-game --provider aws

# Start development server
trebuchet dev --verbose

# Or use a custom command
trebuchet run runLocally
```

### Cloud Deployment

```bash
# Preview deployment
trebuchet deploy --dry-run

# Deploy to AWS
trebuchet deploy --provider aws --region us-east-1

# Check status
trebuchet status

# Later, remove infrastructure
trebuchet undeploy
```

### Using Command Plugins

```bash
# Generate plugins from trebuchet.yaml
trebuchet generate commands

# Add generated plugins to Package.swift
# (Use the provided snippet)

# Run via Swift Package Manager
swift package runLocally
swift package deployStaging
```

### Standalone Server

```bash
# Generate server package
trebuchet generate server --output ./server

# Customize and deploy
cd server
# Edit sources as needed
swift build -c release
./deploy.sh
```

## Tips

### Verbose Output

Use `--verbose` or `-v` for detailed output:
```bash
trebuchet dev --verbose
trebuchet deploy --verbose
trebuchet generate commands --verbose
```

### Custom Configuration

Specify a custom config file path:
```bash
trebuchet deploy --config ./config/production.yaml
trebuchet run runLocally --config ./config/development.yaml
```

### Dry Run Deployments

Preview changes before deploying:
```bash
trebuchet deploy --dry-run --verbose
```

### Local Trebuchet Development

Test CLI changes with `--local`:
```bash
trebuchet dev --local /path/to/trebuchet/repo
```

## See Also

- <doc:GettingStarted> - Getting started with Trebuchet
- <doc:CloudDeploymentOverview> - Cloud deployment overview
- <doc:DeployingToAWS> - AWS-specific deployment guide
