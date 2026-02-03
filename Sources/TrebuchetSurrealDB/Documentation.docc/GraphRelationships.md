# Graph Relationships

Model complex relationships between actors and entities using SurrealDB's graph capabilities.

## Overview

SurrealDB supports native graph relationships through edge tables, enabling you to model many-to-many relationships with metadata. This is perfect for:

- Players in game rooms
- Users in organizations
- Products in categories
- Social connections

## Edge Tables

Edge tables connect two entity types with optional metadata:

```swift
// Node: Game Room
struct GameRoom: Codable, Sendable {
    @ID var id: String?
    var name: String
    var maxPlayers: Int
    var createdAt: Date

    static var tableName: String { "game_rooms" }
}

// Node: Player
struct Player: Codable, Sendable {
    @ID var id: String?
    var username: String
    var score: Int
    var joinedAt: Date

    static var tableName: String { "players" }
}

// Edge: Player in Room
struct PlayerInRoom: Codable, Sendable {
    @ID var id: String?
    var from: String  // Player ID
    var to: String    // Room ID
    var team: String?
    var joinedAt: Date

    static var tableName: String { "player_in_room" }
}
```

## Creating Relationships

Use the `relate` API to create relationships:

```swift
@Trebuchet
distributed actor GameRoom {
    private let db: SurrealDB

    distributed func addPlayer(
        _ playerId: String,
        team: String? = nil
    ) async throws {
        // Verify room exists and has capacity
        guard let room = try await db.select(id.id) as GameRoom? else {
            throw GameRoomError.notFound
        }

        let currentPlayers = try await db.query(
            PlayerInRoom.self,
            where: [\.to == id.id]
        )

        guard currentPlayers.count < room.maxPlayers else {
            throw GameRoomError.roomFull
        }

        // Create relationship
        let edge = PlayerInRoom(
            from: playerId,
            to: id.id,
            team: team,
            joinedAt: Date()
        )

        try await db.relate(
            from: RecordID(playerId)!,
            via: PlayerInRoom.tableName,
            to: RecordID(id.id)!,
            data: edge
        )
    }
}
```

## Querying Relationships

### Get All Related Entities

```swift
// Get all players in a room
distributed func getPlayers() async throws -> [Player] {
    // Query edge table
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [\.to == id.id]
    )

    // Load player entities
    var players: [Player] = []
    for edge in edges {
        if let player = try await db.select(edge.from) as Player? {
            players.append(player)
        }
    }
    return players
}
```

### Filter by Relationship Metadata

```swift
// Get all players on a specific team
distributed func getPlayersOnTeam(_ team: String) async throws -> [Player] {
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [
            \.to == id.id,
            \.team == team
        ]
    )

    var players: [Player] = []
    for edge in edges {
        if let player = try await db.select(edge.from) as Player? {
            players.append(player)
        }
    }
    return players
}
```

### Bidirectional Queries

```swift
// In Player actor: Get all rooms for this player
@Trebuchet
distributed actor PlayerActor {
    distributed func getRooms() async throws -> [GameRoom] {
        let edges = try await db.query(
            PlayerInRoom.self,
            where: [\.from == id.id]
        )

        var rooms: [GameRoom] = []
        for edge in edges {
            if let room = try await db.select(edge.to) as GameRoom? {
                rooms.append(room)
            }
        }
        return rooms
    }
}
```

## Removing Relationships

```swift
distributed func removePlayer(_ playerId: String) async throws {
    // Find the edge
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [
            \.from == playerId,
            \.to == id.id
        ]
    )

    // Delete all matching edges
    for edge in edges {
        guard let edgeId = edge.id else { continue }
        try await db.delete(edgeId)
    }
}
```

## Advanced Patterns

### Many-to-Many with Properties

Store additional metadata on relationships:

```swift
struct PlayerInRoom: Codable, Sendable {
    @ID var id: String?
    var from: String
    var to: String
    var team: String?
    var role: PlayerRole
    var joinedAt: Date
    var points: Int
    var achievements: [String]

    enum PlayerRole: String, Codable {
        case leader
        case member
        case spectator
    }
}
```

### Relationship Aggregations

Compute statistics across relationships:

```swift
distributed func getTeamStats() async throws -> [String: TeamStats] {
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [\.to == id.id]
    )

    var teamStats: [String: TeamStats] = [:]

    for edge in edges {
        guard let team = edge.team else { continue }

        if teamStats[team] == nil {
            teamStats[team] = TeamStats(
                playerCount: 0,
                totalPoints: 0
            )
        }

        teamStats[team]?.playerCount += 1
        teamStats[team]?.totalPoints += edge.points
    }

    return teamStats
}
```

### Cascading Deletes

Clean up relationships when deleting entities:

```swift
distributed func delete() async throws {
    // Delete all player relationships
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [\.to == id.id]
    )

    for edge in edges {
        guard let edgeId = edge.id else { continue }
        try await db.delete(edgeId)
    }

    // Delete the room itself
    try await db.delete(id.id)
}
```

### Relationship Validation

Enforce business rules on relationships:

```swift
distributed func addPlayer(_ playerId: String, team: String?) async throws {
    // Check capacity
    let currentPlayers = try await db.query(
        PlayerInRoom.self,
        where: [\.to == id.id]
    )

    guard currentPlayers.count < maxPlayers else {
        throw GameRoomError.roomFull
    }

    // Check team balance if team specified
    if let team = team {
        let teamCount = currentPlayers.filter { $0.team == team }.count
        let otherTeamCount = currentPlayers.filter { $0.team != team }.count

        guard abs(teamCount - otherTeamCount) <= 1 else {
            throw GameRoomError.teamsImbalanced
        }
    }

    // Create relationship
    // ...
}
```

## Leaderboards

Use relationships to build leaderboards:

```swift
distributed func getLeaderboard() async throws -> [LeaderboardEntry] {
    // Get all players in this room
    let edges = try await db.query(
        PlayerInRoom.self,
        where: [\.to == id.id],
        orderBy: [(\.points, false)]  // Highest points first
    )

    var leaderboard: [LeaderboardEntry] = []
    for (index, edge) in edges.enumerated() {
        if let player = try await db.select(edge.from) as Player? {
            leaderboard.append(LeaderboardEntry(
                rank: index + 1,
                playerId: player.id!,
                username: player.username,
                points: edge.points,
                team: edge.team
            ))
        }
    }

    return leaderboard
}
```

## Best Practices

1. **Use descriptive edge table names** (`player_in_room`, not `player_room`)
2. **Store metadata on edges** rather than duplicating in nodes
3. **Always clean up relationships** when deleting entities
4. **Validate relationship constraints** before creation
5. **Use indexes on from/to fields** for performance
6. **Batch relationship queries** instead of individual lookups

## Complete Example

See `Examples/SurrealDB/GameRoomActor.swift` for a complete implementation with:
- Edge table creation
- Relationship management
- Team assignment
- Leaderboards
- Statistics aggregation

## Graph Query Syntax

For complex graph traversals, use SurrealQL directly:

```swift
// Find friends of friends
let query = """
    SELECT ->friend->person.* FROM person:\(userId)
    """
let results = try await db.query(query)
```

## See Also

- <doc:DirectORMUsage>
- <doc:GettingStarted>
- ``SurrealDBStateStore``
