# SwiftUI Integration

Build reactive SwiftUI apps with Trebuchet's observable connection management.

## Overview

Trebuchet provides first-class SwiftUI support with observable connection state, automatic reconnection, and multiple patterns for accessing remote actors in your views.

## Setting Up the Connection

The easiest way to integrate Trebuchet is using the `.trebuchet()` modifier at your app's root:

```swift
import SwiftUI
import Trebuchet

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuchet(transport: .webSocket(host: "api.example.com", port: 8080))
        }
    }
}
```

This automatically:
- Creates and manages the connection
- Handles auto-reconnection with exponential backoff
- Makes connection state available to all child views

### Accessing the Connection

Use `@Environment` to access the connection in any view:

```swift
struct StatusBar: View {
    @Environment(\.trebuchetConnection) private var connection

    var body: some View {
        HStack {
            Circle()
                .fill(connection?.state.isConnected == true ? .green : .red)
                .frame(width: 8, height: 8)

            Text(statusText)
        }
    }

    private var statusText: String {
        switch connection?.state {
        case .connected: return "Online"
        case .connecting: return "Connecting..."
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .disconnected: return "Offline"
        case .failed: return "Connection Failed"
        case nil: return "Not Configured"
        }
    }
}
```

## Using the @RemoteActor Property Wrapper

The ``RemoteActor`` property wrapper provides the most ergonomic way to work with remote actors:

```swift
struct GameLobbyView: View {
    @RemoteActor(id: "lobby") var lobby: GameLobby?

    var body: some View {
        if let lobby {
            LobbyContent(lobby: lobby)
        } else {
            ProgressView("Joining lobby...")
        }
    }
}
```

### Handling All States

Access the projected value (`$wrapper`) for detailed state information:

```swift
struct GameLobbyView: View {
    @RemoteActor(id: "lobby") var lobby: GameLobby?

    var body: some View {
        switch $lobby.state {
        case .disconnected:
            ContentUnavailableView(
                "Not Connected",
                systemImage: "wifi.slash",
                description: Text("Check your network connection")
            )

        case .loading:
            ProgressView("Joining lobby...")

        case .resolved(let lobby):
            LobbyContent(lobby: lobby)

        case .failed(let error):
            VStack {
                ContentUnavailableView(
                    "Failed to Join",
                    systemImage: "exclamationmark.triangle"
                )
                Button("Retry") {
                    Task { await $lobby.refresh() }
                }
            }
        }
    }
}
```

### Using RemoteActorView

For a more declarative approach, use ``RemoteActorView``:

```swift
var body: some View {
    RemoteActorView(id: "lobby", type: GameLobby.self) { lobby in
        LobbyContent(lobby: lobby)
    } loading: {
        ProgressView()
    } disconnected: {
        Text("Not connected")
    } failed: { error in
        Text("Error: \(error)")
    }
}
```

## Using @ObservedActor for Streaming State

The `@ObservedActor` property wrapper provides automatic subscription to streaming state from distributed actors, with built-in stream resumption after reconnection:

```swift
struct TodoListView: View {
    @ObservedActor("todos", observe: \TodoList.observeState)
    var state

    var body: some View {
        if let currentState = state {
            List(currentState.todos) { todo in
                Text(todo.title)
            }
        }
    }
}
```

When the connection is lost and restored, `@ObservedActor` automatically:
1. Detects the reconnection
2. Attempts to resume the stream from the last checkpoint
3. Requests missed updates from the server
4. Seamlessly continues updating the view

This ensures your SwiftUI views stay synchronized with server state even across network interruptions. For more details on stream resumption and streaming in general, see <doc:Streaming> and <doc:AdvancedStreaming>.

## View Modifiers

Trebuchet provides several view modifiers for common patterns:

### Scoped Connections

Use `.trebuchet()` to create a connection scoped to a specific view:

```swift
struct MatchmakingSheet: View {
    var body: some View {
        MatchmakingContent()
            .trebuchet(transport: .webSocket(host: "matchmaking.example.com", port: 8080))
    }
}
```

### Conditional Content

Show alternative content when disconnected:

```swift
GameView()
    .whenDisconnected {
        VStack {
            ProgressView()
            Text("Reconnecting...")
        }
    }
```

Show content based on specific connection state:

```swift
GameView()
    .whenConnectionState(.connecting) {
        ProgressView("Connecting to server...")
    }

GameView()
    .whenConnectionState(.reconnecting(1)) {
        VStack {
            ProgressView()
            Text("Connection lost. Reconnecting...")
        }
    }
```

### State Change Callbacks

React to connection state changes:

```swift
ContentView()
    .onTrebuchetStateChange { state in
        if state.isConnected {
            loadInitialData()
        }
    }
```

## Multi-Server Scenarios

Connect to multiple servers simultaneously using named connections:

```swift
TrebuchetEnvironment(
    connections: [
        "game": .webSocket(host: "game.example.com", port: 8080),
        "chat": .webSocket(host: "chat.example.com", port: 8080),
        "analytics": .webSocket(host: "analytics.example.com", port: 8080)
    ],
    defaultConnection: "game"
) {
    MainContent()
}
```

### Switching Connections

Use `.trebuchetConnection(name:)` to specify which connection a view subtree uses:

```swift
TabView {
    GameTab()
        .tabItem { Label("Game", systemImage: "gamecontroller") }

    ChatTab()
        .trebuchetConnection(name: "chat")
        .tabItem { Label("Chat", systemImage: "message") }
}
```

### Accessing the Manager

For advanced scenarios, access the ``TrebuchetConnectionManager`` directly:

```swift
struct ConnectionStatusView: View {
    @Environment(\.trebuchetConnectionManager) private var manager

    var body: some View {
        List(manager?.connectionNames ?? [], id: \.self) { name in
            if let connection = manager?[name] {
                ConnectionRow(name: name, connection: connection)
            }
        }
    }
}
```

## Configuring Reconnection

Customize reconnection behavior with ``ReconnectionPolicy``:

```swift
// Aggressive reconnection for real-time apps
ContentView()
    .trebuchet(
        transport: .webSocket(host: "realtime.example.com", port: 8080),
        reconnectionPolicy: .aggressive
    )

// Disable auto-reconnection
ContentView()
    .trebuchet(
        transport: .webSocket(host: "api.example.com", port: 8080),
        reconnectionPolicy: .disabled
    )

// Custom policy
let policy = ReconnectionPolicy(
    maxAttempts: 3,
    initialDelay: .seconds(2),
    maxDelay: .seconds(15),
    backoffMultiplier: 1.5
)
```

## Connection Events

Subscribe to connection lifecycle events for logging or custom handling:

```swift
struct ContentView: View {
    @Environment(\.trebuchetConnection) private var connection

    var body: some View {
        MainContent()
            .task {
                guard let connection else { return }
                for await event in connection.events {
                    switch event {
                    case .didConnect:
                        print("Connected!")
                    case .willReconnect(let attempt, let delay):
                        print("Reconnecting (attempt \(attempt)) in \(delay)...")
                    case .didFailWithError(let error):
                        print("Error: \(error)")
                    default:
                        break
                    }
                }
            }
    }
}
```

## Topics

### Environment Setup

- ``TrebuchetEnvironment``

### Connection Management

- ``TrebuchetConnection``
- ``TrebuchetConnectionManager``
- ``ConnectionState``
- ``ConnectionError``

### Reconnection

- ``ReconnectionPolicy``
- ``ConnectionEvent``

### Property Wrappers

- ``RemoteActor``
- ``RemoteActorView``

### View Modifiers

- ``SwiftUICore/View/trebuchet(transport:reconnectionPolicy:autoConnect:)``
- ``SwiftUICore/View/trebuchetConnection(name:)``
- ``SwiftUICore/View/whenDisconnected(placeholder:)``
- ``SwiftUICore/View/whenConnectionState(_:placeholder:)``
- ``SwiftUICore/View/onTrebuchetStateChange(perform:)``
