import Distributed
import Foundation
import NIO
import Trebuchet
@_exported import struct Trebuchet.TraceContext
import TrebuchetObservability
import TrebuchetSecurity

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
    private let logger: TrebuchetLogger
    private let metrics: (any MetricsCollector)?
    private let middlewareChain: MiddlewareChain

    /// Configuration for the gateway
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var stateStore: (any ActorStateStore)?
        public var registry: (any ServiceRegistry)?
        public var healthCheckPath: String
        public var invokePath: String
        public var loggingConfiguration: LoggingConfiguration
        public var metricsCollector: (any MetricsCollector)?
        public var middlewares: [any CloudMiddleware]

        public init(
            host: String = "0.0.0.0",
            port: UInt16 = 8080,
            stateStore: (any ActorStateStore)? = nil,
            registry: (any ServiceRegistry)? = nil,
            healthCheckPath: String = "/health",
            invokePath: String = "/invoke",
            loggingConfiguration: LoggingConfiguration = .default,
            metricsCollector: (any MetricsCollector)? = nil,
            middlewares: [any CloudMiddleware] = []
        ) {
            self.host = host
            self.port = port
            self.stateStore = stateStore
            self.registry = registry
            self.healthCheckPath = healthCheckPath
            self.invokePath = invokePath
            self.loggingConfiguration = loggingConfiguration
            self.metricsCollector = metricsCollector
            self.middlewares = middlewares
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
        self.logger = TrebuchetLogger(
            label: "CloudGateway",
            configuration: configuration.loggingConfiguration
        )
        self.metrics = configuration.metricsCollector
        self.middlewareChain = MiddlewareChain(middlewares: configuration.middlewares)
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

        await logger.info("Exposed actor", metadata: [
            "actorID": name,
            "actorType": String(describing: A.self)
        ])

        // Update metrics
        if let metrics {
            await metrics.recordGauge(
                TrebuchetMetrics.actorsActive,
                value: Double(exposedActors.count),
                tags: [:]
            )
        }

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
            await logger.debug("Registered actor with service registry", metadata: [
                "actorID": name
            ])
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

        await logger.info("Starting CloudGateway", metadata: [
            "host": configuration.host,
            "port": String(configuration.port),
            "actorCount": String(exposedActors.count)
        ])

        let endpoint = Endpoint(host: configuration.host, port: configuration.port)
        try await transport.listen(on: endpoint)

        await logger.info("CloudGateway listening", metadata: [
            "endpoint": "\(configuration.host):\(configuration.port)"
        ])

        // Start heartbeat task if registry is configured
        if let registry {
            await logger.debug("Starting registry heartbeat loop")
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
        let startTime = Date()

        do {
            let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: message.data)

            // Extract trace context for distributed tracing
            let traceContext = envelope.traceContext ?? TraceContext()

            await logger.debug("Received invocation", metadata: [
                "actorID": envelope.actorID.id,
                "target": envelope.targetIdentifier,
                "callID": envelope.callID.uuidString,
                "traceID": traceContext.traceID.uuidString,
                "spanID": traceContext.spanID.uuidString
            ], correlationID: traceContext.traceID)

            // Find the target actor
            guard let actor = exposedActors[envelope.actorID.id] else {
                await logger.warning("Actor not found", metadata: [
                    "actorID": envelope.actorID.id,
                    "callID": envelope.callID.uuidString
                ])

                // Record error metric
                if let metrics {
                    await metrics.incrementCounter(
                        TrebuchetMetrics.invocationsErrors,
                        tags: ["reason": "actor_not_found"]
                    )
                }

                let response = ResponseEnvelope.failure(
                    callID: envelope.callID,
                    error: "Actor '\(envelope.actorID.id)' not found"
                )
                let responseData = try JSONEncoder().encode(response)
                try await message.respond(responseData)
                return
            }

            // Execute through middleware chain
            let context = MiddlewareContext(
                correlationID: traceContext.traceID,
                timestamp: startTime
            )
            let response = try await middlewareChain.execute(
                envelope,
                actor: actor,
                context: context
            ) { envelope, context in
                try await self.executeInvocation(envelope, on: actor)
            }
            let responseData = try JSONEncoder().encode(response)
            try await message.respond(responseData)

            let duration = Date().timeIntervalSince(startTime)

            // Record metrics
            if let metrics {
                let actorType = String(describing: type(of: actor))
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsCount,
                    tags: [
                        "actor_type": actorType,
                        "target": envelope.targetIdentifier,
                        "status": "success"
                    ]
                )
                await metrics.recordHistogramMilliseconds(
                    TrebuchetMetrics.invocationsLatency,
                    milliseconds: duration * 1000,
                    tags: [
                        "actor_type": actorType,
                        "target": envelope.targetIdentifier
                    ]
                )
            }

            await logger.info("Invocation completed", metadata: [
                "actorID": envelope.actorID.id,
                "target": envelope.targetIdentifier,
                "callID": envelope.callID.uuidString,
                "traceID": traceContext.traceID.uuidString,
                "spanID": traceContext.spanID.uuidString,
                "duration_ms": String(format: "%.2f", duration * 1000),
                "status": "success"
            ], correlationID: traceContext.traceID)

        } catch let error as ValidationError {
            // Validation errors - client issue
            let duration = Date().timeIntervalSince(startTime)

            await logger.warning("Request validation failed", metadata: [
                "error": error.description,
                "duration_ms": String(format: "%.2f", duration * 1000)
            ])

            if let metrics {
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsErrors,
                    tags: ["reason": "validation_error"]
                )
            }

            let response = ResponseEnvelope.failure(
                callID: UUID(),
                error: "Validation failed: \(error.description)"
            )
            if let responseData = try? JSONEncoder().encode(response) {
                try? await message.respond(responseData)
            }
        } catch let error as AuthenticationError {
            // Authentication errors - client issue
            let duration = Date().timeIntervalSince(startTime)

            await logger.warning("Authentication failed", metadata: [
                "error": error.description,
                "duration_ms": String(format: "%.2f", duration * 1000)
            ])

            if let metrics {
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsErrors,
                    tags: ["reason": "authentication_error"]
                )
            }

            let response = ResponseEnvelope.failure(
                callID: UUID(),
                error: "Authentication failed: \(error.description)"
            )
            if let responseData = try? JSONEncoder().encode(response) {
                try? await message.respond(responseData)
            }
        } catch let error as AuthorizationError {
            // Authorization errors - client issue
            let duration = Date().timeIntervalSince(startTime)

            await logger.warning("Authorization failed", metadata: [
                "error": error.description,
                "duration_ms": String(format: "%.2f", duration * 1000)
            ])

            if let metrics {
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsErrors,
                    tags: ["reason": "authorization_error"]
                )
            }

            let response = ResponseEnvelope.failure(
                callID: UUID(),
                error: "Authorization failed: \(error.description)"
            )
            if let responseData = try? JSONEncoder().encode(response) {
                try? await message.respond(responseData)
            }
        } catch let error as RateLimitError {
            // Rate limit errors - client issue
            let duration = Date().timeIntervalSince(startTime)

            await logger.warning("Rate limit exceeded", metadata: [
                "error": error.description,
                "duration_ms": String(format: "%.2f", duration * 1000)
            ])

            if let metrics {
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsErrors,
                    tags: ["reason": "rate_limit_exceeded"]
                )
            }

            let response = ResponseEnvelope.failure(
                callID: UUID(),
                error: "Rate limit exceeded: \(error.description)"
            )
            if let responseData = try? JSONEncoder().encode(response) {
                try? await message.respond(responseData)
            }
        } catch {
            // Handler errors - server issue or actor logic error
            let duration = Date().timeIntervalSince(startTime)

            await logger.error("Actor invocation failed", metadata: [
                "error": String(describing: error),
                "duration_ms": String(format: "%.2f", duration * 1000)
            ])

            // Record error metric
            if let metrics {
                await metrics.incrementCounter(
                    TrebuchetMetrics.invocationsErrors,
                    tags: ["reason": "handler_error"]
                )
            }

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
            await logger.error("Actor method execution failed", metadata: [
                "actorID": envelope.actorID.id,
                "target": envelope.targetIdentifier,
                "callID": envelope.callID.uuidString,
                "error": String(describing: error)
            ])

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
