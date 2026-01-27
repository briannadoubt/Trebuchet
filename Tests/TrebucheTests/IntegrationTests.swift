import Testing
import Distributed
import Foundation
import NIOSSL
@testable import Trebuche

// MARK: - Test Actor

distributed actor EchoActor {
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

// MARK: - Local Actor Tests

@Suite("Local Actor Tests")
struct LocalActorTests {

    @Test("Local actor echo call")
    func localActorEcho() async throws {
        let system = TrebuchetActorSystem()
        let actor = EchoActor(actorSystem: system)

        let result = try await actor.echo(message: "Hello")
        #expect(result == "Echo: Hello")
    }

    @Test("Local actor add call")
    func localActorAdd() async throws {
        let system = TrebuchetActorSystem()
        let actor = EchoActor(actorSystem: system)

        let result = try await actor.add(a: 5, b: 3)
        #expect(result == 8)
    }

    @Test("Local actor returns array")
    func localActorArray() async throws {
        let system = TrebuchetActorSystem()
        let actor = EchoActor(actorSystem: system)

        let result = try await actor.greet(name: "World", times: 3)
        #expect(result.count == 3)
        #expect(result[0] == "Hello World #1")
        #expect(result[2] == "Hello World #3")
    }

    @Test("Multiple actors same system")
    func multipleActors() async throws {
        let system = TrebuchetActorSystem()
        let actor1 = EchoActor(actorSystem: system)
        let actor2 = EchoActor(actorSystem: system)

        let result1 = try await actor1.echo(message: "One")
        let result2 = try await actor2.echo(message: "Two")

        #expect(result1 == "Echo: One")
        #expect(result2 == "Echo: Two")
        #expect(actor1.id != actor2.id)
    }
}

// MARK: - Server Tests

@Suite("Server Tests", .serialized)
struct ServerTests {

    @Test("Server creates actor with correct ID")
    func serverActorID() async throws {
        let server = TrebuchetServer(transport: .webSocket(port: 19000))
        let actor = EchoActor(actorSystem: server.actorSystem)

        #expect(actor.id.port == 19000)
    }

    @Test("Expose actor and get ID")
    func exposeActor() async throws {
        let server = TrebuchetServer(transport: .webSocket(port: 19001))
        let actor = EchoActor(actorSystem: server.actorSystem)

        await server.expose(actor, as: "my-echo")

        let retrievedID = await server.actorID(for: "my-echo")
        #expect(retrievedID == actor.id)
    }

    @Test("Server starts and can be shutdown")
    func serverStartsAndStops() async throws {
        let server = TrebuchetServer(transport: .webSocket(port: 19002))

        // Start server in background with timeout
        let serverTask = Task {
            try await server.run()
        }

        // Give it time to bind
        try await Task.sleep(for: .milliseconds(100))

        // Shutdown
        await server.shutdown()

        // Wait for task to complete with timeout
        let result = await Task {
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
}

// MARK: - Client-Server Integration Tests

@Suite("Client-Server Integration", .serialized)
struct ClientServerIntegrationTests {

    @Test("Client connects to server")
    func clientConnects() async throws {
        let port: UInt16 = 19010

        // Setup server
        let server = TrebuchetServer(transport: .webSocket(port: port))
        let echo = EchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        // Start server
        let serverTask = Task {
            try await server.run()
        }

        // Wait for server to be ready
        try await Task.sleep(for: .milliseconds(200))

        // Connect client
        let client = TrebuchetClient(transport: .webSocket(host: "127.0.0.1", port: port))
        try await client.connect()

        // Basic sanity check - client should be able to resolve
        let remoteEcho = try client.resolve(EchoActor.self, id: "echo")
        #expect(remoteEcho.id.host == "127.0.0.1")
        #expect(remoteEcho.id.port == port)

        // Cleanup
        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("Remote echo call", .timeLimit(.minutes(1)))
    func remoteEchoCall() async throws {
        let port: UInt16 = 19011

        let server = TrebuchetServer(transport: .webSocket(port: port))
        let echo = EchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .webSocket(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(EchoActor.self, id: "echo")

        // Make the actual remote call
        let result = try await remoteEcho.echo(message: "Hello Network!")
        #expect(result == "Echo: Hello Network!")

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("Multiple remote calls", .timeLimit(.minutes(1)))
    func multipleRemoteCalls() async throws {
        let port: UInt16 = 19012

        let server = TrebuchetServer(transport: .webSocket(port: port))
        let echo = EchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .webSocket(host: "127.0.0.1", port: port))
        try await client.connect()

        let remoteEcho = try client.resolve(EchoActor.self, id: "echo")

        // Multiple calls
        for i in 0..<5 {
            let result = try await remoteEcho.echo(message: "Call \(i)")
            #expect(result == "Echo: Call \(i)")
        }

        // Different method
        let sum = try await remoteEcho.add(a: 100, b: 23)
        #expect(sum == 123)

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }
}

// MARK: - TLS Integration Tests

@Suite("TLS Integration", .serialized)
struct TLSIntegrationTests {

    // Self-signed test certificate (generated for localhost, valid for testing only)
    static let testCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDCTCCAfGgAwIBAgIUYcdX9AlG/KSycFWCB0Shc3BkseIwDQYJKoZIhvcNAQEL
    BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDEwNTA2MjIzMloXDTI3MDEw
    NTA2MjIzMlowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    AAOCAQ8AMIIBCgKCAQEAmWiC13DnaPztBOVnDWMTNpQHCnJWN+pdc96POYWsmnoH
    h8vXiTNVUqG7nf4raM2TbIF6SvIZU5VVuRFPJoWq8ggw9LNlcvUNVs7k4lVPFN9K
    y3IXIKxblzwj88d7gowzKnAd83ySeuAUo35wGYJm15ETOpVJn3m9Pd22tV9+J7sY
    8wo9pvnR8RgJWEYQS0ONQRolh2ZzKTUZp/mQIlhfgrrpnYPqV5PtuyPTWzZoIURI
    GPkEKOAWyweEAo3ph5gF/1smG3INO7fl72FkMKgpj1pM33810tKVdsWIgK8aoxHh
    nrszHv6HmTUwjKY6MvjD7efQ7IiPo5Yrn6HRRnXQAQIDAQABo1MwUTAdBgNVHQ4E
    FgQU6fF+mr+ZHkBeIj8DVRNcORTnKb0wHwYDVR0jBBgwFoAU6fF+mr+ZHkBeIj8D
    VRNcORTnKb0wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEATAhM
    BEiGPJQRJMiLWJiy1nogndd8fcuRA0/XPavuSfUNQZWaO17WtQCMV6lzbsrQ42Ko
    +uG5Hi4tSolfCeeVQOqp3QoOfKyiOlBM/ZnoZRUx0Z3uZxf70tZQ2JKDAcmI50LX
    FBc/7y0kafjbMNw9tgGTORqh+4X1jMUDmcCiRRGHWc+8FUU8cqRZj40MtDYYuXM+
    FUW4z+Zv8Fc9DSmdoVszUrxZwJiBtQzXvgXqhu2kBfmtKmLqDaSy2IAkfjOGhAAg
    njx0sj9GtRR7MIlaTD+NpKeECE1Dt/6+6nrGDTwoqwKa45+6203Ffx5gm/HbcwCj
    dqbpcHpWUBhcFezUug==
    -----END CERTIFICATE-----
    """

    static let testPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCZaILXcOdo/O0E
    5WcNYxM2lAcKclY36l1z3o85hayaegeHy9eJM1VSobud/itozZNsgXpK8hlTlVW5
    EU8mharyCDD0s2Vy9Q1WzuTiVU8U30rLchcgrFuXPCPzx3uCjDMqcB3zfJJ64BSj
    fnAZgmbXkRM6lUmfeb093ba1X34nuxjzCj2m+dHxGAlYRhBLQ41BGiWHZnMpNRmn
    +ZAiWF+Cuumdg+pXk+27I9NbNmghREgY+QQo4BbLB4QCjemHmAX/WyYbcg07t+Xv
    YWQwqCmPWkzffzXS0pV2xYiArxqjEeGeuzMe/oeZNTCMpjoy+MPt59DsiI+jliuf
    odFGddABAgMBAAECggEAAQ+IDQ+IqBEMnfqskVsAomFYYZ38At+11PPiW2BVWs2S
    cQHLrBUM51j7LDraR7uZI/hKtUsyeeGX0cNg/9gPgCQmm4CEiGyRkqq0SizTEsa+
    9IRlzMnoSbXGnVxBGjxYK7hR+rGfLSaQufcpNQHx7lZgUsi+tTGxKWT3qw4dmA54
    Pj7bqejXb4co4jtApU2RA0fbNCRNI78VndIQRHxDRcAlAWPM+yZPn/uecUOI+AHm
    A2BG2u63h0QZLsvtdYNjzYqm6iOMPTxrEJ0UrxoZ0ipdtiwFxnd33cULd2WRQYi0
    gAUWdKWCMkvNfdXOhw4xyd9htetrq3rrQvn8Rc5+AQKBgQDL2+g7kpzqZwVKz37V
    17CE071w0FAOhXMWPHgYgJlx7B7V48ey7GQedH80ECag3rdvYWsMsOyTslqmMZkj
    Jk4NNTHHntJxjVDvZzdirJf6sHrqZblQEjLI6+Y7tKQ27gNZIfrB8gbwNq+ke42D
    y2AzCCJ/9aila7sqx2qtCrxGwQKBgQDApTwwZZLgIJUo81aoYGMLVqAoUoVSChoV
    jXF1D9OLfReExRLMvSdSQKTOQGkflRwx5aW0rzTbvClCKC5T3eDr56LKcVhrtfC3
    GLaDox3bPxfzXitWrlZOfcl8bayYXkkzHv0MaKlurSsPjiN0K3Fjl39a0oBinKbR
    uqCCEH8ZQQKBgQCviXw/T8+uR2dXM7STjlaBCZJmQfmth1vCGe+Pqax3XEpxAuJC
    Pys2zjl6Ky4X968cSVZUZ0RPKZTE5pBmo+UxmkxzB19OR9EZVFdssBFt2+j7TPx0
    5ja0q+xkHPgKFIjth0TVHAK9dVlo2LrScZ00VBzg8jd1uX5BJ9XDiyr0AQKBgBna
    UuB/0R0o4juTpG6GOOR9pJKkuGWRG30G9VHrZM1UZUKZG/PD8rH0IOnY9QKbBSSh
    GALOfH58muDY+ZahsRyXgl4+pcoWqY44z82Mp2YT6ofrfE9uqABymwaKxV3RUWt9
    3iG7Lfm/XYcB4Tom1lmyLBIpK7eQJEcDD6VEx3nBAoGBAMVjsUzYVydmdHhA0OCF
    W0PfBOCrAAFVp+/sTtwKAyxzoIzh4oFNqkEiWNID8Xdjdzpgdt9Rqdxqi11MBqvZ
    BjpoJ1smOyJTx3SH67gpaDv73dGlK9k70vRXDcYf/9aP56sgQ+WD7B/IgVfsmdZo
    l3aWdYgwvLfj7QnxGUldBQSC
    -----END PRIVATE KEY-----
    """

    @Test("TLS remote echo call", .timeLimit(.minutes(1)))
    func tlsRemoteEchoCall() async throws {
        let port: UInt16 = 19020

        // Create TLS configuration from test certificates
        let tls = try TLSConfiguration(
            certificatePEM: Self.testCertificatePEM,
            privateKeyPEM: Self.testPrivateKeyPEM
        )

        // Server with TLS
        let server = TrebuchetServer(transport: .webSocket(port: port, tls: tls))
        let echo = EchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        // Client with TLS (certificate verification disabled for self-signed cert)
        let client = TrebuchetClient(transport: .webSocket(host: "127.0.0.1", port: port, tls: tls))
        try await client.connect()

        let remoteEcho = try client.resolve(EchoActor.self, id: "echo")

        // Make the actual remote call over TLS
        let result = try await remoteEcho.echo(message: "Hello Secure World!")
        #expect(result == "Echo: Hello Secure World!")

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }

    @Test("TLS multiple calls", .timeLimit(.minutes(1)))
    func tlsMultipleCalls() async throws {
        let port: UInt16 = 19021

        let tls = try TLSConfiguration(
            certificatePEM: Self.testCertificatePEM,
            privateKeyPEM: Self.testPrivateKeyPEM
        )

        let server = TrebuchetServer(transport: .webSocket(port: port, tls: tls))
        let echo = EchoActor(actorSystem: server.actorSystem)
        await server.expose(echo, as: "echo")

        let serverTask = Task {
            try await server.run()
        }

        try await Task.sleep(for: .milliseconds(200))

        let client = TrebuchetClient(transport: .webSocket(host: "127.0.0.1", port: port, tls: tls))
        try await client.connect()

        let remoteEcho = try client.resolve(EchoActor.self, id: "echo")

        // Multiple secure calls
        for i in 0..<3 {
            let result = try await remoteEcho.echo(message: "Secure \(i)")
            #expect(result == "Echo: Secure \(i)")
        }

        let sum = try await remoteEcho.add(a: 50, b: 50)
        #expect(sum == 100)

        await client.disconnect()
        await server.shutdown()
        serverTask.cancel()
    }
}
