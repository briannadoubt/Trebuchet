# Automatic Dependency Analysis for Xcode Projects

## Overview

The Trebuchet CLI now automatically analyzes and copies all type dependencies when working with Xcode projects. This means you don't have to manually track which files contain the types your actors use—the CLI does it for you!

## Granularity: Hybrid Approach

**Important:** The system uses a **hybrid approach**:
- 🗂️ **File-level copying** - Entire files are copied to preserve structure
- 🔍 **Symbol-level dependency analysis** - Only needed types are analyzed to prevent cascade

If a file contains multiple types:
```swift
// Models.swift
struct PlayerInfo: Codable { }      // Used by actor
struct RoomState: Codable { }       // Used by actor
struct UnrelatedType: Codable {     // NOT used by actor
    let analytics: AnalyticsEngine  // Has its own dependencies
}
```

The **entire `Models.swift` file is copied**, including `UnrelatedType`.

**BUT** - and this is critical - **only `PlayerInfo` and `RoomState`'s dependencies are analyzed**.

This means:
- ✅ `UnrelatedType` is copied (it's in the file)
- ✅ `AnalyticsEngine` is **NOT** analyzed or copied
- ✅ No cascade to analytics dependencies

See [CASCADE_PREVENTION.md](../../../DevelopmentDocs/CASCADE_PREVENTION.md) for detailed technical explanation.

### Why Hybrid Approach?

✅ **Preserves relationships** - Types in the same file often depend on each other
✅ **Handles extensions** - Extensions stay with their types
✅ **Simpler and reliable** - No risk of breaking internal dependencies
✅ **Respects organization** - Developers organize files intentionally

See [SYMBOL_LEVEL_EXTRACTION.md](../../../DevelopmentDocs/SYMBOL_LEVEL_EXTRACTION.md) for a detailed analysis of symbol-level extraction.

### Best Practice

Organize your code with **one type per file** for maximum precision:
```
Models/
├── PlayerInfo.swift      # ← Only copied if used
├── RoomState.swift       # ← Only copied if used
└── UnrelatedType.swift   # ← NOT copied
```

With one-type-per-file, file-level copying ≈ symbol-level extraction!

## How It Works

### 1. Actor Discovery
```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: PlayerInfo) -> RoomState
    distributed func updateScore(playerId: UUID, score: Int) throws
}
```

### 2. Type Extraction
The `DependencyAnalyzer` extracts all types from method signatures:

**From parameters:**
- `PlayerInfo`
- `UUID`
- `Int`

**From return types:**
- `RoomState`

**From generic types:**
- If you use `Array<PlayerInfo>`, it extracts both `Array` and `PlayerInfo`
- If you use `Dictionary<UUID, PlayerStats>`, it extracts `Dictionary`, `UUID`, and `PlayerStats`

### 3. Dependency Resolution

The analyzer then:
1. **Filters out standard types** (String, Int, Array, UUID, etc.)
2. **Searches your project** for files defining the remaining types
3. **Recursively analyzes** those files for their dependencies
4. **Copies all required files** to the generated server package

### Example Flow

Given this project structure:
```
Aura/
├── Aura.xcodeproj/
├── Aura/
│   ├── Actors/
│   │   └── GameRoom.swift        # Uses PlayerInfo, RoomState
│   ├── Models/
│   │   ├── PlayerInfo.swift      # Uses GameStatus
│   │   ├── RoomState.swift       # Uses PlayerInfo, GameStatus
│   │   └── GameStatus.swift      # enum, no dependencies
│   └── Network/
│       └── APIClient.swift        # Not used by actors
```

**Step 1: Analyze GameRoom.swift**
```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: PlayerInfo) -> RoomState
}
```
→ Needs: `PlayerInfo`, `RoomState`

**Step 2: Analyze PlayerInfo.swift**
```swift
struct PlayerInfo: Codable {
    let name: String
    let status: GameStatus  // ← New dependency!
}
```
→ Needs: `GameStatus`

**Step 3: Analyze RoomState.swift**
```swift
struct RoomState: Codable {
    let players: [PlayerInfo]
    let status: GameStatus
}
```
→ Needs: `PlayerInfo` (already found), `GameStatus`

**Step 4: Analyze GameStatus.swift**
```swift
enum GameStatus: String, Codable {
    case waiting, playing, finished
}
```
→ No custom dependencies

**Result: Files Copied**
```
.trebuchet/Sources/ActorSources/
├── GameRoom.swift
├── PlayerInfo.swift
├── RoomState.swift
└── GameStatus.swift
```

`APIClient.swift` is **NOT** copied because it's not used by any actor.

## Supported Type Patterns

### ✅ Simple Types
```swift
struct Player: Codable { }
class GameEngine { }
enum Status { }
```

### ✅ Generic Types
```swift
distributed func getPlayers() -> Array<Player>
distributed func getStats() -> Dictionary<UUID, PlayerStats>
distributed func getOptional() -> Optional<Player>
```
Extracts: `Player`, `PlayerStats`

### ✅ Nested Generics
```swift
distributed func complex() -> Dictionary<UUID, Array<PlayerInfo>>
```
Extracts: `PlayerInfo`

### ✅ Optional and Force-Unwrapped
```swift
distributed func get() -> Player?
distributed func getForce() -> Player!
```
Extracts: `Player`

### ✅ Namespaced Types
```swift
distributed func get() -> MyModule.Player
```
Extracts: `Player`

### ✅ Tuple Types
```swift
distributed func pair() -> (Player, RoomState)
```
Extracts: `Player`, `RoomState`

### ⚠️ Protocol Types
```swift
distributed func get() -> any Playable
```
Protocols are detected, but implementations must be in the same file or explicitly included.

## Smart Filtering

The analyzer automatically **excludes** standard types:

### Swift Standard Library
`String`, `Int`, `Double`, `Bool`, `Array`, `Dictionary`, `Set`, `Optional`, `Result`, etc.

### Foundation
`Data`, `Date`, `URL`, `UUID`, `Decimal`, etc.

### Distributed Actors
`DistributedActor`, `DistributedActorSystem`, etc.

### Trebuchet
`TrebuchetActorSystem`, `TrebuchetActorID`, `TrebuchetError`, etc.

### Swift Concurrency
`Task`, `AsyncStream`, `AsyncThrowingStream`, etc.

## Fallback Behavior

If dependency analysis fails for any reason (malformed Swift, I/O errors, etc.), the CLI automatically falls back to **simple mode**:

```
⚠️  Warning: Dependency analysis failed, copying actor files only
```

This ensures the command still works even if the analyzer encounters edge cases.

## Output Example

```bash
$ cd Aura
$ trebuchet dev --verbose

Starting local development server...
Detected Xcode project, will copy actor sources...
Found actors:
  • GameRoom

  Analyzing dependencies...
  Found 4 required file(s)
  Copied: GameRoom.swift
  Copied: PlayerInfo.swift
  Copied: RoomState.swift
  Copied: GameStatus.swift
✓ Copied 4 source files (including dependencies)
✓ Runner generated

Starting server on localhost:8080...
```

## Implementation Details

### Core Components

**`DependencyAnalyzer`** (`Sources/TrebuchetCLI/Discovery/DependencyAnalyzer.swift`)
- Main analysis engine
- Uses SwiftSyntax to parse files
- Maintains sets of required types and files

**`TypeDefinitionVisitor`**
- Visits Swift AST nodes
- Collects defined types (struct, class, enum, actor, typealias)

**`TypeUsageVisitor`**
- Visits identifier type references
- Extracts used type names

**`ProjectDetector.copyActorSources()`**
- Invokes `DependencyAnalyzer`
- Handles fallback on errors
- Provides progress output

### Algorithm

1. **Initialize** with actor metadata
2. **Extract** types from all method signatures
3. **Filter** out standard library types
4. **Search** all Swift files for type definitions
5. **Recurse** into found files for nested dependencies
6. **Deduplicate** and return final file set
7. **Copy** all required files to target

## Limitations & Edge Cases

### Current Limitations

1. **Same-name conflicts**: If two files define `Player` in different modules, only one is copied
2. **Cross-module imports**: Types from other SPM packages aren't copied (they're assumed to be dependencies)
3. **Dynamic types**: Runtime types like `any Equatable` may not resolve all implementations
4. **Conditional compilation**: `#if` blocks may hide dependencies

### Future Enhancements

- **Module awareness**: Track which module types come from
- **Import analysis**: Parse import statements to build dependency graph
- **Protocol implementations**: Find all types conforming to protocols
- **Extension detection**: Include extensions on copied types
- **Cross-package linking**: Handle multi-package Xcode workspaces

## Testing

The dependency analyzer is tested as part of the CLI test suite:

```bash
swift test --filter TrebuchetCLITests
# ✅ All 34 tests pass
```

For manual testing with complex dependencies:

```bash
# Create test project with nested dependencies
cd /path/to/test-project
trebuchet dev --verbose

# Check .trebuchet/Sources/ActorSources/ for copied files
ls .trebuchet/Sources/ActorSources/
```

## Comparison: Before vs After

### Before (Manual Dependency Management)

**Problem:** Only copies actor files
```
.trebuchet/Sources/ActorSources/
└── GameRoom.swift  ← Missing PlayerInfo, RoomState, GameStatus!
```

**Result:** Build fails
```
error: cannot find type 'PlayerInfo' in scope
error: cannot find type 'RoomState' in scope
```

**Manual fix:** You'd have to:
1. Read build errors
2. Find files defining those types
3. Manually copy them
4. Hope you didn't miss transitive dependencies

### After (Automatic Dependency Analysis)

**Automatic:** Analyzes and copies everything
```
.trebuchet/Sources/ActorSources/
├── GameRoom.swift
├── PlayerInfo.swift
├── RoomState.swift
└── GameStatus.swift
```

**Result:** Builds successfully ✅

## Advanced Example

### Complex Actor with Many Dependencies

```swift
// GameRoom.swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: PlayerInfo) -> RoomState
    distributed func updateScore(_ update: ScoreUpdate) throws -> PlayerStats
    distributed func getRankings() -> [Ranking]
    distributed func startMatch(config: MatchConfig) async throws -> Match
}

// PlayerInfo.swift - Depends on: GameStatus, PlayerStats
struct PlayerInfo: Codable {
    let id: UUID
    let name: String
    let stats: PlayerStats
    let status: GameStatus
}

// PlayerStats.swift - Depends on: Achievement
struct PlayerStats: Codable {
    let score: Int
    let achievements: [Achievement]
}

// Achievement.swift - No dependencies
enum Achievement: String, Codable {
    case firstWin, perfectGame, speedDemon
}

// GameStatus.swift - No dependencies
enum GameStatus: String, Codable {
    case waiting, playing, finished
}

// ScoreUpdate.swift - No dependencies
struct ScoreUpdate: Codable {
    let playerId: UUID
    let points: Int
}

// RoomState.swift - Depends on: PlayerInfo, GameStatus
struct RoomState: Codable {
    let players: [PlayerInfo]
    let status: GameStatus
}

// Ranking.swift - Depends on: PlayerInfo
struct Ranking: Codable {
    let rank: Int
    let player: PlayerInfo
}

// MatchConfig.swift - Depends on: MatchMode, MatchDuration
struct MatchConfig: Codable {
    let mode: MatchMode
    let duration: MatchDuration
}

// MatchMode.swift - No dependencies
enum MatchMode: String, Codable {
    case solo, team, tournament
}

// MatchDuration.swift - No dependencies
enum MatchDuration: Int, Codable {
    case short = 300
    case medium = 600
    case long = 1200
}

// Match.swift - Depends on: MatchConfig, MatchState
struct Match: Codable {
    let id: UUID
    let config: MatchConfig
    let state: MatchState
}

// MatchState.swift - No dependencies
enum MatchState: String, Codable {
    case preparing, active, completed
}
```

### Dependency Graph

```
GameRoom.swift
├── PlayerInfo.swift
│   ├── PlayerStats.swift
│   │   └── Achievement.swift
│   └── GameStatus.swift
├── RoomState.swift
│   ├── PlayerInfo.swift (already collected)
│   └── GameStatus.swift (already collected)
├── ScoreUpdate.swift
├── Ranking.swift
│   └── PlayerInfo.swift (already collected)
├── MatchConfig.swift
│   ├── MatchMode.swift
│   └── MatchDuration.swift
└── Match.swift
    ├── MatchConfig.swift (already collected)
    └── MatchState.swift
```

### Files Copied (Automatically!)

```
.trebuchet/Sources/ActorSources/
├── GameRoom.swift
├── PlayerInfo.swift
├── PlayerStats.swift
├── Achievement.swift
├── GameStatus.swift
├── RoomState.swift
├── ScoreUpdate.swift
├── Ranking.swift
├── MatchConfig.swift
├── MatchMode.swift
├── MatchDuration.swift
├── Match.swift
└── MatchState.swift
```

**Total: 13 files** automatically discovered and copied from just **1 actor**!

## Summary

The dependency analyzer makes Xcode project support **dramatically more powerful** by:

✅ **Automatically finding** all types your actors need
✅ **Recursively resolving** transitive dependencies
✅ **Intelligently filtering** standard library types
✅ **Gracefully falling back** if analysis fails
✅ **Providing clear output** about what's being copied

You can now use complex type hierarchies in your actors without worrying about manually tracking dependencies!
