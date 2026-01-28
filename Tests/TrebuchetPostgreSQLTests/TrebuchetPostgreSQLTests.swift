import Testing
import Foundation
@testable import TrebuchetPostgreSQL

@Suite("PostgreSQL State Store Tests")
struct PostgreSQLStateStoreTests {
    @Test("PostgreSQLStateStore initialization")
    func testInitialization() async throws {
        // Note: This test requires a running PostgreSQL instance
        // In CI/CD, you would set up a test database
        //
        // let store = try await PostgreSQLStateStore(
        //     host: "localhost",
        //     database: "test",
        //     username: "test",
        //     password: "test"
        // )
        //
        // Placeholder test - actual initialization requires PostgreSQL
    }

    @Test("PostgreSQLStateStore parses DATABASE_URL format")
    func testDatabaseURLParsing() async throws {
        // Test various valid connection string formats
        let validURLs = [
            "postgresql://user:pass@localhost:5432/mydb",
            "postgresql://user@localhost/mydb",
            "postgresql://localhost/mydb",
            "postgres://user:pass@host.example.com:5433/production"
        ]

        for url in validURLs {
            // Connection will fail (no actual database), but parsing should succeed
            do {
                _ = try await PostgreSQLStateStore(connectionString: url)
                // If we get here without parsing error, that's unexpected
                // (should fail on connection attempt)
            } catch let error as PostgreSQLError {
                // Should NOT be invalidConnectionString - that's a parsing error
                if case .invalidConnectionString = error {
                    #expect(Bool(false), "Failed to parse valid URL: \(url)")
                }
                // Connection errors are expected and fine
            } catch {
                // Other connection errors are fine
            }
        }
    }

    @Test("PostgreSQLStateStore rejects invalid DATABASE_URL")
    func testInvalidDatabaseURL() async throws {
        let invalidURLs = [
            "not-a-url",
            "postgresql://",  // No host or database
            "postgresql://localhost",  // No database
            "http://localhost/db",  // Wrong scheme
            ""
        ]

        for url in invalidURLs {
            do {
                _ = try await PostgreSQLStateStore(connectionString: url)
                #expect(Bool(false), "Should reject invalid URL: \(url)")
            } catch let error as PostgreSQLError {
                if case .invalidConnectionString = error {
                    // Expected
                } else {
                    #expect(Bool(false), "Expected invalidConnectionString for '\(url)', got \(error)")
                }
            } catch {
                // Connection errors before validation are wrong
                #expect(Bool(false), "Should fail validation before connection for: \(url)")
            }
        }
    }
}

@Suite("PostgreSQL Stream Adapter Tests")
struct PostgreSQLStreamAdapterTests {
    @Test("PostgreSQLStreamAdapter initialization")
    func testInitialization() async throws {
        // Note: This test requires a running PostgreSQL instance
        // In CI/CD, you would set up a test database
        //
        // let adapter = try await PostgreSQLStreamAdapter(
        //     host: "localhost",
        //     database: "test",
        //     username: "test",
        //     password: "test"
        // )
        //
        // Placeholder test - actual initialization requires PostgreSQL
    }

    @Test("PostgreSQLStreamAdapter rejects invalid channel names")
    func testInvalidChannelNames() async throws {
        // Test SQL injection prevention
        do {
            _ = try await PostgreSQLStreamAdapter(
                host: "localhost",
                database: "test",
                username: "test",
                password: "test",
                channel: "actor'; DROP TABLE actor_states; --"
            )
            #expect(Bool(false), "Should have thrown invalidChannelName error")
        } catch let error as PostgreSQLError {
            if case .invalidChannelName = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidChannelName error, got \(error)")
            }
        }
    }

    @Test("PostgreSQLStreamAdapter accepts valid channel names")
    func testValidChannelNames() async {
        // These should all be valid
        let validNames = [
            "actor_state_changes",
            "ActorStateChanges",
            "_private_channel",
            "channel123",
            "my-channel-name"
        ]

        for name in validNames {
            // We can't actually connect without a database, but we can verify
            // that validation passes by checking the error type
            do {
                _ = try await PostgreSQLStreamAdapter(
                    host: "localhost",
                    database: "test",
                    username: "test",
                    password: "test",
                    channel: name
                )
            } catch let error as PostgreSQLError {
                // Connection failure is expected (no database)
                // But NOT invalidChannelName
                if case .invalidChannelName = error {
                    #expect(Bool(false), "Channel '\(name)' should be valid")
                }
            } catch {
                // Other errors are fine (connection failure, etc.)
            }
        }
    }

    @Test("PostgreSQLStreamAdapter rejects channel names with special characters")
    func testInvalidSpecialCharacters() async {
        let invalidNames = [
            "channel;name",  // Semicolon
            "channel name",  // Space
            "channel\nname", // Newline
            "channel'name",  // Single quote
            "channel\"name", // Double quote
            "channel$name",  // Dollar sign
            "123channel",    // Starts with number
            "",              // Empty
            String(repeating: "a", count: 64)  // Too long (>63 chars)
        ]

        for name in invalidNames {
            do {
                _ = try await PostgreSQLStreamAdapter(
                    host: "localhost",
                    database: "test",
                    username: "test",
                    password: "test",
                    channel: name
                )
                #expect(Bool(false), "Channel '\(name)' should be invalid")
            } catch let error as PostgreSQLError {
                if case .invalidChannelName = error {
                    // Expected
                } else {
                    #expect(Bool(false), "Expected invalidChannelName for '\(name)', got \(error)")
                }
            } catch {
                // Connection errors mean validation passed - that's wrong
                #expect(Bool(false), "Channel '\(name)' should fail validation before connection")
            }
        }
    }
}

@Suite("State Change Notification Tests")
struct StateChangeNotificationTests {
    @Test("StateChangeNotification codable")
    func testCodable() throws {
        let notification = StateChangeNotification(
            actorID: "test-actor",
            sequenceNumber: 42,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(StateChangeNotification.self, from: data)

        #expect(decoded.actorID == notification.actorID)
        #expect(decoded.sequenceNumber == notification.sequenceNumber)
    }

    @Test("StateChangeNotification JSON format")
    func testJSONFormat() throws {
        let timestamp = Date(timeIntervalSince1970: 1234567890)
        let notification = StateChangeNotification(
            actorID: "actor-123",
            sequenceNumber: 99,
            timestamp: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(notification)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"actorID\":\"actor-123\""))
        #expect(json.contains("\"sequenceNumber\":99"))
        #expect(json.contains("1234567890"))
    }

    @Test("StateChangeNotification round-trip with seconds encoding")
    func testSecondsEncodingRoundTrip() throws {
        let notification = StateChangeNotification(
            actorID: "test",
            sequenceNumber: 1,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(StateChangeNotification.self, from: data)

        #expect(decoded.actorID == notification.actorID)
        #expect(decoded.sequenceNumber == notification.sequenceNumber)
        #expect(abs(decoded.timestamp.timeIntervalSince1970 - notification.timestamp.timeIntervalSince1970) < 1.0)
    }
}

@Suite("PostgreSQL Error Tests")
struct PostgreSQLErrorTests {
    @Test("PostgreSQLError descriptions")
    func testErrorDescriptions() {
        // Test each error type has a non-empty, meaningful description
        let invalidConnString = PostgreSQLError.invalidConnectionString
        #expect(invalidConnString.description.contains("Invalid"))
        #expect(invalidConnString.description.contains("PostgreSQL"))

        let connFailed = PostgreSQLError.connectionFailed(underlying: NSError(domain: "test", code: 1))
        #expect(connFailed.description.contains("connection"))
        #expect(!connFailed.description.isEmpty)

        let queryFail = PostgreSQLError.queryFailed("SELECT failed")
        #expect(queryFail.description.contains("query"))
        #expect(queryFail.description.contains("SELECT failed"))

        let seqFailed = PostgreSQLError.sequenceRetrievalFailed
        #expect(seqFailed.description.contains("sequence"))
        #expect(seqFailed.description.contains("Failed"))

        let invalidChannel = PostgreSQLError.invalidChannelName("bad;channel")
        #expect(invalidChannel.description.contains("bad;channel"))
        #expect(invalidChannel.description.contains("Invalid"))
    }

    @Test("PostgreSQLError invalidChannelName description")
    func testInvalidChannelNameDescription() {
        let error = PostgreSQLError.invalidChannelName("test;drop")
        let description = error.description

        #expect(description.contains("test;drop"))
        #expect(description.contains("letter"))
        #expect(description.contains("underscore"))
        #expect(description.contains("63"))
    }

    @Test("PostgreSQLError connectionFailed preserves underlying error")
    func testConnectionFailedUnderlyingError() {
        let underlying = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let error = PostgreSQLError.connectionFailed(underlying: underlying)
        let description = error.description

        #expect(description.contains("connection failed"))
        #expect(description.contains("Test error"))
    }
}

@Suite("PostgreSQL Integration Tests")
struct PostgreSQLIntegrationTests {
    // These tests require a running PostgreSQL instance
    // Uncomment and configure for integration testing

    /*
    @Test("Save and load actor state")
    func testSaveAndLoad() async throws {
        let store = try await PostgreSQLStateStore(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test"
        )

        struct TestState: Codable, Sendable, Equatable {
            let value: String
            let count: Int
        }

        let originalState = TestState(value: "hello", count: 42)
        try await store.save(originalState, for: "actor-1")

        let loadedState = try await store.load(for: "actor-1", as: TestState.self)
        #expect(loadedState == originalState)
    }

    @Test("Sequence numbers auto-increment on save")
    func testSequenceIncrement() async throws {
        let store = try await PostgreSQLStateStore(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test"
        )

        struct TestState: Codable, Sendable {
            let iteration: Int
        }

        // Save multiple times
        try await store.save(TestState(iteration: 1), for: "actor-seq")
        try await store.save(TestState(iteration: 2), for: "actor-seq")
        try await store.save(TestState(iteration: 3), for: "actor-seq")

        // Query sequence number directly
        // (Would need to expose sequence number in API or query database)
    }

    @Test("Delete removes actor state")
    func testDelete() async throws {
        let store = try await PostgreSQLStateStore(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test"
        )

        struct TestState: Codable, Sendable {
            let data: String
        }

        try await store.save(TestState(data: "test"), for: "actor-delete")
        try await store.delete(for: "actor-delete")

        let loaded = try await store.load(for: "actor-delete", as: TestState.self)
        #expect(loaded == nil)
    }

    @Test("Exists returns correct status")
    func testExists() async throws {
        let store = try await PostgreSQLStateStore(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test"
        )

        struct TestState: Codable, Sendable {
            let data: String
        }

        #expect(try await !store.exists(for: "nonexistent"))

        try await store.save(TestState(data: "test"), for: "actor-exists")
        #expect(try await store.exists(for: "actor-exists"))

        try await store.delete(for: "actor-exists")
        #expect(try await !store.exists(for: "actor-exists"))
    }

    @Test("NOTIFY broadcasts to subscribers")
    func testNotifyBroadcast() async throws {
        let adapter = try await PostgreSQLStreamAdapter(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test",
            channel: "test_notifications"
        )

        let stream = try await adapter.start()

        let notification = StateChangeNotification(
            actorID: "test-actor",
            sequenceNumber: 1,
            timestamp: Date()
        )

        try await adapter.notify(notification)

        // In a full implementation, would verify notification received via stream
        // For now, just verify notify doesn't throw
    }

    @Test("Connection pool handles concurrent operations")
    func testConcurrentAccess() async throws {
        let store = try await PostgreSQLStateStore(
            host: "localhost",
            database: "test_trebuchet",
            username: "test",
            password: "test"
        )

        struct TestState: Codable, Sendable {
            let id: Int
        }

        // Execute 10 concurrent save operations
        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await store.save(TestState(id: i), for: "actor-\(i)")
                }
            }
        }

        // Verify all saves succeeded
        for i in 0..<10 {
            let state = try await store.load(for: "actor-\(i)", as: TestState.self)
            #expect(state?.id == i)
        }
    }
    */
}
