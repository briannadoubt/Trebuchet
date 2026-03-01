import Distributed
import Foundation
import SurrealDB
import Trebuchet
import TrebuchetSurrealDB

/// A simple CRUD example demonstrating SurrealDB ORM integration with Trebuchet.
///
/// This actor manages a todo list with basic create, read, update, and delete operations.
/// It showcases:
/// - Direct SurrealDB ORM usage without additional state management
/// - Type-safe queries using KeyPath syntax
/// - Schema auto-generation with @ID property wrapper
/// - Actor-scoped data isolation
///
/// Usage:
/// ```swift
/// let db = try await SurrealDB()
/// try await db.connect("ws://localhost:8000")
/// try await db.use(namespace: "todos", database: "todos")
///
/// let server = TrebuchetServer(transport: .webSocket(port: 8080))
/// let todoList = TodoListActor(actorSystem: server.actorSystem, database: db, actorId: "user-123")
/// await server.expose(todoList, as: "user-123-todos")
/// try await server.run()
/// ```
@Trebuchet
distributed actor TodoListActor {
    /// The SurrealDB database connection
    private let db: SurrealDB

    /// The actor ID used to scope todos to this specific actor instance
    private let actorId: String

    /// Initializes a new todo list actor.
    ///
    /// - Parameters:
    ///   - actorSystem: The Trebuchet actor system
    ///   - database: The SurrealDB connection
    ///   - actorId: A unique identifier to scope todos (e.g., user ID)
    ///
    /// This initializer automatically generates the schema for the Todo model
    /// if it doesn't already exist in the database.
    public init(
        actorSystem: TrebuchetRuntime,
        database: SurrealDB,
        actorId: String
    ) async throws {
        self.actorSystem = actorSystem
        self.db = database
        self.actorId = actorId

        // Auto-generate schema for Todo model
        try await db.defineTable(for: Todo.self)
    }

    /// Adds a new todo item to the list.
    ///
    /// - Parameter text: The text content of the todo
    /// - Returns: The created todo with its generated ID
    ///
    /// Example:
    /// ```swift
    /// let todo = try await todoList.addTodo(text: "Buy groceries")
    /// print(todo.id) // "todo:abc123"
    /// ```
    public distributed func addTodo(text: String) async throws -> Todo {
        let todo = Todo(
            text: text,
            completed: false,
            actorId: actorId,
            createdAt: Date()
        )

        return try await db.create(todo)
    }

    /// Retrieves all todos for this actor.
    ///
    /// - Returns: Array of todos sorted by creation date (newest first)
    ///
    /// Example:
    /// ```swift
    /// let todos = try await todoList.getTodos()
    /// for todo in todos {
    ///     print("\(todo.text): \(todo.completed ? "✓" : "○")")
    /// }
    /// ```
    public distributed func getTodos() async throws -> [Todo] {
        // Type-safe query using KeyPath syntax
        return try await db.query(Todo.self)
            .where(\.actorId, equals: actorId)
            .orderBy(\.createdAt, ascending: false)
            .fetch()
    }

    /// Retrieves a specific todo by ID.
    ///
    /// - Parameter id: The SurrealDB record ID (e.g., "todo:abc123")
    /// - Returns: The todo if found, nil otherwise
    ///
    /// Example:
    /// ```swift
    /// if let todo = try await todoList.getTodo(id: "todo:abc123") {
    ///     print(todo.text)
    /// }
    /// ```
    public distributed func getTodo(id: String) async throws -> Todo? {
        return try await db.select(Todo.self, id: id)
    }

    /// Toggles the completed status of a todo.
    ///
    /// - Parameter id: The SurrealDB record ID
    /// - Returns: The updated todo
    ///
    /// Example:
    /// ```swift
    /// let updated = try await todoList.toggleTodo(id: "todo:abc123")
    /// print(updated.completed) // true
    /// ```
    public distributed func toggleTodo(id: String) async throws -> Todo {
        guard var todo = try await db.select(Todo.self, id: id) else {
            throw TodoError.notFound(id)
        }

        // Verify this todo belongs to this actor
        guard todo.actorId == actorId else {
            throw TodoError.unauthorized
        }

        todo.completed.toggle()
        return try await db.update(todo)
    }

    /// Updates the text content of a todo.
    ///
    /// - Parameters:
    ///   - id: The SurrealDB record ID
    ///   - text: The new text content
    /// - Returns: The updated todo
    ///
    /// Example:
    /// ```swift
    /// let updated = try await todoList.updateTodo(id: "todo:abc123", text: "Buy organic groceries")
    /// ```
    public distributed func updateTodo(id: String, text: String) async throws -> Todo {
        guard var todo = try await db.select(Todo.self, id: id) else {
            throw TodoError.notFound(id)
        }

        // Verify this todo belongs to this actor
        guard todo.actorId == actorId else {
            throw TodoError.unauthorized
        }

        todo.text = text
        return try await db.update(todo)
    }

    /// Deletes a todo from the list.
    ///
    /// - Parameter id: The SurrealDB record ID
    ///
    /// Example:
    /// ```swift
    /// try await todoList.deleteTodo(id: "todo:abc123")
    /// ```
    public distributed func deleteTodo(id: String) async throws {
        // Verify the todo exists and belongs to this actor
        guard let todo = try await db.select(Todo.self, id: id) else {
            throw TodoError.notFound(id)
        }

        guard todo.actorId == actorId else {
            throw TodoError.unauthorized
        }

        try await db.delete(Todo.self, id: id)
    }

    /// Deletes all completed todos for this actor.
    ///
    /// - Returns: The number of todos deleted
    ///
    /// Example:
    /// ```swift
    /// let count = try await todoList.clearCompleted()
    /// print("Deleted \(count) completed todos")
    /// ```
    public distributed func clearCompleted() async throws -> Int {
        let completed = try await db.query(Todo.self)
            .where(\.actorId, equals: actorId)
            .where(\.completed, equals: true)
            .fetch()

        for todo in completed {
            try await db.delete(Todo.self, id: todo.id!)
        }

        return completed.count
    }

    /// Returns statistics about the todo list.
    ///
    /// - Returns: Statistics including total, completed, and pending counts
    ///
    /// Example:
    /// ```swift
    /// let stats = try await todoList.getStats()
    /// print("Progress: \(stats.completed)/\(stats.total)")
    /// ```
    public distributed func getStats() async throws -> TodoStats {
        let todos = try await getTodos()
        let completed = todos.filter(\.completed).count

        return TodoStats(
            total: todos.count,
            completed: completed,
            pending: todos.count - completed
        )
    }
}

// MARK: - Models

/// A todo item stored in SurrealDB.
///
/// The @ID property wrapper automatically handles SurrealDB record IDs:
/// - Auto-generated when creating new records
/// - Preserved when fetching from database
/// - Used for updates and deletes
public struct Todo: Codable, Sendable {
    /// The SurrealDB record ID (e.g., "todo:abc123")
    @ID public var id: String?

    /// The text content of the todo
    public var text: String

    /// Whether the todo is completed
    public var completed: Bool

    /// The actor ID that owns this todo (for data isolation)
    public let actorId: String

    /// When the todo was created
    public let createdAt: Date

    public init(
        id: String? = nil,
        text: String,
        completed: Bool,
        actorId: String,
        createdAt: Date
    ) {
        self.id = id
        self.text = text
        self.completed = completed
        self.actorId = actorId
        self.createdAt = createdAt
    }
}

/// Statistics about a todo list.
public struct TodoStats: Codable, Sendable {
    /// Total number of todos
    public let total: Int

    /// Number of completed todos
    public let completed: Int

    /// Number of pending todos
    public let pending: Int
}

// MARK: - Errors

/// Errors specific to todo list operations.
public enum TodoError: Error, Sendable {
    /// The requested todo was not found
    case notFound(String)

    /// The actor does not have permission to access this todo
    case unauthorized
}
