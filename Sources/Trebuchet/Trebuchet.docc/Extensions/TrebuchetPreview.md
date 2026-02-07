# ``Trebuchet/TrebuchetPreview``

Helper for accessing the shared local server in SwiftUI previews.

## Overview

`TrebuchetPreview` provides static access to the shared ``LocalTransport/shared`` server for easy actor exposure and configuration in SwiftUI previews.

## Basic Usage

```swift
#Preview("Game Lobby") {
    LobbyView()
        .trebuchet(transport: .local)
        .task {
            let lobby = GameLobby(actorSystem: TrebuchetPreview.server.actorSystem)
            await lobby.addPlayer(Player(name: "Alice"))
            await TrebuchetPreview.expose(lobby, as: "lobby")
        }
}
```

## Custom PreviewModifier

For reusable preview setups, create a custom `PreviewModifier` with shared context:

```swift
struct GameRoomPreview: PreviewModifier {
    static func makeSharedContext() async throws {
        let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
        await room.addPlayers([
            Player(name: "Alice"),
            Player(name: "Bob")
        ])
        await TrebuchetPreview.expose(room, as: "game-room")
    }

    func body(content: Content, context: Void) -> some View {
        content.trebuchet(transport: .local)
    }
}

#Preview("Game Room", traits: .modifier(GameRoomPreview())) {
    GameRoomView()
}
```

## Streaming Configuration

Configure streaming for preview actors:

```swift
#Preview {
    GameView()
        .trebuchet(transport: .local)
        .task {
            await TrebuchetPreview.configureStreaming(
                for: GameRoomStreaming.self,
                method: "observePlayers"
            ) { await $0.observePlayers() }

            let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
            await TrebuchetPreview.expose(room, as: "room")
        }
}
```

## Topics

### Server Access

- ``server``

### Actor Management

- ``expose(_:as:)``

### Streaming Configuration

- ``configureStreaming(for:method:observe:)``

### See Also

- <doc:LocalTransport>
- ``TrebuchetPreviewModifier``
- ``TrebuchetLocal``
