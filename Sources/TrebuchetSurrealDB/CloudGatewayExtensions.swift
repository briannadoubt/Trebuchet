import Foundation
import SurrealDB
import TrebuchetCloud
import TrebuchetObservability

// MARK: - CloudGateway Configuration Extensions

extension CloudGateway.Configuration {
    /// Create a CloudGateway configuration with SurrealDB state store
    ///
    /// This convenience initializer sets up a CloudGateway with SurrealDB for
    /// actor state persistence. Useful for production deployments where you want
    /// type-safe, relational state management.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let config = try await CloudGateway.Configuration.withSurrealDB(
    ///     url: "wss://production.surrealdb.com/rpc",
    ///     namespace: "production",
    ///     database: "myapp",
    ///     auth: .root(RootAuth(username: "admin", password: "secure"))
    /// )
    ///
    /// let gateway = CloudGateway(configuration: config)
    /// ```
    ///
    /// - Parameters:
    ///   - url: SurrealDB WebSocket URL
    ///   - namespace: SurrealDB namespace
    ///   - database: SurrealDB database
    ///   - auth: Authentication credentials (optional)
    ///   - host: Gateway host (default: "0.0.0.0")
    ///   - port: Gateway port (default: 8080)
    ///   - registry: Optional service registry
    ///   - healthCheckPath: Health check endpoint path
    ///   - invokePath: Invocation endpoint path
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway configuration with SurrealDB state store
    /// - Throws: Configuration or connection errors
    public static func withSurrealDB(
        url: String,
        namespace: String,
        database: String,
        auth: SurrealDBAuth? = nil,
        host: String = "0.0.0.0",
        port: UInt16 = 8080,
        registry: (any ServiceRegistry)? = nil,
        healthCheckPath: String = "/health",
        invokePath: String = "/invoke",
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway.Configuration {
        let config = SurrealDBConfiguration(
            url: url,
            namespace: namespace,
            database: database,
            auth: auth
        )

        let client = try await config.createClient()
        let stateStore = try await SurrealDBStateStore(db: client)

        return CloudGateway.Configuration(
            host: host,
            port: port,
            stateStore: stateStore,
            registry: registry,
            healthCheckPath: healthCheckPath,
            invokePath: invokePath,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )
    }

    /// Create a CloudGateway configuration with SurrealDB from a configuration object
    ///
    /// - Parameters:
    ///   - surrealConfig: SurrealDB configuration
    ///   - host: Gateway host (default: "0.0.0.0")
    ///   - port: Gateway port (default: 8080)
    ///   - registry: Optional service registry
    ///   - healthCheckPath: Health check endpoint path
    ///   - invokePath: Invocation endpoint path
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway configuration with SurrealDB state store
    /// - Throws: Configuration or connection errors
    public static func withSurrealDB(
        configuration surrealConfig: SurrealDBConfiguration,
        host: String = "0.0.0.0",
        port: UInt16 = 8080,
        registry: (any ServiceRegistry)? = nil,
        healthCheckPath: String = "/health",
        invokePath: String = "/invoke",
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway.Configuration {
        let client = try await surrealConfig.createClient()
        let stateStore = try await SurrealDBStateStore(db: client)

        return CloudGateway.Configuration(
            host: host,
            port: port,
            stateStore: stateStore,
            registry: registry,
            healthCheckPath: healthCheckPath,
            invokePath: invokePath,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )
    }

    /// Create a CloudGateway configuration with SurrealDB from environment variables
    ///
    /// This is the most convenient method for production deployments. It reads
    /// SurrealDB connection details from environment variables:
    ///
    /// - `SURREALDB_URL`: WebSocket URL (required)
    /// - `SURREALDB_NAMESPACE`: Namespace (required)
    /// - `SURREALDB_DATABASE`: Database (required)
    /// - `SURREALDB_USERNAME`: Root username (optional)
    /// - `SURREALDB_PASSWORD`: Root password (optional)
    /// - `GATEWAY_HOST`: Gateway host (optional, default: "0.0.0.0")
    /// - `GATEWAY_PORT`: Gateway port (optional, default: 8080)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Set environment variables
    /// export SURREALDB_URL="wss://db.example.com/rpc"
    /// export SURREALDB_NAMESPACE="production"
    /// export SURREALDB_DATABASE="myapp"
    /// export SURREALDB_USERNAME="admin"
    /// export SURREALDB_PASSWORD="secure"
    ///
    /// // Create configuration
    /// let config = try await CloudGateway.Configuration.withSurrealDBFromEnvironment()
    /// let gateway = CloudGateway(configuration: config)
    /// ```
    ///
    /// - Parameters:
    ///   - registry: Optional service registry
    ///   - healthCheckPath: Health check endpoint path
    ///   - invokePath: Invocation endpoint path
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway configuration with SurrealDB state store
    /// - Throws: Configuration or connection errors
    public static func withSurrealDBFromEnvironment(
        registry: (any ServiceRegistry)? = nil,
        healthCheckPath: String = "/health",
        invokePath: String = "/invoke",
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway.Configuration {
        let surrealConfig = try SurrealDBConfiguration.fromEnvironment()
        let client = try await surrealConfig.createClient()
        let stateStore = try await SurrealDBStateStore(db: client)

        // Optional gateway configuration from environment
        let env = ProcessInfo.processInfo.environment
        let host = env["GATEWAY_HOST"] ?? "0.0.0.0"
        let port: UInt16 = {
            if let portStr = env["GATEWAY_PORT"], let portNum = UInt16(portStr) {
                return portNum
            }
            return 8080
        }()

        return CloudGateway.Configuration(
            host: host,
            port: port,
            stateStore: stateStore,
            registry: registry,
            healthCheckPath: healthCheckPath,
            invokePath: invokePath,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )
    }
}

// MARK: - CloudGateway Convenience Builders

extension CloudGateway {
    /// Create a CloudGateway with SurrealDB state store
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let gateway = try await CloudGateway.withSurrealDB(
    ///     url: "wss://production.surrealdb.com/rpc",
    ///     namespace: "production",
    ///     database: "myapp",
    ///     auth: .root(RootAuth(username: "admin", password: "secure"))
    /// )
    ///
    /// let actor = MyActor(actorSystem: gateway.system)
    /// try await gateway.expose(actor, as: "my-actor")
    /// try await gateway.run()
    /// ```
    ///
    /// - Parameters:
    ///   - url: SurrealDB WebSocket URL
    ///   - namespace: SurrealDB namespace
    ///   - database: SurrealDB database
    ///   - auth: Authentication credentials (optional)
    ///   - host: Gateway host (default: "0.0.0.0")
    ///   - port: Gateway port (default: 8080)
    ///   - registry: Optional service registry
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway instance with SurrealDB
    /// - Throws: Configuration or connection errors
    public static func withSurrealDB(
        url: String,
        namespace: String,
        database: String,
        auth: SurrealDBAuth? = nil,
        host: String = "0.0.0.0",
        port: UInt16 = 8080,
        registry: (any ServiceRegistry)? = nil,
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway {
        let configuration = try await Configuration.withSurrealDB(
            url: url,
            namespace: namespace,
            database: database,
            auth: auth,
            host: host,
            port: port,
            registry: registry,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )

        return CloudGateway(configuration: configuration)
    }

    /// Create a CloudGateway with SurrealDB from a configuration object
    ///
    /// - Parameters:
    ///   - surrealConfig: SurrealDB configuration
    ///   - host: Gateway host (default: "0.0.0.0")
    ///   - port: Gateway port (default: 8080)
    ///   - registry: Optional service registry
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway instance with SurrealDB
    /// - Throws: Configuration or connection errors
    public static func withSurrealDB(
        configuration surrealConfig: SurrealDBConfiguration,
        host: String = "0.0.0.0",
        port: UInt16 = 8080,
        registry: (any ServiceRegistry)? = nil,
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway {
        let configuration = try await Configuration.withSurrealDB(
            configuration: surrealConfig,
            host: host,
            port: port,
            registry: registry,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )

        return CloudGateway(configuration: configuration)
    }

    /// Create a CloudGateway with SurrealDB from environment variables
    ///
    /// This is the recommended approach for production deployments.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // In your Lambda handler or server entry point:
    /// let gateway = try await CloudGateway.withSurrealDBFromEnvironment()
    ///
    /// // Expose actors
    /// let gameRoom = GameRoom(actorSystem: gateway.system)
    /// try await gateway.expose(gameRoom, as: "game-room")
    ///
    /// // Start serving
    /// try await gateway.run()
    /// ```
    ///
    /// - Parameters:
    ///   - registry: Optional service registry
    ///   - loggingConfiguration: Logging settings
    ///   - metricsCollector: Optional metrics collector
    ///   - middlewares: Middleware stack
    /// - Returns: CloudGateway instance with SurrealDB
    /// - Throws: Configuration or connection errors
    public static func withSurrealDBFromEnvironment(
        registry: (any ServiceRegistry)? = nil,
        loggingConfiguration: LoggingConfiguration = .default,
        metricsCollector: (any MetricsCollector)? = nil,
        middlewares: [any CloudMiddleware] = []
    ) async throws -> CloudGateway {
        let configuration = try await Configuration.withSurrealDBFromEnvironment(
            registry: registry,
            loggingConfiguration: loggingConfiguration,
            metricsCollector: metricsCollector,
            middlewares: middlewares
        )

        return CloudGateway(configuration: configuration)
    }
}

// MARK: - SurrealDB Client Pool

/// Connection pool for managing SurrealDB client instances
///
/// This actor manages a pool of SurrealDB connections for high-throughput scenarios.
/// It provides connection reuse and automatic lifecycle management.
///
/// ## Usage
///
/// ```swift
/// let pool = SurrealDBConnectionPool(configuration: config, maxConnections: 10)
///
/// // Acquire a connection
/// let client = try await pool.acquire()
///
/// // Use the connection
/// let results = try await client.query(Todo.self)
///
/// // Release back to pool
/// await pool.release(client)
/// ```
///
/// For most use cases, the simpler `withConnection` pattern is recommended:
///
/// ```swift
/// try await pool.withConnection { client in
///     try await client.create(todo)
/// }
/// ```
public actor SurrealDBConnectionPool {
    private let configuration: SurrealDBConfiguration
    private let maxConnections: Int
    private var availableConnections: [SurrealDB] = []
    private var totalConnections: Int = 0
    private var waitingRequests: [CheckedContinuation<SurrealDB, Error>] = []

    /// Initialize a connection pool
    ///
    /// - Parameters:
    ///   - configuration: SurrealDB configuration
    ///   - maxConnections: Maximum number of connections (default: 5)
    public init(
        configuration: SurrealDBConfiguration,
        maxConnections: Int = 5
    ) {
        self.configuration = configuration
        self.maxConnections = maxConnections
    }

    /// Acquire a connection from the pool
    ///
    /// If all connections are in use and the pool is at capacity, this will
    /// wait until a connection becomes available.
    ///
    /// - Returns: A SurrealDB client instance
    /// - Throws: Configuration or connection errors
    public func acquire() async throws -> SurrealDB {
        // Return available connection if one exists
        if !availableConnections.isEmpty {
            return availableConnections.removeFirst()
        }

        // Create new connection if under limit
        if totalConnections < maxConnections {
            totalConnections += 1
            return try await configuration.createClient()
        }

        // Wait for a connection to become available
        return try await withCheckedThrowingContinuation { continuation in
            waitingRequests.append(continuation)
        }
    }

    /// Release a connection back to the pool
    ///
    /// - Parameter client: The client to release
    public func release(_ client: SurrealDB) {
        // If there are waiting requests, fulfill the first one
        if !waitingRequests.isEmpty {
            let continuation = waitingRequests.removeFirst()
            continuation.resume(returning: client)
            return
        }

        // Otherwise add to available connections
        availableConnections.append(client)
    }

    /// Execute a closure with a pooled connection
    ///
    /// This is the recommended way to use the pool. The connection is automatically
    /// acquired and released, even if an error occurs.
    ///
    /// - Parameter work: Closure to execute with the connection
    /// - Returns: Result of the closure
    /// - Throws: Errors from connection acquisition or the closure
    public func withConnection<T: Sendable>(
        _ work: @Sendable (SurrealDB) async throws -> T
    ) async throws -> T {
        let client = try await acquire()
        defer {
            Task {
                release(client)
            }
        }
        return try await work(client)
    }

    /// Drain all connections and close them
    ///
    /// Call this during shutdown to properly clean up resources.
    public func shutdown() async {
        // Cancel all waiting requests
        for continuation in waitingRequests {
            continuation.resume(throwing: ConnectionPoolError.shuttingDown)
        }
        waitingRequests.removeAll()

        // Close all available connections
        for client in availableConnections {
            try? await client.disconnect()
        }
        availableConnections.removeAll()

        totalConnections = 0
    }
}

// MARK: - Connection Pool Error

/// Errors that can occur with connection pooling
public enum ConnectionPoolError: Error, CustomStringConvertible {
    case shuttingDown

    public var description: String {
        switch self {
        case .shuttingDown:
            return "Connection pool is shutting down"
        }
    }
}

// MARK: - Dependency Injection Helpers

extension SurrealDBConfiguration {
    /// Create a shared SurrealDB client for dependency injection
    ///
    /// This creates a single client instance that can be shared across multiple
    /// actors. Useful for reducing connection overhead in development or when
    /// connection pooling is not needed.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let config = SurrealDBConfiguration.development()
    /// let client = try await config.createSharedClient()
    ///
    /// let actor1 = TodoList(actorSystem: system, db: client)
    /// let actor2 = UserService(actorSystem: system, db: client)
    /// ```
    ///
    /// - Returns: Shared SurrealDB client instance
    /// - Throws: Configuration or connection errors
    public func createSharedClient() async throws -> SurrealDB {
        try await createClient()
    }
}

