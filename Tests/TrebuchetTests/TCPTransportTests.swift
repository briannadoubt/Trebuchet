import Testing
import Distributed
import Foundation
@testable import Trebuchet

// MARK: - Test Actor

distributed actor TCPEchoActor {
    typealias ActorSystem = TrebuchetActorSystem

    distributed func echo(message: String) -> String {
        return "Echo: \(message)"
    }

    distributed func add(a: Int, b: Int) -> Int {
        return a + b
    }

    distributed func greet(name: String, times: Int) -> [String] {
        (0..<times).map { "Hello \(name) #\($0 + 1)" }
    }
}

// MARK: - TCP Transport Integration Tests

@Suite("TCP Transport", .serialized)
struct TCPTransportTests {

    @Test("TCP server creates actor with correct ID")
    func tcpServerActorID() async throws {
        let server = TrebuchetServer(transport: .tcp(port: 29000))
        let actor = TCPEchoActor(actorSystem: server.actorSystem)

        #expect(actor.id.port == 29000)
    }

    @Test("TCP expose actor and get ID")
    func tcpExposeActor() async throws {
        let server = TrebuchetServer(transport: .tcp(port: 29001))
        let actor = TCPEchoActor(actorSystem: server.actorSystem)

        await server.expose(actor, as: "my-tcp-echo")

        let retrievedID = await server.actorID(for: "my-tcp-echo")
        #expect(retrievedID == actor.id)
    }

    @Test("TCP server starts and can be shutdown")
    func tcpServerStartsAndStops() async throws {
        let server = TrebuchetServer(transport: .tcp(port: 29002))

        // Start server in background with timeout
        let serverTask = Task {
            try await server.run()
        }

        // Give it time to bind
        try await Task.sleep(for: .milliseconds(100))

        // Shutdown
        await server.shutdown()

        // Wait for task to complete with timeout
        _ = await Task {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await serverTask.value
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
        }.result

        // Server should have stopped (either completed or we timed out)
        serverTask.cancel()
    }

    @Test("TCP client connects to server")
    func tcpClientConnects() async throws {
        let port: UInt16 = 29010

        // Setup server
        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        // Start server
        let serverTask = Task {
            try await server.run()
        }

        // Wait for server to be ready
        try await Task.sleep(for: .milliseconds(200))

        // Connect client
        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        // Basic sanity check - client should be able to resolve
        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")
        #expect(remoteEcho.id.host == "127.0.0.1")
        #expect(remoteEcho.id.port == port)

        // Cleanup
        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP remote echo call", .timeLimit(.minutes(1)))
    func tcpRemoteEchoCall() async throws {
        let port: UInt16 = 29011

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        // Make the actual remote call
        let result = try await remoteEcho.echo(message: "Hello TCP!")
        #expect(result == "Echo: Hello TCP!")

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP multiple remote calls", .timeLimit(.minutes(1)))
    func tcpMultipleRemoteCalls() async throws {
        let port: UInt16 = 29012

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        // Make multiple remote calls
        let result1 = try await remoteEcho.echo(message: "First")
        let result2 = try await remoteEcho.echo(message: "Second")
        let result3 = try await remoteEcho.add(a: 10, b: 20)

        #expect(result1 == "Echo: First")
        #expect(result2 == "Echo: Second")
        #expect(result3 == 30)

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP remote array return", .timeLimit(.minutes(1)))
    func tcpRemoteArrayReturn() async throws {
        let port: UInt16 = 29013

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        let result = try await remoteEcho.greet(name: "TCP", times: 5)
        #expect(result.count == 5)
        #expect(result[0] == "Hello TCP #1")
        #expect(result[4] == "Hello TCP #5")

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP connection pooling", .timeLimit(.minutes(1)))
    func tcpConnectionPooling() async throws {
        let port: UInt16 = 29014

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        // Make many calls to test connection pooling
        for i in 0..<10 {
            let result = try await remoteEcho.add(a: i, b: 1)
            #expect(result == i + 1)
        }

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP handles connection refused")
    func tcpConnectionRefused() async throws {
        // Try to connect to a port that's not listening
        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: 65534))

        var didThrow = false
        do {
            try await client.connect()
        } catch {
            didThrow = true
            // Verify it's a connection error
            if case TrebuchetError.connectionFailed = error {
                // Expected error type
            } else {
                Issue.record("Expected TrebuchetError.connectionFailed, got \(error)")
            }
        }

        #expect(didThrow, "Should throw connection error when server is not listening")
        await client.disconnect()
    }

    @Test("TCP graceful shutdown completes successfully", .timeLimit(.minutes(1)))
    func tcpGracefulShutdown() async throws {
        let port: UInt16 = 29015

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        // Make successful calls
        let result1 = try await remoteEcho.echo(message: "Call 1")
        let result2 = try await remoteEcho.echo(message: "Call 2")

        #expect(result1 == "Echo: Call 1")
        #expect(result2 == "Echo: Call 2")

        // Graceful shutdown should complete without errors
        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()

        // Verify server state is stopped
        let state = await server.getState()
        #expect(state == .stopped)
    }

    @Test("TCP handles large messages", .timeLimit(.minutes(1)))
    func tcpHandlesLargeMessages() async throws {
        let port: UInt16 = 29016

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")

        // Create a large message (100KB)
        let largeMessage = String(repeating: "x", count: 100_000)
        let result = try await remoteEcho.echo(message: largeMessage)

        #expect(result == "Echo: \(largeMessage)")
        #expect(result.count == largeMessage.count + 6) // "Echo: " prefix

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TCP handles concurrent connections", .timeLimit(.minutes(1)))
    func tcpHandlesConcurrentConnections() async throws {
        let port: UInt16 = 29017

        let server = TrebuchetServer(transport: .tcp(port: port))
        let echo = TCPEchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        // Create multiple clients
        let clients = (0..<5).map { _ in
            TrebuchetClient(transport: .tcp(host: "127.0.0.1", port: port))
        }

        // Connect all clients concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask {
                    try await client.connect()
                }
            }
            try await group.waitForAll()
        }

        // Make calls from all clients concurrently
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for (index, client) in clients.enumerated() {
                group.addTask {
                    let remoteEcho = try client.resolve(TCPEchoActor.self, id: "echo")
                    return try await remoteEcho.echo(message: "Client \(index)")
                }
            }

            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.count == 5)
        for result in results {
            #expect(result.hasPrefix("Echo: Client "))
        }

        // Cleanup
        for client in clients {
            await client.disconnect()
        }
        await server.shutdown()
        serverTask.cancel()
    }
}
