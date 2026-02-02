# Dev Server Test Workflow

## Objective
Build and run the Trebuchet dev server for the Aura project, verify the streaming fix works correctly.

## Recent Fixes
- ✅ **Build timeout handling**: Dev command now exits properly on build failures with 5-minute timeout
- ✅ **Streaming fix**: observe methods are now actor-isolated (not nonisolated)
- ✅ **Error reporting**: Build errors are properly shown even in non-verbose mode
- Updated trebuchet binary at `/Users/bri/dev/Trebuchet/.build/release/trebuchet`

---

## Automated Execution

Run the following command to test the dev server:

```bash
cd /Users/bri/dev/Aura && rm -rf .trebuchet && /Users/bri/dev/Trebuchet/.build/release/trebuchet dev --local /Users/bri/dev/Trebuchet --verbose
```

### Expected Outcomes

**✅ Success Output:**
```
Starting local development server...
Using actors from trebuchet.yaml:
  • MessageActor
  ...
Building project...
✓ Build succeeded
Generating development server...
✓ Runner generated
Building server...
✓ Build succeeded
Starting server on localhost:8080...

Server running on ws://localhost:8080
Dynamic actor creation enabled
Logging all activity...
Press Ctrl+C to stop
```

**❌ Build Failure:**
The command will now properly exit with error output and won't hang. Error messages will indicate:
- **Actor isolation violations**: Check macro expansion in DevCommand.swift
- **Module not found**: Check module name matching
- **Build timeout**: Process is hanging, run directly to diagnose
- **Compilation errors**: Fix the specific errors shown

---

## Common Build Error Patterns

### 1. Actor Isolation Violations

**Error:**
```
error: distributed actor-isolated property '_xxx_continuations' can not be accessed from a nonisolated context
```

**Root Cause:** Observe methods marked `nonisolated` in generated code

**Fix Location:** `Sources/TrebuchetCLI/Commands/DevCommand.swift` lines 789-804 (expandMacros function)

**Correct Pattern:**
```swift
// Generated observe method must be actor-isolated (no nonisolated keyword)
public func observeXxx() -> AsyncStream<Type> {
    let id = UUID()
    return AsyncStream { continuation in
        self._xxx_continuations[id] = continuation  // Direct actor access
        continuation.yield(self._xxx_storage)
        continuation.onTermination = { @Sendable [weak self, id] _ in
            Task { try? await self?._cleanupXxxContinuation(id) }
        }
    }
}
```

**After fixing, rebuild:**
```bash
cd /Users/bri/dev/Trebuchet && swift build --product trebuchet --configuration release
```

---

### 2. Streaming Handler Errors

**Error:**
```
error: cannot convert value of type '() -> AsyncStream<Type>' to expected argument type
```

**Root Cause:** Missing `await` in streaming handler

**Fix Location:** `Sources/TrebuchetCLI/Commands/DevCommand.swift` lines 506-530 (generateLocalRunner streaming config)

**Correct Pattern:**
```swift
case "observeXxx":
    let stream = await typedActor.observeXxx()  // Must use await
    return TrebuchetServer.encodeStream(stream)
```

---

### 3. Module Name Mismatch

**Error:**
```
error: no such module 'Aura' or 'ActorSources'
```

**Root Cause:** Module name doesn't match between client and server

**Fix:**
- **Xcode projects**: Check `inferModuleName` in DevCommand.swift (lines 441-460)
- **SPM projects**: Verify Package.swift product names match

**Debug:**
```bash
# Check what module name is being inferred
grep -A 5 "import.*Aura\|import.*ActorSources" /Users/bri/dev/Aura/.trebuchet/Sources/*/main.swift
```

---

## Verifying the Streaming Fix

### Step 1: Start Dev Server

Run the dev server (command above). Leave it running in this terminal.

### Step 2: Launch Client Application

In a new terminal:
```bash
cd /Users/bri/dev/Aura
open Aura.xcodeproj
# Build and run from Xcode
```

### Step 3: Check Logs

**Server logs should show:**
```
[timestamp] 🌊 Stream started: actor-id.observeMessages
[timestamp] 📞 actor-id.method
```

**Client logs should show:**
```
🟢 [StreamRegistry] Creating remote stream with ID: ...
🟢 [StreamRegistry] Received StreamStart: ...
🟢 [StreamRegistry] Received StreamDataEnvelope for stream ...
🔵 [@ObservedActor] Received state update from stream!
```

### Success Criteria

- ✅ Stream creates successfully
- ✅ StreamStart received on client
- ✅ **StreamData received and yielded** (this was the bug)
- ✅ **@ObservedActor state updates** (was previously nil)
- ✅ **SwiftUI views update** (was previously frozen)

### Failure Indicators

- ❌ Stream terminates immediately after StreamStart
- ❌ No "Stream started" logs on server
- ❌ No "Received StreamDataEnvelope" on client
- ❌ State remains `nil` in views

---

## Quick Diagnostics

### Build Hanging or Timeout

```bash
# Test parent project build directly
cd /Users/bri/dev/Aura && swift build

# Test generated server build directly
cd /Users/bri/dev/Aura && swift build --package-path .trebuchet
```

### Macro Expansion Issues

```bash
# Check generated code for Xcode projects
cat /Users/bri/dev/Aura/.trebuchet/Sources/Aura/*.swift | grep -A 10 "observeMessages"

# Verify no nonisolated markers
grep -r "nonisolated.*observe" /Users/bri/dev/Aura/.trebuchet/Sources/

# Verify no Task.detached usage
grep -r "Task.detached" /Users/bri/dev/Aura/.trebuchet/Sources/
```

### Stream Not Receiving Data

1. **Check server**: Is `🌊 Stream started` logged?
   - No: Actor not exposing stream method correctly
   - Yes: Continue to step 2

2. **Check client**: Is `StreamStart` received?
   - No: Transport/connection issue
   - Yes: Continue to step 3

3. **Check data flow**: Is `StreamDataEnvelope` received?
   - No: Server not yielding data (check observe method implementation)
   - Yes: Client not handling data (check StreamRegistry)

---

## Emergency Rollback

If the dev server becomes unusable:

```bash
cd /Users/bri/dev/Trebuchet

# Check what changed
git diff Sources/TrebuchetCLI/Commands/DevCommand.swift
git diff Sources/TrebuchetMacros/TrebuchetMacros.swift

# Revert if needed
git checkout HEAD -- Sources/TrebuchetCLI/Commands/DevCommand.swift
git checkout HEAD -- Sources/TrebuchetMacros/TrebuchetMacros.swift

# Rebuild
swift build --product trebuchet --configuration release
```

---

## Notes

- **Timeout protection**: Build processes now have 5-minute timeout and will exit cleanly
- **Error visibility**: All build errors shown regardless of verbose flag
- **Streaming pattern**: observe methods MUST be actor-isolated, called with `await`
- **Xcode projects**: Macro expansion happens in DevCommand.swift (lines 697-847)
- **SPM projects**: Macros expand during build automatically

---

## Troubleshooting Reference

| Symptom | Root Cause | Fix Location |
|---------|------------|--------------|
| Actor isolation error | `nonisolated` in generated code | DevCommand.swift:789-804 |
| Streaming handler error | Missing `await` | DevCommand.swift:506-530 |
| Module not found | Name mismatch | DevCommand.swift:441-460 |
| Build timeout | Hanging build | Run `swift build` directly |
| Stream terminates early | Continuation race | Check observe method impl |
| No StreamData | Not yielding | Check `continuation.yield()` call |
| View not updating | State not marked @Published | Check @ObservedActor usage |
