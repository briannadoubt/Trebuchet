#if canImport(SwiftUI)
import Foundation

/// Represents the current state of a Trebuchet connection.
///
/// Use this enum to track and display connection status in your SwiftUI views.
///
/// ```swift
/// switch connection.state {
/// case .connected:
///     Text("Online").foregroundStyle(.green)
/// case .connecting, .reconnecting:
///     ProgressView()
/// case .disconnected:
///     Text("Offline")
/// case .failed(let error):
///     Text("Error: \(error.localizedDescription)")
/// }
/// ```
public enum ConnectionState: Sendable, Equatable {
    /// Not connected to any server.
    case disconnected

    /// Actively establishing a connection.
    case connecting

    /// Successfully connected and ready to communicate.
    case connected

    /// Attempting to reconnect after a connection loss.
    /// - Parameter attempt: The current reconnection attempt number (1-based).
    case reconnecting(attempt: Int)

    /// Connection failed after all retry attempts exhausted.
    /// - Parameter error: The error that caused the failure.
    case failed(ConnectionError)

    /// Whether the connection is currently active and usable.
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Whether the connection is in a transitional state (connecting or reconnecting).
    public var isTransitioning: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    /// Whether the connection can accept new connection requests.
    public var canConnect: Bool {
        switch self {
        case .disconnected, .failed:
            return true
        default:
            return false
        }
    }
}

/// An error wrapper that provides connection context and `Equatable` conformance.
///
/// This wraps ``TrebuchetError`` with additional metadata useful for SwiftUI state management.
public struct ConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The underlying Trebuchet error.
    public let underlyingError: TrebuchetError

    /// When this error occurred.
    public let timestamp: Date

    /// The name of the connection that failed (for multi-server scenarios).
    public let connectionName: String?

    /// Creates a new connection error.
    /// - Parameters:
    ///   - underlyingError: The original ``TrebuchetError``.
    ///   - timestamp: When the error occurred. Defaults to now.
    ///   - connectionName: Optional name identifying which connection failed.
    public init(
        underlyingError: TrebuchetError,
        timestamp: Date = Date(),
        connectionName: String? = nil
    ) {
        self.underlyingError = underlyingError
        self.timestamp = timestamp
        self.connectionName = connectionName
    }

    public var description: String {
        if let name = connectionName {
            return "[\(name)] \(underlyingError)"
        }
        return String(describing: underlyingError)
    }

    public var localizedDescription: String {
        description
    }

    public static func == (lhs: ConnectionError, rhs: ConnectionError) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.connectionName == rhs.connectionName
    }
}

/// Configuration for automatic reconnection behavior.
///
/// Use this to customize how ``TrebuchetConnection`` handles connection failures.
///
/// ```swift
/// // Use aggressive reconnection for real-time apps
/// let connection = TrebuchetConnection(
///     transport: .webSocket(host: "game.example.com", port: 8080),
///     reconnectionPolicy: .aggressive
/// )
///
/// // Or create a custom policy
/// let custom = ReconnectionPolicy(
///     maxAttempts: 3,
///     initialDelay: .seconds(2),
///     maxDelay: .seconds(10),
///     backoffMultiplier: 1.5
/// )
/// ```
public struct ReconnectionPolicy: Sendable, Equatable {
    /// Maximum number of reconnection attempts before giving up.
    public let maxAttempts: Int

    /// Initial delay before the first reconnection attempt.
    public let initialDelay: Duration

    /// Maximum delay between reconnection attempts (caps exponential growth).
    public let maxDelay: Duration

    /// Multiplier applied to delay after each failed attempt.
    public let backoffMultiplier: Double

    /// Default reconnection policy with reasonable settings for most apps.
    ///
    /// - 5 attempts maximum
    /// - 1 second initial delay
    /// - 30 seconds maximum delay
    /// - 2x backoff multiplier
    public static let `default` = ReconnectionPolicy(
        maxAttempts: 5,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0
    )

    /// Aggressive reconnection for real-time applications.
    ///
    /// - 10 attempts maximum
    /// - 500ms initial delay
    /// - 60 seconds maximum delay
    /// - 1.5x backoff multiplier
    public static let aggressive = ReconnectionPolicy(
        maxAttempts: 10,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(60),
        backoffMultiplier: 1.5
    )

    /// No automatic reconnection.
    public static let disabled = ReconnectionPolicy(
        maxAttempts: 0,
        initialDelay: .zero,
        maxDelay: .zero,
        backoffMultiplier: 1.0
    )

    /// Creates a custom reconnection policy.
    /// - Parameters:
    ///   - maxAttempts: Maximum reconnection attempts. Use 0 to disable.
    ///   - initialDelay: Delay before first attempt.
    ///   - maxDelay: Maximum delay between attempts.
    ///   - backoffMultiplier: Multiplier for exponential backoff.
    public init(
        maxAttempts: Int,
        initialDelay: Duration,
        maxDelay: Duration,
        backoffMultiplier: Double
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = max(1.0, backoffMultiplier)
    }

    /// Calculate the delay for a given attempt number.
    /// - Parameter attempt: The attempt number (1-based).
    /// - Returns: The delay before this attempt.
    public func delay(for attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }

        let initialSeconds = Double(initialDelay.components.seconds) +
                            Double(initialDelay.components.attoseconds) / 1e18
        let maxSeconds = Double(maxDelay.components.seconds) +
                        Double(maxDelay.components.attoseconds) / 1e18

        let calculated = initialSeconds * pow(backoffMultiplier, Double(attempt - 1))
        let capped = min(calculated, maxSeconds)

        return .milliseconds(Int64(capped * 1000))
    }
}

/// Events emitted during connection lifecycle.
///
/// Subscribe to these events via ``TrebuchetConnection/events`` for custom handling:
///
/// ```swift
/// Task {
///     for await event in connection.events {
///         switch event {
///         case .didConnect:
///             print("Connected!")
///         case .willReconnect(let attempt, let delay):
///             print("Reconnecting (attempt \(attempt)) in \(delay)...")
///         default:
///             break
///         }
///     }
/// }
/// ```
public enum ConnectionEvent: Sendable {
    /// About to attempt connection.
    case willConnect

    /// Successfully connected.
    case didConnect

    /// About to disconnect (either manually or due to error).
    case willDisconnect

    /// Disconnected from server.
    case didDisconnect

    /// Connection failed with the given error.
    case didFailWithError(TrebuchetError)

    /// About to attempt reconnection.
    /// - Parameters:
    ///   - attempt: The attempt number (1-based).
    ///   - delay: How long until the attempt is made.
    case willReconnect(attempt: Int, delay: Duration)

    /// Successfully reconnected after previous failure.
    /// - Parameter afterAttempts: How many attempts were needed.
    case didReconnect(afterAttempts: Int)
}
#endif
