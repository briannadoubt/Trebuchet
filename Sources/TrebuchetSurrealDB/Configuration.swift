import Foundation
import SurrealDB

// MARK: - SurrealDB Configuration

/// Configuration for connecting to SurrealDB
///
/// This configuration manages SurrealDB connection parameters including URL,
/// authentication, and namespace/database selection. It supports both development
/// and production environments with convenient builders and environment variable loading.
///
/// ## Usage
///
/// ### Development Configuration
///
/// ```swift
/// let config = SurrealDBConfiguration.development()
/// ```
///
/// ### Production Configuration
///
/// ```swift
/// let config = SurrealDBConfiguration(
///     url: "wss://production.surrealdb.com/rpc",
///     namespace: "production",
///     database: "myapp",
///     auth: .root(RootAuth(username: "admin", password: "secure-password"))
/// )
/// ```
///
/// ### Environment Variable Loading
///
/// ```swift
/// let config = try SurrealDBConfiguration.fromEnvironment()
/// // Loads from:
/// // - SURREALDB_URL
/// // - SURREALDB_NAMESPACE
/// // - SURREALDB_DATABASE
/// // - SURREALDB_USERNAME (optional, for root auth)
/// // - SURREALDB_PASSWORD (optional, for root auth)
/// ```
public struct SurrealDBConfiguration: Sendable {
    /// The WebSocket URL for the SurrealDB connection
    ///
    /// Examples:
    /// - Development: `ws://localhost:8000/rpc`
    /// - Production: `wss://your-server.com/rpc`
    public let url: String

    /// The SurrealDB namespace
    public let namespace: String

    /// The SurrealDB database name
    public let database: String

    /// Authentication credentials
    public let auth: SurrealDBAuth?

    /// Connection timeout
    public let timeout: Duration

    /// Maximum number of reconnection attempts
    public let maxReconnectAttempts: Int

    /// Initialize SurrealDB configuration
    ///
    /// - Parameters:
    ///   - url: WebSocket URL (e.g., "ws://localhost:8000/rpc")
    ///   - namespace: SurrealDB namespace
    ///   - database: Database name
    ///   - auth: Authentication credentials (optional)
    ///   - timeout: Connection timeout (default: 30 seconds)
    ///   - maxReconnectAttempts: Maximum reconnection attempts (default: 3)
    public init(
        url: String,
        namespace: String,
        database: String,
        auth: SurrealDBAuth? = nil,
        timeout: Duration = .seconds(30),
        maxReconnectAttempts: Int = 3
    ) {
        self.url = url
        self.namespace = namespace
        self.database = database
        self.auth = auth
        self.timeout = timeout
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    /// Validate the configuration
    ///
    /// - Throws: `ConfigurationError` if validation fails
    public func validate() throws {
        // Validate URL
        guard url.hasPrefix("ws://") || url.hasPrefix("wss://") else {
            throw ConfigurationError.invalidURL("URL must start with ws:// or wss://")
        }

        guard URL(string: url) != nil else {
            throw ConfigurationError.invalidURL("Invalid URL format: \(url)")
        }

        // Validate namespace
        guard !namespace.isEmpty else {
            throw ConfigurationError.invalidNamespace("Namespace cannot be empty")
        }

        // Validate database
        guard !database.isEmpty else {
            throw ConfigurationError.invalidDatabase("Database cannot be empty")
        }

        // Validate timeout
        guard timeout > .zero else {
            throw ConfigurationError.invalidTimeout("Timeout must be greater than zero")
        }

        // Validate reconnect attempts
        guard maxReconnectAttempts >= 0 else {
            throw ConfigurationError.invalidReconnectAttempts("Max reconnect attempts cannot be negative")
        }
    }

    /// Create a SurrealDB client from this configuration
    ///
    /// - Returns: Configured SurrealDB client
    /// - Throws: Configuration or connection errors
    public func createClient() async throws -> SurrealDB {
        try validate()

        let client = try SurrealDB(url: url)
        try await client.connect()

        // Authenticate if credentials provided
        if let auth = auth {
            switch auth {
            case .root(let rootAuth):
                try await client.signin(.root(rootAuth))
            case .namespace(let namespaceAuth):
                try await client.signin(.namespace(namespaceAuth))
            case .database(let databaseAuth):
                try await client.signin(.database(databaseAuth))
            case .recordAccess(let recordAccessAuth):
                try await client.signin(.recordAccess(recordAccessAuth))
            }
        }

        // Select namespace and database
        try await client.use(namespace: namespace, database: database)

        return client
    }
}

// MARK: - Authentication

/// Authentication options for SurrealDB
public enum SurrealDBAuth: Sendable {
    /// Root-level authentication
    case root(RootAuth)

    /// Namespace-level authentication
    case namespace(NamespaceAuth)

    /// Database-level authentication
    case database(DatabaseAuth)

    /// Record access authentication
    case recordAccess(RecordAccessAuth)
}

// MARK: - Convenience Builders

extension SurrealDBConfiguration {
    /// Development configuration with sensible defaults
    ///
    /// Uses localhost:8000 with development namespace/database.
    /// No authentication required.
    ///
    /// - Parameters:
    ///   - namespace: Namespace name (default: "development")
    ///   - database: Database name (default: "test")
    /// - Returns: Development configuration
    public static func development(
        namespace: String = "development",
        database: String = "test"
    ) -> SurrealDBConfiguration {
        SurrealDBConfiguration(
            url: "ws://localhost:8000/rpc",
            namespace: namespace,
            database: database,
            auth: nil
        )
    }

    /// Load configuration from environment variables
    ///
    /// Reads from:
    /// - `SURREALDB_URL` (required): WebSocket URL
    /// - `SURREALDB_NAMESPACE` (required): Namespace
    /// - `SURREALDB_DATABASE` (required): Database
    /// - `SURREALDB_USERNAME` (optional): Root username
    /// - `SURREALDB_PASSWORD` (optional): Root password
    /// - `SURREALDB_TIMEOUT` (optional): Connection timeout in seconds
    /// - `SURREALDB_MAX_RECONNECT_ATTEMPTS` (optional): Max reconnection attempts
    ///
    /// - Returns: Configuration loaded from environment
    /// - Throws: `ConfigurationError` if required variables are missing
    public static func fromEnvironment() throws -> SurrealDBConfiguration {
        let env = ProcessInfo.processInfo.environment

        guard let url = env["SURREALDB_URL"] else {
            throw ConfigurationError.missingEnvironmentVariable("SURREALDB_URL")
        }

        guard let namespace = env["SURREALDB_NAMESPACE"] else {
            throw ConfigurationError.missingEnvironmentVariable("SURREALDB_NAMESPACE")
        }

        guard let database = env["SURREALDB_DATABASE"] else {
            throw ConfigurationError.missingEnvironmentVariable("SURREALDB_DATABASE")
        }

        // Optional authentication
        let auth: SurrealDBAuth?
        if let username = env["SURREALDB_USERNAME"],
           let password = env["SURREALDB_PASSWORD"] {
            auth = .root(RootAuth(username: username, password: password))
        } else {
            auth = nil
        }

        // Optional timeout
        let timeout: Duration
        if let timeoutStr = env["SURREALDB_TIMEOUT"],
           let timeoutSeconds = Int(timeoutStr) {
            timeout = .seconds(timeoutSeconds)
        } else {
            timeout = .seconds(30)
        }

        // Optional max reconnect attempts
        let maxReconnectAttempts: Int
        if let attemptsStr = env["SURREALDB_MAX_RECONNECT_ATTEMPTS"],
           let attempts = Int(attemptsStr) {
            maxReconnectAttempts = attempts
        } else {
            maxReconnectAttempts = 3
        }

        return SurrealDBConfiguration(
            url: url,
            namespace: namespace,
            database: database,
            auth: auth,
            timeout: timeout,
            maxReconnectAttempts: maxReconnectAttempts
        )
    }
}

// MARK: - Configuration Error

/// Errors that can occur during configuration
public enum ConfigurationError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidNamespace(String)
    case invalidDatabase(String)
    case invalidTimeout(String)
    case invalidReconnectAttempts(String)
    case missingEnvironmentVariable(String)

    public var description: String {
        switch self {
        case .invalidURL(let message):
            return "Invalid URL: \(message)"
        case .invalidNamespace(let message):
            return "Invalid namespace: \(message)"
        case .invalidDatabase(let message):
            return "Invalid database: \(message)"
        case .invalidTimeout(let message):
            return "Invalid timeout: \(message)"
        case .invalidReconnectAttempts(let message):
            return "Invalid reconnect attempts: \(message)"
        case .missingEnvironmentVariable(let variable):
            return "Missing required environment variable: \(variable)"
        }
    }
}
