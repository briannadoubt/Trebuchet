# SwiftUI Integration

Build reactive SwiftUI apps with Trebuche's observable connection management.

## Overview

Trebuche provides first-class SwiftUI support with observable connection state, automatic reconnection, and multiple patterns for accessing remote actors in your views.

## Setting Up the Connection

The easiest way to integrate Trebuche is using the `.trebuche()` modifier at your app's root:

```swift
import SwiftUI
import Trebuche

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuche(transport: .webSocket(host: "api.example.com", port: 8080))
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

## View Modifiers

Trebuche provides several view modifiers for common patterns:

### Scoped Connections

Use `.trebuche()` to create a connection scoped to a specific view:

```swift
struct MatchmakingSheet: View {
    var body: some View {
        MatchmakingContent()
            .trebuche(transport: .webSocket(host: "matchmaking.example.com", port: 8080))
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
    .trebuche(
        transport: .webSocket(host: "realtime.example.com", port: 8080),
        reconnectionPolicy: .aggressive
    )

// Disable auto-reconnection
ContentView()
    .trebuche(
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

- ``SwiftUICore/View/trebuche(transport:reconnectionPolicy:autoConnect:)``
- ``SwiftUICore/View/trebuchetConnection(name:)``
- ``SwiftUICore/View/whenDisconnected(placeholder:)``
- ``SwiftUICore/View/whenConnectionState(_:placeholder:)``
- ``SwiftUICore/View/onTrebuchetStateChange(perform:)``
