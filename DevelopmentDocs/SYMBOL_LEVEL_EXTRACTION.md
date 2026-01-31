# Symbol-Level Extraction: Design Document

## Overview

This document explores implementing **symbol-level extraction** instead of file-level copying, where only the specific types needed are extracted from source files.

## Current Implementation: File-Level

```swift
// Models.swift (source)
struct PlayerInfo: Codable { }
struct RoomState: Codable { }
struct UnrelatedType: Codable { }  // ← Not needed but copied

// Result: Entire file copied
```

## Proposed: Symbol-Level

```swift
// Models.swift (source)
struct PlayerInfo: Codable { }
struct RoomState: Codable { }
struct UnrelatedType: Codable { }

// Result: Only needed types extracted
// ActorSources/Models_extracted.swift
struct PlayerInfo: Codable { }
struct RoomState: Codable { }
// UnrelatedType NOT included
```

## Implementation Challenges

### 1. Extract Individual Declarations

Need to:
- Parse Swift file into AST
- Find specific type declarations
- Extract their source ranges
- Reconstruct valid Swift from those ranges

```swift
func extractType(named: String, from file: String) -> String? {
    let source = try String(contentsOfFile: file)
    let parsed = Parser.parse(source: source)

    // Find the declaration
    let visitor = TypeExtractor(targetName: named)
    visitor.walk(parsed)

    // Extract source text for that declaration only
    guard let declaration = visitor.foundDeclaration else {
        return nil
    }

    return declaration.description
}
```

### 2. Handle Extensions

Extensions must be kept with their types:

```swift
// Models.swift
struct Player: Codable {
    let name: String
}

extension Player {
    func greet() -> String {
        "Hello, \(name)"
    }
}

extension Player: Equatable {
    // Additional conformance
}
```

**Problem:** Extensions can be anywhere in the file, or even in other files!

**Solution:** Need to scan for all extensions targeting extracted types:

```swift
func extractExtensions(for type: String, in file: String) -> [String] {
    // Find all: extension TypeName { }
}
```

### 3. Handle Dependencies Between Types in Same File

```swift
// Models.swift
struct Inner: Codable {
    let value: Int
}

struct Outer: Codable {
    let inner: Inner  // ← Depends on Inner
}
```

If actor uses `Outer`, we need `Inner` too, even though it's in the same file.

**Solution:** Recursively analyze dependencies within the file:

```swift
func extractWithLocalDeps(type: String, from file: String) -> Set<String> {
    var extracted = Set([type])

    // Analyze type for local dependencies
    let localDeps = findLocalDependencies(type, in: file)
    for dep in localDeps {
        extracted.formUnion(extractWithLocalDeps(dep, from: file))
    }

    return extracted
}
```

### 4. Preserve File-Level Declarations

Some things exist at file level:

```swift
// Models.swift
import Foundation
import CustomFramework

typealias PlayerID = UUID

fileprivate func helper() { }

struct Player: Codable {
    let id: PlayerID  // ← Uses file-level typealias

    func doSomething() {
        helper()  // ← Uses file-level function
    }
}
```

**Problem:** If we only extract `Player`, it won't compile!

**Solution:** Need to extract and include:
- Relevant imports
- Typealiases used by extracted types
- File-level helpers/constants
- Conditional compilation blocks

This gets very complex very quickly.

### 5. Handle Nested Types

```swift
struct GameRoom {
    struct Settings: Codable {
        let maxPlayers: Int
    }

    enum State {
        case waiting, active
    }
}

// Actor uses:
distributed func configure(settings: GameRoom.Settings)
```

**Problem:** Need to extract `GameRoom.Settings`, but it's nested inside `GameRoom`.

**Solution:** Extract the entire `GameRoom` struct (bringing us back to file-level!)

Or: Create a new file structure:
```swift
// GameRoom_Settings.swift
extension GameRoom {
    struct Settings: Codable {
        let maxPlayers: Int
    }
}
```

But this changes the structure and may break other code.

## Comparison: File-Level vs Symbol-Level

| Aspect | File-Level ✅ | Symbol-Level |
|--------|--------------|--------------|
| **Implementation** | Simple | Very Complex |
| **Correctness** | Always works | Risk of missing deps |
| **Code size** | May include extras | Minimal |
| **File structure** | Preserved | Altered |
| **Extensions** | Automatically included | Must be tracked |
| **Nested types** | Handled naturally | Requires special logic |
| **Performance** | Fast (copy file) | Slower (parse, extract, reconstruct) |
| **Debugging** | Easy (same structure) | Harder (restructured) |
| **Maintenance** | Low | High |

## Recommendation: Hybrid Approach

Instead of pure symbol-level extraction, consider a **hybrid approach**:

### Option 1: File-Level with Warnings

Keep current file-level copying, but warn about unused types:

```bash
✓ Copied Models.swift (3 types, 1 unused: UnrelatedType)
```

Users can then manually clean up if desired.

### Option 2: Smart File Splitting

Detect files with many types and suggest splitting:

```bash
⚠️  Models.swift contains 15 types, but only 3 are used.
   Consider organizing types into separate files for better tree-shaking.
```

### Option 3: Opt-In Symbol Extraction

Add a flag for symbol-level extraction for advanced users:

```bash
trebuchet dev --extract-symbols
```

With clear warnings about potential issues.

## Proposed Implementation (Symbol-Level)

If we wanted to implement symbol-level extraction:

```swift
/// Extracts specific type declarations from a Swift file
struct SymbolExtractor {
    /// Extract types and their dependencies from a file
    func extract(types: Set<String>, from filePath: String) throws -> String {
        let source = try String(contentsOfFile: filePath)
        let parsed = Parser.parse(source: source)

        var extracted: [String] = []

        // 1. Extract imports
        extracted.append(extractImports(from: parsed))

        // 2. Extract file-level declarations (typealiases, etc.)
        let fileLevelDecls = extractFileLevelDeclarations(from: parsed)
        extracted.append(fileLevelDecls)

        // 3. Extract each requested type
        for typeName in types {
            if let typeDecl = extractTypeDeclaration(named: typeName, from: parsed) {
                extracted.append(typeDecl)
            }

            // 4. Extract extensions for this type
            let extensions = extractExtensions(for: typeName, from: parsed)
            extracted.append(contentsOf: extensions)
        }

        return extracted.joined(separator: "\n\n")
    }

    private func extractTypeDeclaration(named: String, from tree: SourceFileSyntax) -> String? {
        let visitor = TypeDeclarationFinder(targetName: named)
        visitor.walk(tree)
        return visitor.declaration?.description
    }

    private func extractExtensions(for type: String, from tree: SourceFileSyntax) -> [String] {
        let visitor = ExtensionFinder(targetType: type)
        visitor.walk(tree)
        return visitor.extensions.map { $0.description }
    }

    private func extractImports(from tree: SourceFileSyntax) -> String {
        let visitor = ImportCollector()
        visitor.walk(tree)
        return visitor.imports.map { $0.description }.joined(separator: "\n")
    }
}

final class TypeDeclarationFinder: SyntaxVisitor {
    let targetName: String
    var declaration: (any DeclSyntaxProtocol)?

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            declaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    // Similar for class, enum, actor, protocol...
}

final class ExtensionFinder: SyntaxVisitor {
    let targetType: String
    var extensions: [ExtensionDeclSyntax] = []

    init(targetType: String) {
        self.targetType = targetType
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedType = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        if extendedType == targetType {
            extensions.append(node)
        }
        return .visitChildren
    }
}
```

## Testing Symbol Extraction

Would need extensive tests:

```swift
@Test
func symbolExtractionBasic() throws {
    let source = """
    struct Used: Codable {
        let value: Int
    }

    struct Unused: Codable {
        let data: String
    }
    """

    let extractor = SymbolExtractor()
    let result = try extractor.extract(types: ["Used"], from: sourceFile)

    #expect(result.contains("struct Used"))
    #expect(!result.contains("struct Unused"))
}

@Test
func symbolExtractionWithExtension() throws {
    let source = """
    struct Player: Codable {
        let name: String
    }

    extension Player {
        func greet() -> String {
            "Hello"
        }
    }
    """

    let extractor = SymbolExtractor()
    let result = try extractor.extract(types: ["Player"], from: sourceFile)

    #expect(result.contains("struct Player"))
    #expect(result.contains("extension Player"))
}
```

## Conclusion

**Recommendation:** Stick with file-level copying for now.

**Reasons:**
1. Much simpler and more reliable
2. Preserves developer's file organization
3. Handles edge cases naturally
4. Fewer bugs and easier to maintain
5. Most files are already well-organized by type

**Future Enhancement:** Add symbol-level extraction as an opt-in advanced feature once file-level is battle-tested.

## User Workflow

For users who want minimal copied code:

**Best Practice:** Organize your Xcode project with one type per file
```
Models/
├── PlayerInfo.swift      # Just PlayerInfo
├── RoomState.swift       # Just RoomState
├── GameStatus.swift      # Just GameStatus
└── UnrelatedType.swift   # Won't be copied
```

Then file-level copying = symbol-level extraction!
