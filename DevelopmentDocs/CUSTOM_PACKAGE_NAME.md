# Custom Package Name and Output Directory

You can now customize both the package name and output directory for generated servers through `trebuchet.yaml`.

## Configuration

Add the optional `packageName` and `outputDirectory` fields to your `trebuchet.yaml`:

```yaml
name: my-game-server
version: "1"
packageName: "GameServerRunner"     # Custom package name (optional)
outputDirectory: "TrebuchetServer"  # Custom output dir (optional)

defaults:
  provider: aws
  region: us-east-1
  memory: 512
  timeout: 30

actors:
  GameRoom:
    memory: 1024
```

## Default Behavior

### Package Name

If `packageName` is **not specified**, the following defaults are used:

- **`trebuchet dev`**: Package name is `"LocalRunner"`
- **`trebuchet generate server`**: Package name is `"TrebuchetAutoServer"`

### Output Directory

If `outputDirectory` is **not specified**, the default is:

- **`trebuchet dev`**: Output directory is `".trebuchet"` (hidden folder)

## With Custom Package Name

If `packageName: "GameServerRunner"` is specified:

- **`trebuchet dev`**: Package name is `"GameServerRunner"`
- **`trebuchet generate server`**: Package name is `"GameServerRunner"`

## What Gets Customized

When you set `packageName`, it affects:

1. **Package.swift** - The `Package(name: ...)` declaration
2. **Target names** - The executable target name
3. **Directory structure** - The `Sources/{PackageName}/` directory

## Example: Before and After

### Before (default)

```bash
trebuchet dev
```

Generated structure:
```
.trebuchet/                 # Hidden directory
├── Package.swift           # name: "LocalRunner"
└── Sources/
    └── LocalRunner/        # Default package name
        └── main.swift
```

### After (with both customizations)

```yaml
# trebuchet.yaml
name: my-game
packageName: "GameServer"
outputDirectory: "DevServer"
```

```bash
trebuchet dev
```

Generated structure:
```
DevServer/                  # Visible directory, can add to Xcode!
├── Package.swift           # name: "GameServer"
└── Sources/
    └── GameServer/         # Custom package name
        └── main.swift
```

### Just Output Directory (keep default package name)

```yaml
# trebuchet.yaml
name: my-game
outputDirectory: "TrebuchetDevServer"
```

Generated structure:
```
TrebuchetDevServer/         # Visible directory
├── Package.swift           # name: "LocalRunner" (default)
└── Sources/
    └── LocalRunner/
        └── main.swift
```

## Output Directory Use Cases

### Why Customize the Output Directory?

The default `.trebuchet` directory is **hidden** (starts with `.`), which causes issues:

1. **Xcode Workspaces**: Cannot add hidden folders to Xcode workspaces
2. **Visibility**: Hidden in Finder by default
3. **Git**: May be unintentionally ignored

### Solution: Use a Visible Directory

```yaml
name: my-app
outputDirectory: "TrebuchetServer"  # Visible, can be added to workspace
```

Now the generated server appears in:
```
my-app/
├── TrebuchetServer/        # ✅ Visible in Xcode and Finder
│   ├── Package.swift
│   └── Sources/
└── Package.swift
```

### Adding to Xcode Workspace

With a visible output directory, you can:

1. **Add to workspace**: File → Add Files to "{Workspace}"
2. **Browse sources**: See generated server code in Xcode
3. **Debug**: Set breakpoints in generated server
4. **Build from Xcode**: Build the dev server directly

## Package Name Use Cases

### 1. Multiple Server Configurations

If you maintain multiple server configurations, custom package names help differentiate them:

```yaml
# development.yaml
name: my-app
packageName: "DevServer"

# production.yaml
name: my-app
packageName: "ProdServer"
```

### 2. Naming Conventions

Match your team's naming conventions:

```yaml
packageName: "MyAppActorServer"  # Descriptive
packageName: "ServerBundle"       # Generic
packageName: "EdgeRuntime"        # Domain-specific
```

### 3. Avoid Conflicts

If `LocalRunner` conflicts with existing packages:

```yaml
packageName: "TrebuchetDevServer"  # Explicit, no conflicts
```

## .gitignore Considerations

### Default `.trebuchet` (hidden)

Usually added to `.gitignore` automatically:

```gitignore
.trebuchet/
```

### Custom Visible Directory

If you use a visible directory and want to **ignore it**:

```gitignore
# Add to .gitignore
DevServer/
TrebuchetServer/
```

If you want to **commit it** (for CI/CD caching):

```gitignore
# Don't add to .gitignore - commit the generated server
```

## Implementation Details

The customizations are applied to:

### Package Name
- `DevCommand.swift` - Both Swift Package and Xcode project modes
- `ServerGenerator.swift` - Standalone server generation
- All generated `Package.swift` manifests
- All executable target definitions
- Source directory naming (Sources/{PackageName}/)

### Output Directory
- `DevCommand.swift` - Directory where dev server is generated
- Affects cleanup operations (old directory removal)
- Used in all file path operations

## Validation

Package names must be valid Swift identifiers:
- Start with a letter
- Contain only letters, numbers, and underscores
- No spaces or special characters

Invalid examples:
```yaml
packageName: "My Server"      # ❌ Contains space
packageName: "123Server"      # ❌ Starts with number
packageName: "server-runner"  # ❌ Contains hyphen
```

Valid examples:
```yaml
packageName: "MyServer"       # ✅
packageName: "Server123"      # ✅
packageName: "my_server"      # ✅
```
