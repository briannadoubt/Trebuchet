import Distributed
import Foundation
import NIO
import Trebuche

// MARK: - Cloud Gateway

/// Entry point for hosting distributed actors in cloud environments.
///
/// CloudGateway provides a unified interface for exposing actors via HTTP,
/// handling invocation routing, state management, and health checks.
public actor CloudGateway {
    private let actorSystem: TrebuchetActorSystem
    private let transport: HTTPTransport
    private let stateStore: (any ActorStateStore)?
    private let registry: (any ServiceRegistry)?
    private var exposedActors: [String: any DistributedActor] = [:]
    private var running = false

    /// Configuration for the gateway
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var stateStore: (any ActorStateStore)?
        public var registry: (any ServiceRegistry)?
        public var healthCheckPath: String
        public var invokePath: String

        public init(
            host: String = "0.0.0.0",
            port: UInt16 = 8080,
            stateStore: (any ActorStateStore)? = nil,
            registry: (any ServiceRegistry)? = nil,
            healthCheckPath: String = "/health",
            invokePath: String = "/invoke"
        ) {
            self.host = host
            self.port = port
            self.stateStore = stateStore
            self.registry = registry
            self.healthCheckPath = healthCheckPath
            self.invokePath = invokePath
        }
    }

    private let configuration: Configuration

    /// Create a cloud gateway
    /// - Parameter configuration: Gateway configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.actorSystem = TrebuchetActorSystem()
        self.transport = HTTPTransport()
        self.stateStore = configuration.stateStore
        self.registry = configuration.registry
    }

    /// The actor system used by this gateway
    public nonisolated var system: TrebuchetActorSystem {
        actorSystem
    }

    // MARK: - Actor Management

    /// Expose an actor through the gateway
    /// - Parameters:
    ///   - actor: The actor to expose
    ///   - name: The logical name for the actor
    public func expose<A: DistributedActor>(
        _ actor: A,
        as name: String
    ) async throws where A.ActorSystem == TrebuchetActorSystem {
        exposedActors[name] = actor

        // Register with service registry if available
        if let registry {
            let endpoint = CloudEndpoint(
                provider: .local,
                region: "local",
                identifier: "\(configuration.host):\(configuration.port)",
                scheme: .http
            )
            try await registry.register(
                actorID: name,
                endpoint: endpoint,
                metadata: ["type": String(describing: A.self)],
                ttl: .seconds(30)
            )
        }
    }

    /// Remove an exposed actor
    /// - Parameter name: The name of the actor to remove
    public func unexpose(_ name: String) async throws {
        exposedActors.removeValue(forKey: name)

        if let registry {
            try await registry.deregister(actorID: name)
        }
    }

    /// Get an exposed actor by name
    /// - Parameter name: The actor name
    /// - Returns: The actor if found
    public func actor<A: DistributedActor>(named name: String) -> A? where A.ActorSystem == TrebuchetActorSystem {
        exposedActors[name] as? A
    }

    // MARK: - Lifecycle

    /// Start the gateway
    public func run() async throws {
        guard !running else { return }
        running = true

        let endpoint = Endpoint(host: configuration.host, port: configuration.port)
        try await transport.listen(on: endpoint)

        // Start heartbeat task if registry is configured
        if let registry {
            Task {
                await heartbeatLoop(registry: registry)
            }
        }

        // Process incoming requests
        for await message in transport.incoming {
            await handleMessage(message)
        }
    }

    /// Stop the gateway
    public func shutdown() async {
        running = false
        await transport.shutdown()

        // Deregister all actors
        if let registry {
            for name in exposedActors.keys {
                try? await registry.deregister(actorID: name)
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: TransportMessage) async {
        do {
            let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: message.data)

            // Find the target actor
            guard let actor = exposedActors[envelope.actorID.id] else {
                let response = ResponseEnvelope.failure(
                    callID: envelope.callID,
                    error: "Actor '\(envelope.actorID.id)' not found"
                )
                let responseData = try JSONEncoder().encode(response)
                try await message.respond(responseData)
                return
            }

            // Execute the invocation
            let response = try await executeInvocation(envelope, on: actor)
            let responseData = try JSONEncoder().encode(response)
            try await message.respond(responseData)

        } catch {
            // Send error response
            let response = ResponseEnvelope.failure(
                callID: UUID(),
                error: "Failed to process request: \(error)"
            )
            if let responseData = try? JSONEncoder().encode(response) {
                try? await message.respond(responseData)
            }
        }
    }

    private func executeInvocation(
        _ envelope: InvocationEnvelope,
        on actor: any DistributedActor
    ) async throws -> ResponseEnvelope {
        // Create decoder and result handler
        var decoder = TrebuchetDecoder(envelope: envelope)
        let handler = TrebuchetResultHandler()

        do {
            // Execute the distributed target
            try await actorSystem.executeDistributedTarget(
                on: actor,
                target: RemoteCallTarget(envelope.targetIdentifier),
                invocationDecoder: &decoder,
                handler: handler
            )

            // Return success response
            return ResponseEnvelope.success(
                callID: envelope.callID,
                result: handler.resultData ?? Data()
            )
        } catch {
            return ResponseEnvelope.failure(
                callID: envelope.callID,
                error: String(describing: error)
            )
        }
    }

    // MARK: - Health & Registry

    private func heartbeatLoop(registry: any ServiceRegistry) async {
        while running {
            for name in exposedActors.keys {
                try? await registry.heartbeat(actorID: name)
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

// MARK: - Lambda Handler Support

/// Protocol for actors that can handle Lambda-style events directly
public protocol LambdaEventHandler {
    associatedtype Event: Codable
    associatedtype Response: Codable

    func handle(event: Event, context: LambdaContext) async throws -> Response
}

/// Context passed to Lambda event handlers
public struct LambdaContext: Sendable {
    public let requestID: String
    public let functionName: String
    public let memoryLimit: Int
    public let deadline: Date

    public init(
        requestID: String,
        functionName: String,
        memoryLimit: Int = 128,
        deadline: Date = Date().addingTimeInterval(30)
    ) {
        self.requestID = requestID
        self.functionName = functionName
        self.memoryLimit = memoryLimit
        self.deadline = deadline
    }

    public var remainingTime: Duration {
        let remaining = deadline.timeIntervalSinceNow
        return .seconds(max(0, remaining))
    }
}

// MARK: - Convenience Builders

extension CloudGateway {
    /// Create a gateway with in-memory registry and state store (for development)
    public static func development(
        host: String = "localhost",
        port: UInt16 = 8080
    ) -> CloudGateway {
        CloudGateway(configuration: Configuration(
            host: host,
            port: port,
            stateStore: InMemoryStateStore(),
            registry: InMemoryRegistry()
        ))
    }
}
