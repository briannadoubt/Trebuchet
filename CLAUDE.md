# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the package
swift build

# Run tests
swift test

# Run a specific test
swift test --filter TrebucheTests.testName
```

## Architecture

Trebuche is a Swift 6.2 library package with a standard SPM structure:
- `Sources/Trebuche/` - Library source code
- `Tests/TrebucheTests/` - Tests using Swift Testing framework (`import Testing`)
