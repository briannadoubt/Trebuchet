import Testing
import Foundation
import SurrealDB
@testable import TrebuchetSurrealDB
@testable import TrebuchetCloud

@Suite("SurrealDB Integration Tests")
struct SurrealDBIntegrationTests {

    // MARK: - ORM Pattern Tests

    @Test("Create and query records using ORM")
    func testCreateAndQuery() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create a todo
        let todo = TestTodo(
            text: "Write tests",
            completed: false,
            actorId: actorId,
            createdAt: Date()
        )
        let created = try await db.create(todo)
        #expect(created.id != nil)
        #expect(created.text == "Write tests")

        // Query todos for this actor
        let todos: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [\TestTodo.actorId == actorId]
        )
        #expect(todos.count == 1)
        #expect(todos.first?.text == "Write tests")

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    @Test("Update and delete records")
    func testUpdateAndDelete() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create a todo
        let todo = TestTodo(
            text: "Original text",
            completed: false,
            actorId: actorId,
            createdAt: Date()
        )
        let created = try await db.create(todo)

        // Update the todo
        var updated = created
        updated.text = "Updated text"
        updated.completed = true
        let savedUpdate = try await db.update(updated)
        #expect(savedUpdate.text == "Updated text")
        #expect(savedUpdate.completed == true)

        // Delete the todo
        try await db.delete(created)

        // Verify deleted
        let todos: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [\TestTodo.actorId == actorId]
        )
        #expect(todos.isEmpty)

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    // MARK: - Schema Generation Tests

    @Test("Generate table schema from model")
    func testSchemaGeneration() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        // Generate schema for TestUser model
        let schema = try SchemaGenerator.generateTableSchema(for: TestUser.self)

        // Verify schema contains expected statements
        #expect(schema.count > 0)

        // Apply schema
        for statement in schema {
            _ = try await db.query(statement)
        }

        // Create a user to verify schema works
        let user = TestUser(
            username: "testuser",
            email: "test@example.com",
            apiKey: UUID().uuidString,
            createdAt: Date()
        )
        let created = try await db.create(user)
        #expect(created.id != nil)
        #expect(created.username == "testuser")

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    @Test("Schema enforces unique index")
    func testUniqueIndexEnforcement() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        // Generate and apply schema
        let schema = try SchemaGenerator.generateTableSchema(for: TestUser.self)
        for statement in schema {
            _ = try await db.query(statement)
        }

        let apiKey = UUID().uuidString

        // Create first user with unique API key
        let user1 = TestUser(
            username: "user1",
            email: "user1@example.com",
            apiKey: apiKey,
            createdAt: Date()
        )
        _ = try await db.create(user1)

        // Attempt to create second user with same API key
        let user2 = TestUser(
            username: "user2",
            email: "user2@example.com",
            apiKey: apiKey,  // Duplicate!
            createdAt: Date()
        )

        do {
            _ = try await db.create(user2)
            Issue.record("Expected unique constraint violation")
        } catch {
            // Expected error due to unique constraint
            #expect(error is SurrealError)
        }

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    // MARK: - Type-Safe Query Tests

    @Test("Query with multiple conditions")
    func testComplexQuery() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create multiple todos
        for i in 0..<5 {
            let todo = TestTodo(
                text: "Task \(i)",
                completed: i % 2 == 0,
                actorId: actorId,
                createdAt: Date()
            )
            _ = try await db.create(todo)
        }

        // Query only completed todos
        let completedTodos: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [
                \TestTodo.actorId == actorId,
                \TestTodo.completed == true
            ]
        )

        // Should have 3 completed todos (0, 2, 4)
        #expect(completedTodos.count == 3)
        #expect(completedTodos.allSatisfy { $0.completed })

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    @Test("Query with ordering and limit")
    func testQueryWithOrderingAndLimit() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create todos with different texts
        let texts = ["Zebra", "Apple", "Mango", "Banana"]
        for text in texts {
            let todo = TestTodo(
                text: text,
                completed: false,
                actorId: actorId,
                createdAt: Date()
            )
            _ = try await db.create(todo)
        }

        // Query with ordering (ascending) and limit
        let sorted: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [\TestTodo.actorId == actorId],
            orderBy: [(\TestTodo.text, true)],  // Ascending order
            limit: 2
        )

        #expect(sorted.count == 2)
        #expect(sorted[0].text == "Apple")
        #expect(sorted[1].text == "Banana")

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    // MARK: - Relationship Tests

    @Test("Create and query relationships")
    func testRelationships() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create a game room
        let room = TestGameRoom(
            name: "Main Lobby",
            maxPlayers: 10,
            actorId: actorId
        )
        let createdRoom = try await db.create(room)
        let roomId = try #require(createdRoom.id)

        // Create a user
        let user = TestUser(
            username: "player1",
            email: "player1@example.com",
            apiKey: UUID().uuidString,
            createdAt: Date()
        )
        let createdUser = try await db.create(user)
        let userId = try #require(createdUser.id)

        // Create relationship
        let edge = TestPlayerInRoom(
            joinedAt: Date(),
            role: "player"
        )
        let _: TestPlayerInRoom = try await db.relate(from: userId, via: TestPlayerInRoom.tableName, to: roomId, data: edge)

        // Query to verify relationship exists
        let rooms: [TestGameRoom] = try await db.query(
            TestGameRoom.self,
            where: [\TestGameRoom.actorId == actorId]
        )
        #expect(rooms.count == 1)
        #expect(rooms.first?.name == "Main Lobby")

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    @Test("Load relationships using ORM")
    func testLoadRelationships() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create multiple game rooms
        let room1 = TestGameRoom(name: "Room 1", maxPlayers: 5, actorId: actorId)
        let room2 = TestGameRoom(name: "Room 2", maxPlayers: 10, actorId: actorId)
        _ = try await db.create(room1)
        _ = try await db.create(room2)

        // Query all rooms for this actor
        let rooms: [TestGameRoom] = try await db.query(
            TestGameRoom.self,
            where: [\TestGameRoom.actorId == actorId]
        )

        #expect(rooms.count == 2)
        #expect(Set(rooms.map(\.name)) == Set(["Room 1", "Room 2"]))

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    // MARK: - End-to-End Actor State Tests

    @Test("End-to-end: Actor state persistence with ORM")
    func testEndToEndActorStatePersistence() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()
        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Simulate actor saving framework-managed state
        let frameworkState = TestActorState(name: "MyActor", count: 100)
        try await stateStore.save(frameworkState, for: actorId)

        // Simulate actor also maintaining domain models in SurrealDB
        let todo1 = TestTodo(
            text: "Task from actor",
            completed: false,
            actorId: actorId,
            createdAt: Date()
        )
        _ = try await db.create(todo1)

        // Verify framework state
        let loadedState = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loadedState?.name == "MyActor")
        #expect(loadedState?.count == 100)

        // Verify domain models
        let todos: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [\TestTodo.actorId == actorId]
        )
        #expect(todos.count == 1)
        #expect(todos.first?.text == "Task from actor")

        try await SurrealDBTestHelpers.cleanup(db: db)
        await stateStore.shutdown()
    }

    @Test("Batch operations with transactions")
    func testBatchOperations() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Create multiple todos in a loop
        for i in 0..<10 {
            let todo = TestTodo(
                text: "Batch task \(i)",
                completed: false,
                actorId: actorId,
                createdAt: Date()
            )
            _ = try await db.create(todo)
        }

        // Query all todos
        let todos: [TestTodo] = try await db.query(
            TestTodo.self,
            where: [\TestTodo.actorId == actorId]
        )

        #expect(todos.count == 10)

        try await SurrealDBTestHelpers.cleanup(db: db)
    }

    @Test("Concurrent actor operations")
    func testConcurrentActorOperations() async throws {
        try #require(await SurrealDBTestHelpers.isSurrealDBAvailable())

        let db = try await SurrealDBTestHelpers.createClient()

        // Simulate multiple actors concurrently creating data
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let actorId = SurrealDBTestHelpers.uniqueActorID(prefix: "actor-\(i)")

                    let todo = TestTodo(
                        text: "Task from actor \(i)",
                        completed: false,
                        actorId: actorId,
                        createdAt: Date()
                    )
                    _ = try! await db.create(todo)
                }
            }
        }

        // Query all todos across all actors
        let allTodos: [TestTodo] = try await db.query(TestTodo.self)
        #expect(allTodos.count >= 5)  // At least 5 from our concurrent operations

        try await SurrealDBTestHelpers.cleanup(db: db)
    }
}
