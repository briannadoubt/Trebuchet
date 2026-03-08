# Xcode Project Support (System-First)

## Overview

Trebuchet's Xcode integration is **System-package first**:

- Your app remains in an Xcode project (`.xcodeproj`)
- Your server remains a Swift package (commonly `./Server`)
- Trebuchet starts/stops the System executable for your Run action
- No generated source-copy server harness is required

## Canonical Workflow

### 1. Verify your System package

Your server package must contain an executable with `@main` conforming to `System`:

```swift
@main
struct AuraSystem: System {
    var topology: some Topology { ... }
}
```

### 2. Wire Xcode once

```bash
cd /path/to/AppRoot

trebuchet xcode setup \
  --project-path . \
  --system-path ./Server \
  --product AuraSystem \
  --host 127.0.0.1 \
  --port 8080
```

### 3. Run app from managed scheme

This creates/updates:

- Managed scheme: `<BaseScheme>+Trebuchet` (or in-place when requested)
- Start script: `.trebuchet-xcode/session-start.sh`
- Stop script: `.trebuchet-xcode/session-stop.sh`

The managed scheme:

- pre-run: `trebuchet xcode session start ...`
- post-run: `trebuchet xcode session stop ...`

## Session Management

Manual controls:

```bash
trebuchet xcode session start --project-path . --system-path ./Server --product AuraSystem
trebuchet xcode session status --project-path .
trebuchet xcode session stop --project-path .
```

Integration status:

```bash
trebuchet xcode status --project-path .
```

Teardown:

```bash
trebuchet xcode teardown --project-path .
```

## Requirements

- A valid Swift package at `--system-path` (must contain `Package.swift`)
- A System executable product (`--product`) or a uniquely resolvable one
- macOS: Compote available for dependency orchestration in auto mode
- non-macOS: Docker Compose available for dependency orchestration in auto mode

## Migration from Legacy `.trebuchet` Source-Copy Flow

If you previously used generated `.trebuchet` server sources:

1. Move server behavior to a real System package (`./Server`)
2. Use `trebuchet dev ./Server --product <SystemExecutable>`
3. Re-run `trebuchet xcode setup --system-path ./Server --product <SystemExecutable>`
4. Stop relying on generated server sources as an execution path

Use `trebuchet doctor` for migration hints in existing projects.
