# Testing Xcode Project Support

This demo demonstrates Trebuchet CLI's Xcode project support with automatic dependency analysis.

## Setup

The demo has been configured as follows:

```
TrebuchetDemo/
├── TrebuchetDemo.xcodeproj          ← Xcode project
├── TrebuchetDemo/
│   ├── Actors/                      ← Actors moved here
│   │   ├── TodoList.swift          ← Distributed actor
│   │   ├── TodoListStreaming.swift ← Distributed actor
│   │   └── TodoItem.swift          ← Type used by actors
│   └── Views/                       ← SwiftUI views
└── Shared/                          ← Original SPM package (for comparison)
```

## Testing Xcode Project Support

### 1. Build the CLI

```bash
cd /Users/bri/dev/Trebuchet
swift build --product trebuchet
```

### 2. Run from Xcode Project

```bash
cd TrebuchetDemo
../build/debug/trebuchet dev --verbose
```

### Expected Output

```
Starting local development server...

Detected Xcode project, will copy actor sources...

Found actors:
  • TodoList
  • TodoListStreaming

  Analyzing dependencies...
  Found 3 required file(s)
  Copied: TodoList.swift
  Copied: TodoListStreaming.swift
  Copied: TodoItem.swift
✓ Copied 3 source files (including dependencies)

✓ Runner generated

Starting server on localhost:8080...
```

### What the CLI Does

1. **Detects Xcode Project**
   - Finds `TrebuchetDemo.xcodeproj`
   - Switches to Xcode project mode

2. **Discovers Actors**
   - Scans `TrebuchetDemo/` directory for Swift files
   - Finds `@Trebuchet` distributed actors
   - Discovers: `TodoList` and `TodoListStreaming`

3. **Analyzes Dependencies**
   - Parses actor method signatures
   - `TodoList` uses `TodoItem` → dependency found
   - `TodoListStreaming` has no custom dependencies

4. **Copies Files**
   - Copies only the 3 needed files to `.trebuchet/Sources/ActorSources/`
   - Does NOT copy unrelated files from the project

5. **Generates Server**
   - Creates `.trebuchet/Package.swift` without parent reference
   - Includes `ActorSources` module with copied files
   - Generates development server

6. **Starts Server**
   - Runs on `localhost:8080`
   - Exposes actors for remote access

## Verify Dependency Analysis

Check what was copied:

```bash
ls .trebuchet/Sources/ActorSources/
# Should show: TodoItem.swift  TodoList.swift  TodoListStreaming.swift
```

Check the generated package:

```bash
cat .trebuchet/Package.swift
# Should NOT have .package(path: "..")
# Should include ActorSources target
```

## Compare with Swift Package Mode

The `Shared/` directory is a Swift Package for comparison:

```bash
cd Shared
../../.build/debug/trebuchet dev --verbose
```

This uses the traditional SPM path (finds `Package.swift`).

## Expected Behavior Differences

| Aspect | Xcode Project | Swift Package |
|--------|--------------|---------------|
| **Detection** | Finds `.xcodeproj` | Finds `Package.swift` |
| **Build step** | Skipped | `swift build` runs |
| **Source copying** | Copies files to ActorSources | References parent package |
| **Dependency analysis** | Analyzes types, copies files | Uses package dependencies |
| **Package.swift** | Standalone, no parent | References parent with `.package(path: "..")` |

## Cleanup

```bash
rm -rf .trebuchet
```

## Troubleshooting

### "No distributed actors found"

- Check that actors are in `TrebuchetDemo/TrebuchetDemo/Actors/`
- Verify actors have `@Trebuchet` macro or `typealias ActorSystem = TrebuchetActorSystem`

### Build fails

- Ensure Trebuchet is properly linked as a dependency
- Check that all type dependencies are present

### Wrong files copied

- Verify dependency analysis is working
- Check verbose output for what was discovered
- Files should match actors + their dependencies only

## Success Criteria

✅ CLI detects `.xcodeproj`
✅ Finds 2 actors (TodoList, TodoListStreaming)
✅ Analyzes dependencies and finds TodoItem
✅ Copies exactly 3 files (not the whole project)
✅ Generates working server package
✅ Server starts successfully
✅ No cascade to unrelated Xcode project files
