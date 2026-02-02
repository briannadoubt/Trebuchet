---
name: ui-test
description: Run UI tests for the Aura project to verify streaming functionality
---

# UI Test Skill

Run the Aura UI tests on iPhone Air simulator to verify @ObservedActor streaming functionality.

## Prerequisites

1. Dev server must be running on localhost:8080
2. Aura Xcode project must be built
3. iPhone Air simulator must be available

## Workflow

1. **Verify server is running**:
   ```bash
   lsof -i :8080 | grep LISTEN
   ```

2. **Run UI tests**:
   ```bash
   cd /Users/bri/dev/Aura
   xcodebuild -project Aura.xcodeproj \
     -scheme Aura \
     -destination "platform=iOS Simulator,name=iPhone Air" \
     test 2>&1 | tee /tmp/ui-test-results.log
   ```

3. **Analyze results**:
   - Check for test pass/fail status
   - Look for `testTestMessageViewSendsAndReceivesMessages` result
   - Verify message count >= 3 (indicates streaming worked)
   - Check connection state shows "connected"

## Expected Output

**Success indicators**:
- ✅ Test suite completes
- ✅ `testTestMessageViewSendsAndReceivesMessages` passes
- ✅ Messages count shows >= 3 messages received via streaming
- ✅ Connection state shows "connected"

**Failure indicators**:
- ❌ Test times out waiting for messages
- ❌ Messages count shows -1 or < 3
- ❌ Connection state shows "disconnected" or "failed"

## Troubleshooting

If tests fail:
1. Check dev server logs for connection attempts
2. Verify actor is exposed correctly
3. Check streaming configuration in server
4. Look for macro expansion errors in build output

## Test File Location

- UI Test: `/Users/bri/dev/Aura/AuraUITests/AuraUITests.swift`
- Test View: `/Users/bri/dev/Aura/Aura/Views/TestStreamingView.swift`
