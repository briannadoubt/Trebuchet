# Local Development

Run your distributed actors locally with automatic dependency management.

## Overview

The `trebuchet dev` command provides a complete local development environment for your distributed actors. It automatically discovers actors in your project, manages required dependencies like databases, and runs a local server for testing.

## Basic Usage

Start a local development server:

```bash
trebuchet dev --port 8080
```

The dev command:
- Discovers all `@Trebuchet` actors in your project
- Analyzes and copies type dependencies
- **Automatically starts required Docker containers** (databases, caches, etc.)
- Builds and runs a local HTTP server
- Exposes actors at `http://localhost:8080/invoke`
- Provides health check at `http://localhost:8080/health`

## Automatic Dependency Management

Trebuchet automatically detects and starts Docker containers for services your actors need based on your configuration.

### Auto-Detected Dependencies

When you configure a state store in `trebuchet.yaml`, the CLI automatically starts the appropriate container:

```yaml
name: my-app
state:
  type: surrealdb  # Auto-starts SurrealDB container
```

Supported auto-detection:

| State Store Type | Container | Port | Credentials |
|-----------------|-----------|------|-------------|
| `surrealdb` | `surrealdb/surrealdb:latest` | 8000 | root/root |
| `postgresql` | `postgres:16-alpine` | 5432 | trebuchet/trebuchet |
| `dynamodb` | `localstack/localstack:3.0` | 4566 | N/A |

### Custom Dependencies

Declare additional dependencies in your `trebuchet.yaml`:

```yaml
name: my-app
dependencies:
  - name: redis
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      port: 6379
      interval: 2
      retries: 10

  - name: meilisearch
    image: getmeili/meilisearch:latest
    ports:
      - "7700:7700"
    environment:
      MEILI_ENV: development
    healthcheck:
      url: http://localhost:7700/health
      interval: 2
      retries: 15
```

### Dependency Configuration

Each dependency supports:

- **name** (required): Unique identifier for the container
- **image** (required): Docker image to use
- **ports**: Port mappings in `host:container` format
- **command**: Command arguments to pass to the container
- **environment**: Environment variables as key-value pairs
- **healthcheck**: Health check configuration
- **volumes**: Volume mounts in `host:container` format

### Health Checks

Health checks ensure containers are ready before starting your actors:

```yaml
dependencies:
  - name: postgres
    image: postgres:16-alpine
    healthcheck:
      port: 5432          # TCP port check
      interval: 2         # Check every 2 seconds
      retries: 15         # Max 15 attempts

  - name: api-service
    image: my-api:latest
    healthcheck:
      url: http://localhost:8080/health  # HTTP endpoint check
      interval: 3
      retries: 20
```

Health check types:
- **port**: TCP connectivity check on localhost
- **url**: HTTP GET request (expects 2xx response)

### Container Lifecycle

Containers are automatically managed throughout the dev session:

1. **Startup**: Containers start before the dev server
2. **Health Checking**: Waits for containers to be ready
3. **Port Conflict Detection**: Fails early if ports are in use
4. **Graceful Shutdown**: Stops containers on exit or Ctrl+C

Container naming: `trebuchet-{projectName}-{depName}`

### Skipping Dependency Management

To run without Docker containers:

```bash
trebuchet dev --no-deps
```

This is useful when:
- You're managing dependencies yourself
- Running on systems without Docker
- Testing without external services

## Command Options

### Port and Host

```bash
# Custom port
trebuchet dev --port 3000

# Bind to all interfaces
trebuchet dev --host 0.0.0.0 --port 8080
```

### Verbose Output

```bash
trebuchet dev --verbose
```

Shows:
- Dependency detection and resolution
- Docker pull and container startup
- Health check attempts
- Detailed build output

### Using Local Trebuchet

Develop against a local Trebuchet checkout:

```bash
trebuchet dev --local ~/dev/Trebuchet
```

## Example Workflow

Complete local development setup:

```yaml
# trebuchet.yaml
name: game-server
state:
  type: surrealdb

dependencies:
  - name: redis
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      port: 6379
```

```bash
# Start development environment
trebuchet dev --verbose

# Output:
# Analyzing dependencies...
#   Detected state store: surrealdb
#   Custom dependencies: redis
#
# Starting dependencies...
#   ✓ surrealdb ready
#     └─ localhost:8000
#   ✓ redis ready
#     └─ localhost:6379
#
# Building actors...
# Starting server on localhost:8080...
# Ready! Press Ctrl+C to stop.
```

Press Ctrl+C to cleanly stop the server and all containers.

## Troubleshooting

### Docker Not Available

If Docker is not installed or running:

```
Docker is not available. Skipping dependency startup.
Install Docker to enable automatic dependency management.
```

Install Docker Desktop or Docker Engine to use dependency management.

### Port Conflicts

If a required port is already in use:

```
Port 8000 is already in use (needed by surrealdb).
Stop the conflicting process or change the port in trebuchet.yaml.
```

Change the port mapping in your configuration:

```yaml
dependencies:
  - name: surrealdb
    image: surrealdb/surrealdb:latest
    ports:
      - "9000:8000"  # Use port 9000 on host instead
```

### Health Check Failures

If a container fails to become ready:

```
surrealdb failed to become ready after 15 attempts.
Check if the service starts correctly with 'docker run' manually.
```

Try starting the container manually to diagnose:

```bash
docker run -p 8000:8000 surrealdb/surrealdb:latest start --log info memory
```

Adjust health check settings if the service needs more time:

```yaml
healthcheck:
  port: 8000
  interval: 5      # Longer interval
  retries: 30      # More retries
```

## See Also

- <doc:GettingStarted> - Create your first distributed actors
- <doc:CloudDeployment/CloudDeploymentOverview> - Deploy to production
- <doc:CloudDeployment/PostgreSQLConfiguration> - PostgreSQL state storage
