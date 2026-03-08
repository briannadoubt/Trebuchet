/// TrebuchetSurrealDB - SurrealDB integration for Trebuchet distributed actors
///
/// This module provides seamless integration between Trebuchet distributed actors and SurrealDB,
/// enabling type-safe, ORM-based data persistence with automatic schema generation.
///
/// ## Overview
///
/// TrebuchetSurrealDB builds on the surrealdb-swift ORM to provide:
/// - **Type-safe models** using `SurrealModel` protocol
/// - **Automatic schema generation** from Swift types
/// - **ActorStateStore implementation** for framework-managed state
/// - **Direct ORM access** for custom domain models
/// - **Graph relationships** for related actors and entities
///
/// ## Quick Start
///
/// ### Using ActorStateStore Pattern
///
/// ```swift
/// // Simple state persistence
/// @Trebuchet
/// distributed actor Counter: StatefulActor {
///     struct State: Codable, Sendable {
///         var count: Int = 0
///     }
///
///     let stateStore: SurrealDBStateStore
///     var state = State()
///
///     init(actorSystem: TrebuchetRuntime, stateStore: SurrealDBStateStore) {
///         self.actorSystem = actorSystem
///         self.stateStore = stateStore
///     }
///
///     distributed func increment() async throws {
///         state.count += 1
///         try await persistState()
///     }
/// }
/// ```
///
/// ### Using Direct ORM Access
///
/// ```swift
/// import SurrealDB
///
/// @Trebuchet
/// distributed actor TodoList {
///     private let db: SurrealDB
///
///     struct Todo: SurrealModel {
///         @ID(strategy: .uuid) var id: RecordID?
///         var text: String
///         var completed: Bool
///         var actorId: String
///
///         static var tableName: String { "todos" }
///     }
///
///     init(actorSystem: TrebuchetRuntime, db: SurrealDB) async throws {
///         self.actorSystem = actorSystem
///         self.db = db
///
///         // Auto-generate schema from Swift type
///         let schema = try SchemaGenerator.generateTableSchema(for: Todo.self)
///         for statement in schema {
///             try await db.query(statement)
///         }
///     }
///
///     distributed func addTodo(_ text: String) async throws -> Todo {
///         var todo = Todo(text: text, completed: false, actorId: id.id)
///         return try await db.create(todo)
///     }
///
///     distributed func getTodos() async throws -> [Todo] {
///         return try await db.query(
///             Todo.self,
///             where: [\Todo.actorId == id.id]
///         )
///     }
/// }
/// ```
///
/// ## Configuration
///
/// ### Development
///
/// ```yaml
/// # trebuchet.yaml
/// state:
///   type: surrealdb
/// ```
///
/// The `trebuchet dev` command automatically starts a SurrealDB container at localhost:8000.
///
/// ### Production
///
/// ```swift
/// // Initialize SurrealDB client
/// let db = try await SurrealDB(url: "ws://your-server:8000/rpc")
/// try await db.connect()
/// try await db.signin(.root(RootAuth(username: "root", password: "root")))
/// try await db.use(namespace: "production", database: "myapp")
///
/// // Create state store
/// let stateStore = try await SurrealDBStateStore(
///     url: "ws://your-server:8000/rpc",
///     namespace: "production",
///     database: "myapp"
/// )
///
/// // Use with CloudGateway
/// let gateway = CloudGateway(configuration: .init(
///     stateStore: stateStore,
///     // ... other config
/// ))
/// ```
///
/// ## Features
///
/// ### Type-Safe Models
///
/// Define models using Swift types with property wrappers:
///
/// ```swift
/// struct User: SurrealModel {
///     @ID(strategy: .uuid) var id: RecordID?
///     var username: String
///     var email: String
///     @Index(type: .unique) var apiKey: String
///     var createdAt: Date
///
///     static var tableName: String { "users" }
/// }
/// ```
///
/// ### Automatic Schema Generation
///
/// ```swift
/// let schema = try SchemaGenerator.generateTableSchema(for: User.self)
/// for statement in schema {
///     try await db.query(statement)
/// }
/// ```
///
/// ### Graph Relationships
///
/// ```swift
/// struct GameRoom: SurrealModel {
///     @ID(strategy: .uuid) var id: RecordID?
///     var name: String
///     @Relation(edge: PlayerInRoom.self, direction: .in) var players: [Player]
/// }
///
/// struct Player: SurrealModel {
///     @ID(strategy: .uuid) var id: RecordID?
///     var username: String
///     @Relation(edge: PlayerInRoom.self, direction: .out) var rooms: [GameRoom]
/// }
///
/// struct PlayerInRoom: EdgeModel {
///     typealias From = Player
///     typealias To = GameRoom
///     var joinedAt: Date
/// }
/// ```
///
/// ### Type-Safe Queries
///
/// ```swift
/// // Query with conditions
/// let activePlayers = try await db.query(
///     Player.self,
///     where: [\Player.lastSeen > Date().addingTimeInterval(-3600)],
///     orderBy: [(\Player.username, true)],
///     limit: 50
/// )
///
/// // Load relationships
/// let playerRooms = try await player.load(\.rooms, using: db)
/// ```
///
/// ## Topics
///
/// ### State Management
///
/// - ``SurrealDBStateStore``
/// - ``StatefulActor``
///
/// ### Configuration
///
/// - ``SurrealDBConfiguration``
///
/// ### Extensions
///
/// - ``CloudGateway`` extensions for SurrealDB
///
@_exported import SurrealDB
@_exported import TrebuchetCloud

public struct TrebuchetSurrealDB {
    /// The version of TrebuchetSurrealDB
    public static let version = "0.1.0"
}
