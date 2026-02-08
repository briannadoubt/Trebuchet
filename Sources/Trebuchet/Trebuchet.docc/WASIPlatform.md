# WASI Platform Support

Build Trebuchet distributed actors for WebAssembly System Interface (WASI) and browser environments.

## Overview

Trebuchet supports WASI builds, enabling Swift distributed actors to run in browser environments and other WebAssembly runtimes. The WASI implementation uses JavaScriptKit to provide WebSocket client connectivity through the browser's native WebSocket API.

### Platform Availability

WASI support is available for:
- Browser-based applications
- Node.js with WASI runtime
- Other WASI-compliant WebAssembly environments

### Limitations

The WASI platform has specific constraints:

- **Client-only**: WASI builds can only act as clients connecting to remote actors
- **WebSocket only**: Only ``WebSocketTransport`` is available; TCP transport is compiled out
- **No server mode**: The `listen(on:)` method is unavailable on WASI
- **No macros**: The `@Trebuchet` and `@StreamedState` macros are unavailable on WASI builds

## Building for WASI

### Prerequisites

Install the Swift WASM toolchain and SDK:

```bash
# Install swiftly (if not already installed)
brew install swiftly

# Install Swift 6.2.3
swiftly install 6.2.3
swiftly use 6.2.3

# Install WASM SDK
swift sdk install \
  https://download.swift.org/swift-6.2.3-release/wasm-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 394040ecd5260e68bb02f6c20aeede733b9b90702c2204e178f3e42413edad2a
```

### Package Configuration

Configure your `Package.swift` to support WASI:

```swift
let package = Package(
    name: "MyApp",
    platforms: [.custom("wasi", versionString: "1.0")],
    dependencies: [
        .package(url: "https://github.com/yourusername/Trebuchet.git", from: "0.2.3"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "Trebuchet", package: "Trebuchet"),
            ]
        )
    ]
)
```

### Build Command

Build your project for WASI:

```bash
swift build --swift-sdk swift-6.2.3-RELEASE_wasm
```

For optimized production builds:

```bash
swift build \
  --swift-sdk swift-6.2.3-RELEASE_wasm \
  -c release \
  -Xswiftc -Osize \
  -Xswiftc -whole-module-optimization \
  -Xlinker --lto-O3 \
  -Xlinker --gc-sections \
  -Xlinker --strip-debug
```

The compiled WASM binary will be located at:
```
.build/wasm32-unknown-wasip1/debug/MyApp.wasm
```

## Using WebSocket Transport in WASI

Create a client connection to a remote Trebuchet server:

```swift
import Foundation
import Trebuchet
import JavaScriptKit
import JavaScriptEventLoop

// Initialize the JavaScript event loop
JavaScriptEventLoop.installGlobalExecutor()

// Create WebSocket transport
let endpoint = Endpoint(host: "server.example.com", port: 8080)
let transport = WebSocketTransport()

// Connect and send messages
try await transport.connect(to: endpoint)
try await transport.send(data, to: endpoint)

// Receive messages
for await message in transport.incoming {
    // Process incoming message
}

// Clean up
await transport.shutdown()
```

### Client-Side Actor Resolution

Connect to and interact with remote actors:

```swift
@main
struct MyWASMApp {
    static func main() async throws {
        JavaScriptEventLoop.installGlobalExecutor()

        let endpoint = Endpoint(host: "game.example.com", port: 8080)
        let client = TrebuchetClient(transport: .webSocket(host: "game.example.com", port: 8080))

        try await client.connect()

        // Resolve remote actor
        let gameRoom = try client.resolve(GameRoom.self, id: "lobby")

        // Call distributed methods
        let state = try await gameRoom.join(player: currentPlayer)

        // Keep alive or process events...
    }
}
```

## Running WASM in the Browser

### HTML Setup

Create an HTML file to load your WASM module:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Trebuchet WASM App</title>
    <script type="module">
        import { SwiftRuntime } from "./swift-runtime.mjs";
        import { WASI } from "@wasmer/wasi";

        const swift = new SwiftRuntime();
        const wasi = new WASI({
            args: [],
            env: {}
        });

        const response = await fetch("./MyApp.wasm");
        const wasmBytes = await response.arrayBuffer();

        const { instance } = await WebAssembly.instantiate(wasmBytes, {
            wasi_snapshot_preview1: wasi.wasiImport,
            javascript_kit: swift.wasmImports,
        });

        swift.setInstance(instance);
        instance.exports._initialize();

        // Your app entry point
        instance.exports.main();
    </script>
</head>
<body>
    <h1>Trebuchet WASM App</h1>
</body>
</html>
```

### Serving the Application

Use a simple HTTP server for development:

```bash
python3 -m http.server 8000
```

Navigate to `http://localhost:8000` in your browser.

## Testing WASI Builds

Trebuchet includes an end-to-end test harness for WASI WebSocket functionality:

```bash
./Tests/WasmE2E/run-wasm-websocket-e2e.sh
```

This script:
1. Builds a WASM probe using the Trebuchet library
2. Starts a local WebSocket echo server
3. Runs the probe in a Node.js WASI runtime
4. Verifies bidirectional WebSocket communication

Expected output:
```
[1/5] Building WASM probe
[2/5] Starting local echo server
[3/5] Preparing node WASI runner
[4/5] Running node WASI probe
PROBE_RESULT=PASS
[5/5] WASM websocket e2e passed
```

## API Differences

When building for WASI, certain APIs behave differently:

### Unavailable APIs

The following methods throw errors or are compile-time unavailable on WASI:

```swift
// ❌ Server mode not supported
transport.listen(on: endpoint)  // Throws TrebuchetError.invalidConfiguration

// ❌ TCP transport compiled out
TransportConfiguration.tcp(host: "0.0.0.0", port: 8080)  // Not available

// ❌ HTTP transport unavailable
TransportConfiguration.http(host: "0.0.0.0", port: 8080)  // Not available

// ❌ Actor system server helpers unavailable
TrebuchetActorSystem.forServer(host: "localhost", port: 8080)  // Unavailable
```

### Available APIs

These APIs work as expected on WASI:

```swift
// ✅ WebSocket client transport
let transport = WebSocketTransport()
try await transport.connect(to: endpoint)
try await transport.send(data, to: endpoint)

// ✅ Client configuration
let client = TrebuchetClient(transport: .webSocket(host: "server.com", port: 8080))

// ✅ Actor resolution
let actor = try client.resolve(MyActor.self, id: "actor-id")

// ✅ Message streaming
for await message in transport.incoming { ... }
```

## Troubleshooting

### Build Errors

**"No available targets compatible with wasm32-unknown-wasip1"**

Ensure you're using the swift.org toolchain (not Apple's Xcode Swift) and have installed the WASM SDK:

```bash
swift --version  # Should show swift.org toolchain
swift sdk list   # Should show swift-6.2.3-RELEASE_wasm
```

### Bundle Size Issues

WASM binaries can be large. Use optimization flags:

```bash
swift build --swift-sdk swift-6.2.3-RELEASE_wasm -c release -Xswiftc -Osize
```

Add LTO and strip options for maximum size reduction (see Build Command section).

### Browser Connection Issues

Verify the WebSocket URL scheme:
- Use `ws://` for insecure connections
- Use `wss://` for secure (TLS) connections
- Check CORS settings on your server

### Runtime Errors

Initialize the JavaScript event loop before using Trebuchet:

```swift
import JavaScriptEventLoop

JavaScriptEventLoop.installGlobalExecutor()
```

## Topics

### Transport Configuration

- ``WebSocketTransport``
- ``TransportConfiguration/webSocket(host:port:tls:)``
- ``Endpoint``

### Client API

- ``TrebuchetClient``
- ``TrebuchetActorSystem``

### Dependencies

- JavaScriptKit
- JavaScriptEventLoop
