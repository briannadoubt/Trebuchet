import Foundation
import SurrealDB
@testable import TrebuchetSurrealDB
@testable import TrebuchetCloud

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helper utilities for SurrealDB integration tests
enum SurrealDBTestHelpers {
    /// SurrealDB endpoint URL
    static let endpoint = "ws://localhost:8000/rpc"

    /// Default namespace for tests
    static let namespace = "test"

    /// Default database for tests
    static let database = "trebuchet"

    /// Root credentials
    static let username = "root"
    static let password = "root"

    /// Check if SurrealDB is available and healthy
    static func isSurrealDBAvailable() async -> Bool {
        // Check if SurrealDB health endpoint is reachable
        guard let url = URL(string: "http://localhost:8000/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            return true
        } catch {
            return false
        }
    }

    /// Create a SurrealDB client configured for testing
    static func createClient() async throws -> SurrealDB {
        let db = try await SurrealDB(url: endpoint)
        try await db.connect()
        try await db.signin(.root(RootAuth(username: username, password: password)))
        try await db.use(namespace: namespace, database: database)
        return db
    }

    /// Create a SurrealDBStateStore for testing
    static func createStateStore() async throws -> SurrealDBStateStore {
        let stateStore = try await SurrealDBStateStore(
            url: endpoint,
            namespace: namespace,
            database: database,
            username: username,
            password: password
        )
        return stateStore
    }

    /// Generate a unique actor ID for test isolation
    static func uniqueActorID(prefix: String = "test-actor") -> String {
        return "\(prefix)-\(UUID().uuidString)"
    }

    /// Clean up test data from a table
    static func cleanupTable(_ tableName: String, using db: SurrealDB) async throws {
        // Delete all records from the table
        _ = try await db.query("DELETE \(tableName)")
    }

    /// Clean up entire database (use between tests)
    static func cleanupDatabase(using db: SurrealDB) async throws {
        // Get all tables
        let result: [SurrealValue] = try await db.query("INFO FOR DB")

        // Extract table names and delete all data
        if let info = result.first,
           case .object(let infoDict) = info,
           let tablesValue = infoDict["tb"],
           case .object(let tables) = tablesValue {
            for tableName in tables.keys {
                try await cleanupTable(tableName, using: db)
            }
        }
    }

    /// Clean up and close a database connection
    static func cleanup(db: SurrealDB) async throws {
        try await cleanupDatabase(using: db)
        try await db.disconnect()
    }
}

// MARK: - Test Model Definitions

/// Test model for state persistence
struct TestActorState: Codable, Sendable, Equatable {
    let name: String
    let count: Int
}

/// Test model with more complex data
struct ComplexState: Codable, Sendable, Equatable {
    let id: String
    let values: [Int]
    let metadata: [String: String]
    let timestamp: Date
}

/// Test model using SurrealModel protocol
struct TestTodo: SurrealModel {
    @ID(strategy: .uuid) var id: RecordID?
    var text: String
    var completed: Bool
    var actorId: String
    var createdAt: Date

    static var tableName: String { "test_todos" }
}

/// Test model for user data
struct TestUser: SurrealModel {
    @ID(strategy: .uuid) var id: RecordID?
    var username: String
    var email: String
    var apiKey: String
    var createdAt: Date

    static var tableName: String { "test_users" }
}

/// Test model for game room
struct TestGameRoom: SurrealModel {
    @ID(strategy: .uuid) var id: RecordID?
    var name: String
    var maxPlayers: Int
    var actorId: String

    static var tableName: String { "test_game_rooms" }
}

/// Test edge model for relationships
struct TestPlayerInRoom: EdgeModel {
    typealias From = TestUser
    typealias To = TestGameRoom

    var joinedAt: Date
    var role: String

    static var tableName: String { "player_in_room" }
}
