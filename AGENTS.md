# Trebuchet Agent Notes

## Local Dependency Orchestration

- `compote` is a host-installed CLI tool and must not be added as a SwiftPM dependency.
- On macOS, local dependency orchestration defaults to `compote` from `PATH`; do not auto-fallback to Docker.
- Explicit `--runtime docker` on macOS is allowed when requested.
- Ensure `socat` is installed on macOS when compose manifests expose ports (Compote relies on it for port forwarding).
- On non-macOS platforms, use Docker (`docker compose` or `docker-compose`) for dependency orchestration.
- Keep dependency manifests in compose-format files (`compote.yml`, `docker-compose.yml`, or `compose.yml`) when custom service networks are needed.

## Pull Request Workflow

- Agents are allowed to publish changes by creating branches, pushing to `origin`, and opening pull requests with `gh pr create`.
- If work starts on a detached `HEAD`, create a named branch before pushing.
- Prefer one focused PR per task; update the existing PR with additional commits when continuing the same task.
- After opening a PR, verify title/body/labels and use `gh pr edit` to correct metadata when needed.
- Apply `codex` and `codex-automation` labels when those labels exist in the repository; otherwise use the closest existing label.
