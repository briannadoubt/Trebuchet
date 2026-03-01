import Distributed
import Foundation
import SurrealDB
import Trebuchet
import TrebuchetSurrealDB

/// A graph relationships example demonstrating SurrealDB ORM integration with Trebuchet.
///
/// This actor manages a game room with players, showcasing:
/// - Graph database relationships using edge tables
/// - @Relation property wrapper for related entities
/// - Type-safe graph traversal queries
/// - Schema generation for nodes and edges
/// - Many-to-many relationships with metadata
///
/// Usage:
/// ```swift
/// let db = try await SurrealDB()
/// try await db.connect("ws://localhost:8000")
/// try await db.use(namespace: "game", database: "game")
///
/// let server = TrebuchetServer(transport: .webSocket(port: 8080))
/// let room = GameRoomActor(actorSystem: server.actorSystem, database: db, roomId: "main-lobby")
/// await server.expose(room, as: "main-lobby")
/// try await server.run()
/// ```
@Trebuchet
distributed actor GameRoomActor {
    /// The SurrealDB database connection
    private let db: SurrealDB

    /// The unique identifier for this game room
    private let roomId: String

    /// Maximum number of players allowed in the room
    private let maxPlayers: Int

    /// Initializes a new game room actor.
    ///
    /// - Parameters:
    ///   - actorSystem: The Trebuchet actor system
    ///   - database: The SurrealDB connection
    ///   - roomId: A unique identifier for this room
    ///   - maxPlayers: Maximum number of players (default: 4)
    ///
    /// This initializer automatically generates schemas for:
    /// - GameRoom node table
    /// - Player node table
    /// - PlayerInRoom edge table
    public init(
        actorSystem: TrebuchetRuntime,
        database: SurrealDB,
        roomId: String,
        maxPlayers: Int = 4
    ) async throws {
        self.actorSystem = actorSystem
        self.db = database
        self.roomId = roomId
        self.maxPlayers = maxPlayers

        // Auto-generate schemas for all models
        try await db.defineTable(for: GameRoom.self)
        try await db.defineTable(for: Player.self)
        try await db.defineTable(for: PlayerInRoom.self)

        // Create the room if it doesn't exist
        try await ensureRoomExists()
    }

    /// Ensures the game room record exists in the database.
    private func ensureRoomExists() async throws {
        let existing = try await db.select(GameRoom.self, id: "game_room:\(roomId)")

        if existing == nil {
            let room = GameRoom(
                id: "game_room:\(roomId)",
                name: roomId,
                maxPlayers: maxPlayers,
                createdAt: Date()
            )
            _ = try await db.create(room)
        }
    }

    /// Adds a player to the game room.
    ///
    /// This creates both the player node and the relationship edge.
    ///
    /// - Parameters:
    ///   - playerId: Unique player identifier
    ///   - name: Display name for the player
    ///   - team: Optional team assignment
    /// - Returns: The created player
    ///
    /// Example:
    /// ```swift
    /// let player = try await room.addPlayer(
    ///     playerId: "player-123",
    ///     name: "Alice",
    ///     team: .red
    /// )
    /// ```
    public distributed func addPlayer(
        playerId: String,
        name: String,
        team: Team? = nil
    ) async throws -> Player {
        // Check if room is full
        let currentPlayers = try await getPlayers()
        guard currentPlayers.count < maxPlayers else {
            throw GameRoomError.roomFull
        }

        // Check if player already exists
        if let existing = try await db.select(Player.self, id: "player:\(playerId)") {
            // Player exists, check if already in this room
            let inRoom = try await isPlayerInRoom(playerId: playerId)
            if inRoom {
                throw GameRoomError.playerAlreadyInRoom
            }

            // Add existing player to room
            try await createPlayerRoomRelationship(player: existing, team: team)
            return existing
        }

        // Create new player
        let player = Player(
            id: "player:\(playerId)",
            name: name,
            score: 0,
            joinedAt: Date()
        )
        let created = try await db.create(player)

        // Create relationship
        try await createPlayerRoomRelationship(player: created, team: team)

        return created
    }

    /// Creates a relationship between a player and this room.
    private func createPlayerRoomRelationship(player: Player, team: Team?) async throws {
        let edge = PlayerInRoom(
            from: player.id!,
            to: "game_room:\(roomId)",
            team: team,
            joinedAt: Date()
        )
        _ = try await db.create(edge)
    }

    /// Checks if a player is in this room.
    private func isPlayerInRoom(playerId: String) async throws -> Bool {
        let edges = try await db.query(PlayerInRoom.self)
            .where(\.from, equals: "player:\(playerId)")
            .where(\.to, equals: "game_room:\(roomId)")
            .fetch()

        return !edges.isEmpty
    }

    /// Retrieves all players in the game room.
    ///
    /// This uses graph traversal to fetch players through the relationship edge.
    ///
    /// - Returns: Array of players with their team assignments
    ///
    /// Example:
    /// ```swift
    /// let players = try await room.getPlayers()
    /// for player in players {
    ///     print("\(player.name) - \(player.team?.rawValue ?? "no team")")
    /// }
    /// ```
    public distributed func getPlayers() async throws -> [PlayerWithTeam] {
        // Query all edges connecting to this room
        let edges = try await db.query(PlayerInRoom.self)
            .where(\.to, equals: "game_room:\(roomId)")
            .orderBy(\.joinedAt, ascending: true)
            .fetch()

        // Fetch player details for each edge
        var playersWithTeams: [PlayerWithTeam] = []
        for edge in edges {
            if let player = try await db.select(Player.self, id: edge.from) {
                playersWithTeams.append(PlayerWithTeam(
                    player: player,
                    team: edge.team,
                    joinedAt: edge.joinedAt
                ))
            }
        }

        return playersWithTeams
    }

    /// Retrieves all players on a specific team.
    ///
    /// - Parameter team: The team to filter by
    /// - Returns: Array of players on the specified team
    ///
    /// Example:
    /// ```swift
    /// let redTeam = try await room.getPlayersByTeam(.red)
    /// ```
    public distributed func getPlayersByTeam(_ team: Team) async throws -> [Player] {
        let edges = try await db.query(PlayerInRoom.self)
            .where(\.to, equals: "game_room:\(roomId)")
            .where(\.team, equals: team)
            .fetch()

        var players: [Player] = []
        for edge in edges {
            if let player = try await db.select(Player.self, id: edge.from) {
                players.append(player)
            }
        }

        return players
    }

    /// Assigns or changes a player's team.
    ///
    /// - Parameters:
    ///   - playerId: The player identifier
    ///   - team: The new team assignment
    ///
    /// Example:
    /// ```swift
    /// try await room.setPlayerTeam(playerId: "player-123", team: .blue)
    /// ```
    public distributed func setPlayerTeam(playerId: String, team: Team) async throws {
        // Find the edge
        let edges = try await db.query(PlayerInRoom.self)
            .where(\.from, equals: "player:\(playerId)")
            .where(\.to, equals: "game_room:\(roomId)")
            .fetch()

        guard var edge = edges.first else {
            throw GameRoomError.playerNotInRoom
        }

        // Update the team
        edge.team = team
        _ = try await db.update(edge)
    }

    /// Updates a player's score.
    ///
    /// - Parameters:
    ///   - playerId: The player identifier
    ///   - points: Points to add (can be negative)
    /// - Returns: The updated player
    ///
    /// Example:
    /// ```swift
    /// let player = try await room.addScore(playerId: "player-123", points: 10)
    /// print("New score: \(player.score)")
    /// ```
    public distributed func addScore(playerId: String, points: Int) async throws -> Player {
        guard var player = try await db.select(Player.self, id: "player:\(playerId)") else {
            throw GameRoomError.playerNotFound
        }

        // Verify player is in this room
        let inRoom = try await isPlayerInRoom(playerId: playerId)
        guard inRoom else {
            throw GameRoomError.playerNotInRoom
        }

        player.score += points
        return try await db.update(player)
    }

    /// Removes a player from the game room.
    ///
    /// This only removes the relationship, not the player node itself.
    ///
    /// - Parameter playerId: The player identifier
    ///
    /// Example:
    /// ```swift
    /// try await room.removePlayer(playerId: "player-123")
    /// ```
    public distributed func removePlayer(playerId: String) async throws {
        // Find and delete the edge
        let edges = try await db.query(PlayerInRoom.self)
            .where(\.from, equals: "player:\(playerId)")
            .where(\.to, equals: "game_room:\(roomId)")
            .fetch()

        guard let edge = edges.first else {
            throw GameRoomError.playerNotInRoom
        }

        try await db.delete(PlayerInRoom.self, id: edge.id!)
    }

    /// Retrieves statistics about the game room.
    ///
    /// - Returns: Room statistics including player count and team distribution
    ///
    /// Example:
    /// ```swift
    /// let stats = try await room.getStats()
    /// print("Players: \(stats.playerCount)/\(stats.maxPlayers)")
    /// ```
    public distributed func getStats() async throws -> RoomStats {
        let playersWithTeams = try await getPlayers()

        let teamDistribution = Dictionary(grouping: playersWithTeams) { $0.team }
            .mapValues { $0.count }

        let totalScore = playersWithTeams.reduce(0) { $0 + $1.player.score }

        return RoomStats(
            roomId: roomId,
            playerCount: playersWithTeams.count,
            maxPlayers: maxPlayers,
            teamDistribution: teamDistribution,
            totalScore: totalScore
        )
    }

    /// Retrieves the leaderboard sorted by score.
    ///
    /// - Parameter limit: Maximum number of players to return (default: 10)
    /// - Returns: Array of players sorted by score (highest first)
    ///
    /// Example:
    /// ```swift
    /// let top3 = try await room.getLeaderboard(limit: 3)
    /// ```
    public distributed func getLeaderboard(limit: Int = 10) async throws -> [Player] {
        let playersWithTeams = try await getPlayers()

        return playersWithTeams
            .map(\.player)
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Models

/// A game room node in the graph.
public struct GameRoom: Codable, Sendable {
    /// The SurrealDB record ID (e.g., "game_room:main-lobby")
    @ID public var id: String?

    /// Display name for the room
    public var name: String

    /// Maximum number of players allowed
    public let maxPlayers: Int

    /// When the room was created
    public let createdAt: Date

    public init(
        id: String? = nil,
        name: String,
        maxPlayers: Int,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.maxPlayers = maxPlayers
        self.createdAt = createdAt
    }
}

/// A player node in the graph.
public struct Player: Codable, Sendable {
    /// The SurrealDB record ID (e.g., "player:abc123")
    @ID public var id: String?

    /// Display name
    public var name: String

    /// Current score
    public var score: Int

    /// When the player first joined any room
    public let joinedAt: Date

    public init(
        id: String? = nil,
        name: String,
        score: Int,
        joinedAt: Date
    ) {
        self.id = id
        self.name = name
        self.score = score
        self.joinedAt = joinedAt
    }
}

/// An edge representing a player's membership in a room.
///
/// This is a relationship table that connects players to rooms
/// with additional metadata like team assignment.
public struct PlayerInRoom: Codable, Sendable {
    /// The SurrealDB edge record ID
    @ID public var id: String?

    /// The player record ID (source)
    public let from: String

    /// The room record ID (target)
    public let to: String

    /// Optional team assignment
    public var team: Team?

    /// When the player joined this specific room
    public let joinedAt: Date

    public init(
        id: String? = nil,
        from: String,
        to: String,
        team: Team? = nil,
        joinedAt: Date
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.team = team
        self.joinedAt = joinedAt
    }
}

/// Team assignment for players.
public enum Team: String, Codable, Sendable {
    case red
    case blue
    case green
    case yellow
}

/// A player with their team assignment.
public struct PlayerWithTeam: Codable, Sendable {
    public let player: Player
    public let team: Team?
    public let joinedAt: Date
}

/// Statistics about a game room.
public struct RoomStats: Codable, Sendable {
    /// The room identifier
    public let roomId: String

    /// Current number of players
    public let playerCount: Int

    /// Maximum allowed players
    public let maxPlayers: Int

    /// Number of players per team
    public let teamDistribution: [Team?: Int]

    /// Combined score of all players
    public let totalScore: Int
}

// MARK: - Errors

/// Errors specific to game room operations.
public enum GameRoomError: Error, Sendable {
    /// The room has reached maximum capacity
    case roomFull

    /// The player is already in this room
    case playerAlreadyInRoom

    /// The player is not in this room
    case playerNotInRoom

    /// The player was not found in the database
    case playerNotFound
}
