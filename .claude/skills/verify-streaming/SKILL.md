---
name: verify-streaming
description: Verify the streaming fix is properly implemented in the codebase
---

Verify that the streaming bug fix is correctly implemented:

## Checks to Perform

### 1. Check Macro Expansion in DevCommand.swift

Verify observe method generation (around lines 789-804):
```bash
grep -A 20 "public func observe" /Users/bri/dev/Trebuchet/Sources/TrebuchetCLI/Commands/DevCommand.swift | head -30
```

**Expected**: No `nonisolated` keyword, direct actor property access

### 2. Check Streaming Handler Generation

Verify handlers use await (around lines 506-530):
```bash
grep -A 5 "let stream = await" /Users/bri/dev/Trebuchet/Sources/TrebuchetCLI/Commands/DevCommand.swift
```

**Expected**: `let stream = await typedActor.observeXxx()`

### 3. Check for Task.detached Anti-pattern

```bash
grep -r "Task.detached" /Users/bri/dev/Trebuchet/Sources/TrebuchetCLI/Commands/DevCommand.swift
```

**Expected**: No matches (this was the buggy pattern)

### 4. Check Generated Code (if Aura .trebuchet exists)

```bash
if [ -d /Users/bri/dev/Aura/.trebuchet ]; then
  echo "Checking generated code..."
  grep -r "nonisolated.*observe" /Users/bri/dev/Aura/.trebuchet/Sources/ 2>/dev/null || echo "✓ No nonisolated observe methods"
  grep -r "Task.detached" /Users/bri/dev/Aura/.trebuchet/Sources/ 2>/dev/null || echo "✓ No Task.detached found"
fi
```

## Report Results

For each check, report:
- ✅ Pass or ❌ Fail
- Show relevant code snippets
- Explain what the fix solves

## What This Fix Solves

The streaming bug was caused by:
- `Task.detached` spawned on global executor, not actor executor
- Observe method accessed actor state from detached task (race condition)
- Continuation registered after first value might yield
- Result: Stream terminated immediately, no data received

The fix:
- Observe methods are actor-isolated (no `nonisolated`)
- Direct access to actor state in actor's isolation domain
- No race conditions
- Stream properly yields initial value and updates
