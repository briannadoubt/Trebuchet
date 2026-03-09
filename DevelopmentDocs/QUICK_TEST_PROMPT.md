# Quick Dev Server Test Task

Execute these steps to build and verify the Trebuchet dev server:

## Step 1: Build and Run

```bash
cd /Users/bri/dev/Aura && rm -rf .trebuchet && /Users/bri/dev/Trebuchet/.build/release/trebuchet dev --local /Users/bri/dev/Trebuchet --verbose
```

**If successful (server starts):** Leave running and go to Step 3

**If fails:** Go to Step 2

## Step 2: Fix Compilation Errors

1. **Read the error logs** - capture full output
2. **Identify the issue:**
   - Actor isolation errors → Check if observe methods have `nonisolated` (should NOT)
   - Module errors → Check module name matching
   - Await errors → Check if streaming handler uses `await`
3. **Fix the code** in appropriate files:
   - `Sources/TrebuchetMacros/TrebuchetMacros.swift` (macro)
   - `Sources/TrebuchetCLI/Commands/DevCommand.swift` (manual expansion)
4. **Rebuild trebuchet:**
   ```bash
   cd /Users/bri/dev/Trebuchet && swift build --product trebuchet --configuration release
   ```
5. **Return to Step 1** (max 5 attempts)

## Step 3: Verify Streaming Works

With server running from Step 1:

1. **Check server logs** - should show:
   ```
   🟡 [Server] Executing streaming target: observeMessages
   🟡 [Server] Received data from stream, sequence: 1
   ```

2. **Run client** (Aura app) and check for:
   ```
   🟢 [StreamRegistry] Received StreamDataEnvelope
   🔵 [@ObservedActor] Received state update from stream!
   ```

3. **Verify UI updates** - SwiftUI views should show state changes

## Success Criteria

✅ Dev server builds without errors
✅ Server sends StreamData envelopes
✅ Client receives StreamData
✅ @ObservedActor state updates
✅ UI reflects changes

## Critical Fix Reminder

The observe methods should look like this:

```swift
// ✅ CORRECT
public func observeMessages() -> AsyncStream<[Message]> {
    let id = UUID()
    return AsyncStream { continuation in
        self._messages_continuations[id] = continuation
        continuation.yield(self._messages_storage)
        // ...
    }
}

// ❌ WRONG (old code)
nonisolated public func observeMessages() -> AsyncStream<[Message]> {
    Task.detached { ... }
}
```

For detailed troubleshooting, see `DEV_SERVER_TEST_PROMPT.md`.
