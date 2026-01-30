import Testing
import Foundation
@testable import Trebuchet

@Suite("SwiftUI Integration Tests")
struct SwiftUIIntegrationTests {

    // MARK: - ConnectionState Tests

    @Test("ConnectionState disconnected initial state")
    func connectionStateDisconnected() {
        let state = ConnectionState.disconnected
        #expect(state == .disconnected)
    }

    @Test("ConnectionState connecting transition")
    func connectionStateConnecting() {
        let state = ConnectionState.connecting
        #expect(state == .connecting)
    }

    @Test("ConnectionState connected")
    func connectionStateConnected() {
        let state = ConnectionState.connected
        #expect(state == .connected)
        #expect(state.isConnected == true)
    }

    @Test("ConnectionState failed with error")
    func connectionStateFailed() {
        let underlying = TrebuchetError.connectionFailed(host: "localhost", port: 8080, underlying: NSError(domain: "test", code: -1))
        let error = ConnectionError(underlyingError: underlying)
        let state = ConnectionState.failed(error)

        if case .failed(let err) = state {
            // Verify error properties are accessible
            _ = err.underlyingError
            _ = err.timestamp
            #expect(err.connectionName == nil)
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test("ConnectionState isConnected property")
    func connectionStateIsConnected() {
        #expect(ConnectionState.disconnected.isConnected == false)
        #expect(ConnectionState.connecting.isConnected == false)
        #expect(ConnectionState.connected.isConnected == true)

        let error = ConnectionError(underlyingError: .systemNotRunning)
        #expect(ConnectionState.failed(error).isConnected == false)
    }

    // MARK: - ReconnectionPolicy Tests

    @Test("ReconnectionPolicy default")
    func reconnectionPolicyDefault() {
        let policy = ReconnectionPolicy.default
        #expect(policy.maxAttempts == 5)
        #expect(policy.initialDelay == .seconds(1))
        #expect(policy.maxDelay == .seconds(30))
        #expect(policy.backoffMultiplier == 2.0)
    }

    @Test("ReconnectionPolicy disabled")
    func reconnectionPolicyDisabled() {
        let policy = ReconnectionPolicy.disabled
        #expect(policy.maxAttempts == 0)
    }

    @Test("ReconnectionPolicy custom parameters")
    func reconnectionPolicyCustom() {
        let policy = ReconnectionPolicy(
            maxAttempts: 3,
            initialDelay: .seconds(2),
            maxDelay: .seconds(60),
            backoffMultiplier: 1.5
        )

        #expect(policy.maxAttempts == 3)
        #expect(policy.initialDelay == .seconds(2))
        #expect(policy.maxDelay == .seconds(60))
        #expect(policy.backoffMultiplier == 1.5)
    }

    // MARK: - TrebuchetConnection Tests

    @Test("TrebuchetConnection initialization")
    @MainActor
    func trebuchetConnectionInit() async {
        let connection = TrebuchetConnection(
            transport: .webSocket(host: "localhost", port: 8080)
        )

        #expect(connection.state == .disconnected)
    }

    @Test("TrebuchetConnection with reconnection policy")
    @MainActor
    func trebuchetConnectionWithReconnectionPolicy() async {
        let connection = TrebuchetConnection(
            transport: .webSocket(host: "localhost", port: 8080),
            reconnectionPolicy: ReconnectionPolicy(
                maxAttempts: 3,
                initialDelay: .seconds(1),
                maxDelay: .seconds(10),
                backoffMultiplier: 2.0
            )
        )

        #expect(connection.reconnectionPolicy.maxAttempts == 3)
    }

    @Test("TrebuchetConnection initial state is disconnected")
    @MainActor
    func trebuchetConnectionInitialState() async {
        let connection = TrebuchetConnection(
            transport: .webSocket(host: "localhost", port: 8080)
        )

        #expect(connection.state == .disconnected)
    }

    @Test("TrebuchetConnection disconnect when not connected")
    @MainActor
    func trebuchetConnectionDisconnectWhenNotConnected() async {
        let connection = TrebuchetConnection(
            transport: .webSocket(host: "localhost", port: 8080)
        )

        // Should not throw or crash when disconnecting while not connected
        await connection.disconnect()

        #expect(connection.state == .disconnected)
    }

    // MARK: - TrebuchetConnectionManager Tests

    @Test("TrebuchetConnectionManager initialization")
    @MainActor
    func connectionManagerInit() {
        let manager = TrebuchetConnectionManager()
        #expect(manager.connections.isEmpty)
    }

    @Test("TrebuchetConnectionManager register connection")
    @MainActor
    func connectionManagerRegisterConnection() async {
        let manager = TrebuchetConnectionManager()

        manager.registerConnection(
            named: "server1",
            transport: .webSocket(host: "server1", port: 8080)
        )

        let retrieved = manager["server1"]
        #expect(retrieved != nil)
        #expect(manager.defaultConnectionName == "server1")
    }

    @Test("TrebuchetConnectionManager remove connection")
    @MainActor
    func connectionManagerRemoveConnection() async {
        let manager = TrebuchetConnectionManager()

        manager.registerConnection(
            named: "server1",
            transport: .webSocket(host: "server1", port: 8080)
        )

        await manager.removeConnection(named: "server1")

        let retrieved = manager["server1"]
        #expect(retrieved == nil)
    }

    @Test("TrebuchetConnectionManager disconnect all")
    @MainActor
    func connectionManagerDisconnectAll() async {
        let manager = TrebuchetConnectionManager()

        manager.registerConnection(named: "server1", transport: .webSocket(host: "server1", port: 8080))
        manager.registerConnection(named: "server2", transport: .webSocket(host: "server2", port: 8080))

        await manager.disconnectAll()

        // Connections should still exist but be disconnected
        #expect(manager["server1"]?.state == .disconnected)
        #expect(manager["server2"]?.state == .disconnected)
    }

    // MARK: - RemoteActorState Tests

    @Test("RemoteActorState disconnected")
    func remoteActorStateDisconnected() {
        let state = RemoteActorState<SwiftUITestActor>.disconnected
        #expect(state.isResolved == false)
        #expect(state.isLoading == false)
        #expect(state.actor == nil)
    }

    @Test("RemoteActorState loading")
    func remoteActorStateLoading() {
        let state = RemoteActorState<SwiftUITestActor>.loading
        #expect(state.isLoading == true)
        #expect(state.isResolved == false)
        #expect(state.actor == nil)
    }

    @Test("RemoteActorState failed")
    func remoteActorStateFailed() {
        let actorID = TrebuchetActorID(id: "test", host: "localhost", port: 8080)
        let error = TrebuchetError.actorNotFound(actorID)
        let state = RemoteActorState<SwiftUITestActor>.failed(error)

        #expect(state.isResolved == false)
        #expect(state.isLoading == false)
        #expect(state.error != nil)
    }

    // Note: RemoteActorWrapper and ObservedActor require SwiftUI environment
    // and are best tested in actual SwiftUI integration tests with a running server.
    // Basic API verification only.

    // MARK: - Environment Integration Tests

    @Test("Environment view modifier configuration")
    func environmentViewModifier() {
        // This would normally be tested in a SwiftUI context
        // For now, verify the transport configuration is valid
        let config = TransportConfiguration.webSocket(host: "localhost", port: 8080)
        #expect(config.endpoint.host == "localhost")
        #expect(config.endpoint.port == 8080)
    }
}

// MARK: - Test Helper Types

// Mock actor for SwiftUI testing
@Trebuchet
distributed actor SwiftUITestActor {
    var someProperty: String = "test"
    var count: Int = 0

    distributed func increment() {
        count += 1
    }

    distributed func getMessage() -> String {
        return someProperty
    }
}

// MARK: - Integration Test Scenarios

@Suite("SwiftUI Integration Scenarios", .serialized)
struct SwiftUIIntegrationScenarios {

    @Test("Connection lifecycle scenario")
    @MainActor
    func connectionLifecycle() async {
        let connection = TrebuchetConnection(
            transport: .webSocket(host: "localhost", port: 8090)
        )

        // Initial state
        #expect(connection.state == .disconnected)

        // Note: Actual connection would require a running server
        // This test verifies the API is callable

        // Disconnect (should be safe even when not connected)
        await connection.disconnect()

        #expect(connection.state == .disconnected)
    }

    @Test("Multi-server management scenario")
    @MainActor
    func multiServerManagement() async {
        let manager = TrebuchetConnectionManager()

        // Register multiple servers
        let servers = ["game-server", "chat-server", "auth-server"]

        for server in servers {
            manager.registerConnection(
                named: server,
                transport: .webSocket(host: server, port: 8080)
            )
        }

        // Verify all are added
        for server in servers {
            let conn = manager[server]
            #expect(conn != nil)
        }

        // Disconnect all
        await manager.disconnectAll()

        // Connections should still exist
        for server in servers {
            let conn = manager[server]
            #expect(conn != nil)
        }
    }

    @Test("Actor resolution state transitions")
    func actorResolutionStateTransitions() {
        // Verify state enum transitions
        let disconnected = RemoteActorState<SwiftUITestActor>.disconnected
        let loading = RemoteActorState<SwiftUITestActor>.loading

        let actorID = TrebuchetActorID(id: "test", host: "localhost", port: 8080)
        let failed = RemoteActorState<SwiftUITestActor>.failed(TrebuchetError.actorNotFound(actorID))

        #expect(!disconnected.isLoading)
        #expect(loading.isLoading)
        #expect(!failed.isResolved)
    }
}
