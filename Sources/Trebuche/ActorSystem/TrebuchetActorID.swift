import Distributed
import Foundation

/// Identifies a distributed actor in the Trebuchet system.
///
/// The ID contains enough information to locate and communicate with the actor,
/// whether it's local or remote.
public struct TrebuchetActorID: Sendable, Hashable, Codable {
    /// Unique identifier for this actor instance
    public let id: String

    /// The host where this actor resides (nil for local actors)
    public let host: String?

    /// The port on which the actor's system is listening (nil for local actors)
    public let port: UInt16?

    /// Whether this actor is local to the current system
    public var isLocal: Bool {
        host == nil && port == nil
    }

    /// Whether this actor is remote
    public var isRemote: Bool {
        !isLocal
    }

    /// Create a local actor ID
    public init(id: String) {
        self.id = id
        self.host = nil
        self.port = nil
    }

    /// Create a remote actor ID
    public init(id: String, host: String, port: UInt16) {
        self.id = id
        self.host = host
        self.port = port
    }

    /// Create an ID from an endpoint string (e.g., "actor-id@host:port")
    public init?(parsing string: String) {
        let parts = string.split(separator: "@")
        guard let idPart = parts.first else { return nil }

        self.id = String(idPart)

        if parts.count > 1 {
            let hostPort = parts[1].split(separator: ":")
            guard hostPort.count == 2,
                  let port = UInt16(hostPort[1]) else { return nil }
            self.host = String(hostPort[0])
            self.port = port
        } else {
            self.host = nil
            self.port = nil
        }
    }

    /// String representation suitable for network transmission
    public var endpoint: String {
        if let host, let port {
            return "\(id)@\(host):\(port)"
        }
        return id
    }
}

extension TrebuchetActorID: CustomStringConvertible {
    public var description: String {
        endpoint
    }
}
