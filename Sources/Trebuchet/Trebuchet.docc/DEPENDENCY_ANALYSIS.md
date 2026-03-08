# Legacy Dependency Analysis (Historical)

## Status

The old Xcode source-copy workflow (which analyzed and copied actor type dependencies into `.trebuchet`) is now a **legacy path**.

Trebuchet's recommended architecture is **System-first**:

- Keep server code in a Swift package (for example `./Server`)
- Run local dev with:

```bash
trebuchet dev ./Server --product <SystemExecutable>
```

- Use Xcode integration with explicit server package wiring:

```bash
trebuchet xcode setup --project-path . --system-path ./Server --product <SystemExecutable>
```

## Why this changed

System-first removes duplicate execution models and keeps one source of truth for:

- topology
- deployments
- actor registration
- runtime startup behavior

## Migration guidance

1. Create or adopt a server Swift package containing your `@main ...: System` executable.
2. Move any generated-runner-only behavior into the System package.
3. Rewire Xcode setup/session commands to use `--system-path` and `--product`.
4. Treat `.trebuchet` as ignorable artifact, not an execution dependency.

For quick project checks, run:

```bash
trebuchet doctor
```
