import Foundation

/// Errors that can occur in the Trebuchet distributed actor system
public enum TrebuchetError: Error, Sendable {
    /// Failed to connect to a remote actor system
    case connectionFailed(host: String, port: UInt16, underlying: Error?)

    /// The connection was closed unexpectedly
    case connectionClosed

    /// Failed to serialize a message
    case serializationFailed(Error)

    /// Failed to deserialize a message
    case deserializationFailed(Error)

    /// The requested actor was not found
    case actorNotFound(TrebuchetActorID)

    /// The remote call timed out
    case timeout(duration: Duration)

    /// The invocation failed on the remote side
    case remoteInvocationFailed(String)

    /// The actor system is not running
    case systemNotRunning

    /// Invalid configuration
    case invalidConfiguration(String)
}

extension TrebuchetError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionFailed(let host, let port, let underlying):
            let base = "Failed to connect to \(host):\(port)"
            if let underlying {
                return "\(base): \(underlying)"
            }
            return base
        case .connectionClosed:
            return "Connection closed unexpectedly"
        case .serializationFailed(let error):
            return "Serialization failed: \(error)"
        case .deserializationFailed(let error):
            return "Deserialization failed: \(error)"
        case .actorNotFound(let id):
            return "Actor not found: \(id)"
        case .timeout(let duration):
            return "Operation timed out after \(duration)"
        case .remoteInvocationFailed(let message):
            return "Remote invocation failed: \(message)"
        case .systemNotRunning:
            return "Actor system is not running"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        }
    }
}
