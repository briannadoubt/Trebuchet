---
name: release
description: Create a new Trebuchet release tag following semantic versioning (without 'v' prefix)
---

Create a new release for Trebuchet:

## Pre-Release Checks

1. Check for uncommitted changes:
   ```bash
   cd /Users/bri/dev/Trebuchet && git status --short
   ```
   If there are uncommitted changes, ask the user if they want to proceed.

2. Show current version:
   ```bash
   cd /Users/bri/dev/Trebuchet && git describe --tags --abbrev=0 2>/dev/null || echo "No tags yet"
   ```

3. Show recent commits:
   ```bash
   cd /Users/bri/dev/Trebuchet && git log --oneline -10
   ```

## Release Workflow

1. Ask the user: "What version number for this release?"
   - Format: MAJOR.MINOR.PATCH (e.g., `0.4.0`)
   - **CRITICAL**: NO 'v' prefix! Use `0.4.0` NOT `v0.4.0`

2. Validate the version format matches `\d+\.\d+\.\d+`

3. Ask the user: "What's the release message?"

4. Create the annotated tag:
   ```bash
   cd /Users/bri/dev/Trebuchet && git tag -a VERSION -m "MESSAGE"
   ```

5. Confirm with user before pushing

6. Push the tag:
   ```bash
   cd /Users/bri/dev/Trebuchet && git push origin VERSION
   ```

## Version Guidelines

- **MAJOR**: Breaking API changes
- **MINOR**: New features, backwards compatible
- **PATCH**: Bug fixes, backwards compatible

## Important Notes

- Trebuchet uses semantic versioning **WITHOUT** 'v' prefix
- Verify CHANGELOG.md is updated before releasing
- Ensure all tests pass before creating a release
