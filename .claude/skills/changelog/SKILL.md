---
name: changelog
description: Update CHANGELOG.md with new entries following Keep a Changelog format
---

Help update the CHANGELOG.md file with new entries:

## Workflow

1. Read the current CHANGELOG.md:
   ```bash
   cat /Users/bri/dev/Trebuchet/CHANGELOG.md | head -50
   ```

2. Show the last release tag:
   ```bash
   cd /Users/bri/dev/Trebuchet && git describe --tags --abbrev=0 2>/dev/null || echo "No tags yet"
   ```

3. Get unreleased commits:
   ```bash
   cd /Users/bri/dev/Trebuchet && git log $(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)..HEAD --oneline --no-merges
   ```

4. For each significant commit, ask the user to categorize:
   - **Added**: New features
   - **Changed**: Changes to existing functionality
   - **Deprecated**: Soon-to-be removed features
   - **Removed**: Removed features
   - **Fixed**: Bug fixes
   - **Security**: Security fixes

5. Ask the user for user-friendly descriptions of each change

6. Update CHANGELOG.md with new entries under `[Unreleased]` section

7. Ask: "Do you want to prepare this for a release?"
   - If yes: Create new version section with today's date, move entries from [Unreleased]
   - If no: Leave entries under [Unreleased]

## Format

Follow the Keep a Changelog standard:

```markdown
## [Unreleased]

### Added
- New feature description

### Fixed
- Bug fix description

## [0.4.0] - 2025-01-15

### Added
- Previous features
```

## Guidelines

- Use present tense ("Add feature" not "Added feature")
- Focus on user impact, not implementation details
- Keep entries concise but meaningful
- Link to issues/PRs when applicable
