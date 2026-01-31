# Xcode Project Support for Trebuchet CLI

## Overview

Trebuchet CLI commands now support both Swift Package Manager projects and Xcode projects. When an Xcode project is detected (by the presence of `.xcodeproj` or `.xcworkspace` files), the CLI automatically adapts its behavior to copy actor source files instead of trying to reference the parent directory as a Swift Package.

## Changes Made

### New Utility: ProjectDetector

Created `Sources/TrebuchetCLI/Utilities/ProjectDetector.swift` to provide:

- **Xcode project detection**: Checks for `.xcodeproj` or `.xcworkspace` files
- **Package name extraction**: Reads package name from `Package.swift` if it exists
- **Source file copying**: Copies actor source files to target directories
- **Package manifest generation**: Creates appropriate `Package.swift` manifests based on project type

### Updated Commands

#### 1. `trebuchet dev` (DevCommand.swift)

**Before:**
```swift
.package(path: ".."),  // Always referenced parent as package
```

**After:**
- Detects Xcode projects vs Swift Packages
- For Xcode projects:
  - Skips `swift build` step (not applicable)
  - Copies actor source files to `.trebuchet/Sources/ActorSources/`
  - Generates standalone `Package.swift` without parent dependency
  - Creates `ActorSources` module containing copied files
- For Swift Packages:
  - Maintains existing behavior with `.package(path: "..")`

#### 2. `trebuchet generate server` (ServerGenerator.swift)

**Before:**
```swift
dependencies: [
    .package(path: "\(projectPath)"),  // Always referenced parent
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", ...)
]
```

**After:**
- Uses `ProjectDetector` to determine project type
- For Xcode projects:
  - Copies actor sources to generated server package
  - Creates `ActorSources` module
  - Generates `Package.swift` without parent dependency
- For Swift Packages:
  - Maintains existing package reference behavior

#### 3. Lambda Bootstrap (BootstrapGenerator.swift)

**Before:**
```swift
.package(path: "../.."),  // Main project
```

**After:**
- Accepts `projectPath` parameter
- Uses `ProjectDetector` to adapt package manifest
- For Xcode projects:
  - Includes `ActorSources` target in generated package
  - Omits parent package dependency
- For Swift Packages:
  - Maintains package reference with proper module name

## How It Works

### For Swift Package Projects

```
MyProject/
├── Package.swift            ← Detected
├── Sources/
│   └── MyActors/
│       └── GameRoom.swift
```

Generated `.trebuchet/Package.swift`:
```swift
dependencies: [
    .package(path: ".."),  // References parent package
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", ...)
]
```

### For Xcode Projects

```
Aura/
├── Aura.xcodeproj/         ← Detected
├── Aura/
│   └── Actors/
│       └── GameRoom.swift
```

Generated `.trebuchet/Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", ...)
    // NO parent package reference
],
targets: [
    .target(
        name: "ActorSources",  // Copied actor files
        dependencies: ["Trebuchet"]
    ),
    .executableTarget(
        name: "LocalRunner",
        dependencies: [
            "Trebuchet",
            "TrebuchetCloud",
            "ActorSources"  // Uses copied sources
        ]
    )
]
```

## Affected Commands

✅ **trebuchet dev** - Fully supported
✅ **trebuchet generate server** - Fully supported
✅ **trebuchet deploy --provider fly** - Supported (uses ServerGenerator)
⚠️ **trebuchet deploy --provider aws** - Partial support (Lambda deployment via Docker may need additional work)

## Automatic Dependency Analysis 🎉

The CLI now **automatically analyzes and copies all type dependencies**!

When you use custom types in your actor methods:

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: PlayerInfo) -> RoomState
}
```

The CLI will:
1. **Extract types** from method signatures (`PlayerInfo`, `RoomState`)
2. **Find files** defining those types
3. **Recursively analyze** those files for their dependencies
4. **Copy everything** needed to build your actors

See [Dependency Analysis](DEPENDENCY_ANALYSIS.md) for complete details.

### What This Means

✅ **Complex type hierarchies** - Automatically resolved
✅ **Nested dependencies** - Recursively discovered
✅ **Generic types** - `Array<Player>`, `Dictionary<UUID, Stats>` handled correctly
✅ **Transitive dependencies** - If `PlayerInfo` uses `GameStatus`, both are copied

### Example

Your project:
```
Aura/
├── Actors/
│   └── GameRoom.swift      # Uses PlayerInfo, RoomState
├── Models/
│   ├── PlayerInfo.swift    # Uses GameStatus
│   ├── RoomState.swift     # Uses PlayerInfo
│   └── GameStatus.swift
```

Files copied automatically:
```
.trebuchet/Sources/ActorSources/
├── GameRoom.swift
├── PlayerInfo.swift
├── RoomState.swift
└── GameStatus.swift
```

## Limitations

### Current Implementation

### Edge Cases

While dependency analysis handles most cases, there are some edge cases:

1. **Same-name types** - If multiple files define `Player` in different contexts, only one is copied
2. **Protocol conformances** - `any Playable` protocols are detected, but all implementations must be discoverable
3. **Conditional compilation** - Types hidden in `#if DEBUG` blocks may not be found
4. **Cross-package dependencies** - Types from other SPM packages are assumed to be in dependencies

### Workarounds

For the rare edge cases:

1. **Add a Package.swift** to your Xcode project for maximum compatibility:
   ```swift
   // swift-tools-version: 6.0
   import PackageDescription

   let package = Package(
       name: "Aura",
       platforms: [.iOS(.v17), .macOS(.v14)],
       products: [
           .library(name: "Aura", targets: ["Aura"])
       ],
       targets: [
           .target(name: "Aura")
       ]
   )
   ```

2. **Use verbose mode** to see what's being copied:
   ```bash
   trebuchet dev --verbose
   ```

3. **Check the generated sources** to ensure all needed files were copied:
   ```bash
   ls .trebuchet/Sources/ActorSources/
   ```

## Testing

All existing tests pass with the new implementation:

```bash
swift test --filter TrebuchetCLITests
# Test run with 34 tests in 5 suites passed
```

## Example Usage

### Xcode Project

```bash
cd /path/to/Aura  # Xcode project with .xcodeproj
trebuchet dev

# Output:
# Starting local development server...
# Detected Xcode project, will copy actor sources...
# Found actors:
#   • GameRoom
# ✓ Copied 1 actor source file(s)
# ✓ Runner generated
# Starting server on localhost:8080...
```

### Swift Package

```bash
cd /path/to/MyPackage  # Has Package.swift
trebuchet dev

# Output:
# Starting local development server...
# Building project...
# ✓ Build succeeded
# Found actors:
#   • GameRoom
# ✓ Runner generated
# Starting server on localhost:8080...
```

## Future Enhancements

Potential improvements for more robust Xcode project support:

1. **Dependency analysis** - Parse Swift files to detect imported types and copy dependency files
2. **Module map generation** - Create proper module maps for complex Xcode project structures
3. **Framework linking** - Build Xcode project and link against compiled frameworks
4. **Workspace support** - Handle `.xcworkspace` with multiple projects

## Related Files

- `Sources/TrebuchetCLI/Utilities/ProjectDetector.swift` - Core detection and utility logic
- `Sources/TrebuchetCLI/Commands/DevCommand.swift` - Dev server implementation
- `Sources/TrebuchetCLI/Build/ServerGenerator.swift` - Standalone server generation
- `Sources/TrebuchetCLI/Build/BootstrapGenerator.swift` - Lambda bootstrap generation
- `Tests/TrebuchetCLITests/TrebuchetCLITests.swift` - Test coverage
