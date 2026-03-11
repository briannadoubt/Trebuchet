# Streaming Bug Investigation Prompt

## Problem Statement

`@ObservedActor` in SwiftUI is not receiving streaming state updates from distributed actors. The stream is created successfully, receives `StreamStart`, but then terminates immediately without ever yielding any data.

## Observable Symptoms

From the client logs:
```
🟢 [StreamRegistry] Creating remote stream with ID: 71EA4A29-7553-4475-A330-C0C7D934005B for callID: 0B8E6388-3E5D-4B12-862A-65CB0E34F68F
🟢 [StreamRegistry] Registering continuation for stream 71EA4A29-7553-4475-A330-C0C7D934005B
🔵 [@ObservedActor] Stream created with ID: 71EA4A29-7553-4475-A330-C0C7D934005B
🔵 [@ObservedActor] Starting stream iteration...
🟢 [StreamRegistry] Received StreamStart: callID=0B8E6388-3E5D-4B12-862A-65CB0E34F68F, serverStreamID=6A9162A1-D542-48DE-A6EC-9E8D01C843A2
🟢 [StreamRegistry] Creating alias: serverStreamID 6A9162A1-D542-48DE-A6EC-9E8D01C843A2 -> clientStreamID 71EA4A29-7553-4475-A330-C0C7D934005B
🟢 [StreamRegistry] Stream aliased successfully (both IDs active)
🟢 [StreamRegistry] Stream 71EA4A29-7553-4475-A330-C0C7D934005B terminated  ← IMMEDIATE TERMINATION
🔵 [@ObservedActor] Stream iteration ended
```

The view state remains `nil` throughout. The `@ObservedActor` never receives any state updates.

## Architecture Overview

### Stream Creation Flow

1. **Client** (`@ObservedActor`):
   - Calls `remoteCallStream()` on actor system
   - Gets back `(streamID, AsyncStream<State>)`
   - The `streamID` is client-generated (UUID)
   - Begins iterating the stream with `for await`

2. **StreamRegistry** (client-side):
   - `createRemoteStream(callID:)` creates a new stream with client-generated `streamID`
   - Stores `StreamState` in `streams[clientStreamID]`
   - Maps `callID -> clientStreamID` in `callIDToStreamID`
   - Returns `AsyncStream<Data>` with a continuation that will be registered

3. **Server**:
   - Receives invocation envelope
   - Generates its own server `streamID` (different from client's)
   - Sends `StreamStart` envelope with server's `streamID`
   - Executes the streaming method to get `AsyncStream<Data>`
   - Iterates the stream and sends `StreamData` envelopes with server's `streamID`

4. **StreamRegistry** (receives StreamStart):
   - Looks up client stream using `callID`
   - Creates "alias" by copying `StreamState` to `streams[serverStreamID]`
   - Updates mapping: `callIDToStreamID[callID] = serverStreamID`

5. **StreamRegistry** (should receive StreamData):
   - Should receive `StreamData` envelope with server's `streamID`
   - Should yield data to continuation
   - **BUT THIS NEVER HAPPENS** - stream terminates first

### Type Hierarchy

```
TrebuchetActorSystem.remoteCallStream()
  ↓
  Creates: StreamRegistry.createRemoteStream() → AsyncStream<Data> (dataStream)
  ↓
  Wraps in: AsyncStream<Res> (typedStream) that decodes Data → Res
  ↓
  Returns to @ObservedActor
  ↓
  @ObservedActor iterates with: for await state in typedStream
```

## What We've Tried

### Attempt 1: Changed StreamState from struct to class
**Rationale**: Struct copying was creating separate instances for clientStreamID and serverStreamID, so the continuation registered on one wasn't accessible from the other.

**Result**: STILL FAILS. Stream still terminates immediately after StreamStart.

**Files Modified**:
- `Sources/Trebuchet/ActorSystem/StreamRegistry.swift` - Changed `StreamState` from `struct` to `class`

## Key Files to Investigate

1. **StreamRegistry.swift** (`Sources/Trebuchet/ActorSystem/StreamRegistry.swift`)
   - Manages stream state and continuations
   - Handles StreamStart/StreamData/StreamEnd envelopes
   - The aliasing logic in `handleStreamStart()` is suspicious

2. **TrebuchetActorSystem.swift** (`Sources/Trebuchet/ActorSystem/TrebuchetActorSystem.swift`)
   - `remoteCallStream()` creates the typed stream wrapper
   - Contains the Task that iterates `dataStream` and transforms it

3. **ObservedActor.swift** (`Sources/Trebuchet/SwiftUI/ObservedActor.swift`)
   - `startStreaming()` method calls `remoteCallStream()`
   - Iterates the returned stream

4. **TrebuchetServer.swift** (`Sources/Trebuchet/Server/TrebuchetServer.swift`)
   - `handleStreamingInvocation()` sends StreamStart and iterates the actor's stream
   - Should be sending StreamData envelopes

## Critical Questions to Answer

### 1. Why does the stream terminate immediately?
The `onTermination` callback fires right after StreamStart is received. What's causing the AsyncStream to finish?

Possible causes:
- The `dataStream` from StreamRegistry is ending immediately
- The `typedStream` wrapper's Task is completing
- The continuation is being finished somewhere
- The stream is being cancelled

### 2. Is the server actually sending StreamData?
We need to see server logs showing:
```
🟡 [Server] Executing streaming target: observeMessages
🟡 [Server] Stream obtained, starting iteration...
🟡 [Server] Received data from stream, sequence: 1
```

**If these logs are missing**, the server never started iterating the stream. Why?

**If these logs are present**, the StreamData envelopes are being sent. Are they arriving at the client?

### 3. What happens to the AsyncStream continuation?
The continuation is registered in `registerContinuation()`. Is it:
- Being registered successfully?
- Being finished by something?
- Never being yielded to?

### 4. The dual-stream wrapper pattern
`remoteCallStream()` creates a wrapper `AsyncStream<Res>` that spawns a Task to iterate `dataStream`. This Task:
```swift
Task {
    for await dataItem in dataStream {
        let value = try decoder.decode(Res.self, from: dataItem)
        continuation.yield(value)
    }
    continuation.finish()
}
```

If `dataStream` ends immediately (before any data), this Task would finish and call `continuation.finish()` on the wrapper stream. Is this what's happening?

### 5. The aliasing logic
When we create an alias:
```swift
guard let state = streams[clientStreamID] else { return }
streams[envelope.streamID] = state
callIDToStreamID[envelope.callID] = envelope.streamID
```

Even with `class`, are we sure both dictionary entries reference the exact same instance? Or could there be a retain/copy happening?

## Debugging Strategy

### Step 1: Add comprehensive logging
Add logs at EVERY step to trace the exact flow:

1. In `remoteCallStream()`:
   - When `dataStream` is created
   - When the wrapper Task starts
   - Each iteration of `for await dataItem in dataStream`
   - When the loop ends (normal vs cancelled)

2. In `StreamRegistry.registerContinuation()`:
   - When continuation is set
   - The state of `streams[streamID]` before and after

3. In `StreamRegistry.handleStreamData()`:
   - When each envelope arrives
   - Whether the continuation exists
   - Whether yield succeeds

4. In `TrebuchetServer.handleStreamingInvocation()`:
   - When stream iteration starts
   - Each data item from the actor's stream
   - When StreamData envelopes are sent

### Step 2: Check for race conditions
The AsyncStream continuation might not be registered yet when data arrives. Check:
- Is `pendingData` being used correctly?
- Does the continuation get registered AFTER StreamData arrives?

### Step 3: Verify the actor's stream
Does the actor's `observeMessages()` method actually return a stream that yields data?
- Add logging inside the actor's streaming method
- Verify it yields at least once before the connection

### Step 4: Test without the wrapper
Try iterating `dataStream` directly instead of wrapping it in a typed stream. Does the raw Data stream work?

### Step 5: Check StreamEnd envelopes
Is the server sending a StreamEnd immediately after StreamStart?
- Search for logs showing StreamEnd being sent
- Check if there's an error in the actor's streaming method

## Expected Behavior (What Should Happen)

1. Client creates stream with clientStreamID
2. Client sends invocation with callID
3. Server receives invocation
4. Server generates serverStreamID
5. Server sends StreamStart(serverStreamID, callID)
6. Client receives StreamStart, creates alias
7. Server begins iterating actor's stream
8. Server yields first data item
9. Server sends StreamData(serverStreamID, data, seq=1)
10. Client receives StreamData, looks up serverStreamID, finds continuation
11. Client yields data to continuation
12. The wrapper Task receives data, decodes it, yields to typed stream
13. @ObservedActor receives typed value, updates state
14. View re-renders with new state

**WHERE IN THIS FLOW IS IT BREAKING?**

## Test Case

Use the ConversationActor test with `observeMessages`:

```swift
@ObservedActor(id: "conversationactor-test", property: "messages")
var conversation
```

The actor has:
```swift
@StreamedState private var messages: [Message] = []

distributed func observeMessages() -> AsyncStream<[Message]> {
    _observeMessages()  // Generated by @StreamedState macro
}
```

## Success Criteria

After the fix:
1. Stream creates successfully ✅
2. StreamStart received ✅
3. **StreamData received and yielded to continuation** ← CURRENTLY FAILING
4. **State decoded and passed to @ObservedActor** ← CURRENTLY FAILING
5. **View updates with new state** ← CURRENTLY FAILING
6. Subsequent state changes continue to stream

## Additional Context

- The regular `@RemoteActor` property wrapper works fine (non-streaming calls)
- This suggests the core RPC infrastructure is working
- The problem is specific to streaming
- The `@StreamedState` macro appears to be working (actor compiles successfully)
- The dev server is running with `--local` pointing to the local Trebuchet with fixes

## Next Steps

1. Read the server logs from the latest run to see if StreamData is being sent
2. Add detailed logging to trace exactly where the stream terminates
3. Potentially add a test case that doesn't involve SwiftUI to isolate the issue
4. Consider whether the problem is in the stream wrapper, the registry, or the server

Good luck! This is a critical bug blocking the entire streaming feature.
