# Trebuchet Agent Notes

## Local Dependency Orchestration

- `compote` is a host-installed CLI tool and must not be added as a SwiftPM dependency.
- On macOS, local dependency orchestration defaults to `compote` from `PATH`; do not auto-fallback to Docker.
- Explicit `--runtime docker` on macOS is allowed when requested.
- Ensure `socat` is installed on macOS when compose manifests expose ports (Compote relies on it for port forwarding).
- On non-macOS platforms, use Docker (`docker compose` or `docker-compose`) for dependency orchestration.
- Keep dependency manifests in compose-format files (`compote.yml`, `docker-compose.yml`, or `compose.yml`) when custom service networks are needed.
