import Foundation
import NIOSSL

/// An endpoint for network communication
public struct Endpoint: Sendable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String {
        "\(host):\(port)"
    }
}

/// Protocol for transport implementations in Trebuchet.
///
/// Transports handle the low-level network communication between
/// distributed actor systems. Different implementations can use
/// WebSocket, HTTP, TCP, or custom protocols.
public protocol TrebuchetTransport: Sendable {
    /// Send data to a specific endpoint
    func send(_ data: Data, to endpoint: Endpoint) async throws

    /// Start listening for incoming connections
    func listen(on endpoint: Endpoint) async throws

    /// Stop the transport
    func shutdown() async

    /// Stream of incoming messages
    var incoming: AsyncStream<TransportMessage> { get }
}

/// A message received from the transport layer
public struct TransportMessage: Sendable {
    /// The data payload
    public let data: Data

    /// The source endpoint (if known)
    public let source: Endpoint?

    /// Callback to send a response
    public let respond: @Sendable (Data) async throws -> Void

    public init(
        data: Data,
        source: Endpoint?,
        respond: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.data = data
        self.source = source
        self.respond = respond
    }
}

/// TLS configuration for secure connections
public struct TLSConfiguration: Sendable {
    /// Certificate chain in PEM format
    public let certificateChain: [NIOSSLCertificate]

    /// Private key in PEM format
    public let privateKey: NIOSSLPrivateKey

    /// Create TLS configuration from PEM-encoded certificate and key files
    /// - Parameters:
    ///   - certificatePath: Path to PEM certificate file (or chain)
    ///   - privateKeyPath: Path to PEM private key file
    public init(certificatePath: String, privateKeyPath: String) throws {
        self.certificateChain = try NIOSSLCertificate.fromPEMFile(certificatePath)
        self.privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
    }

    /// Create TLS configuration from PEM-encoded strings
    /// - Parameters:
    ///   - certificatePEM: PEM-encoded certificate (or chain)
    ///   - privateKeyPEM: PEM-encoded private key
    public init(certificatePEM: String, privateKeyPEM: String) throws {
        self.certificateChain = try NIOSSLCertificate.fromPEMBytes([UInt8](certificatePEM.utf8))
        self.privateKey = try NIOSSLPrivateKey(bytes: [UInt8](privateKeyPEM.utf8), format: .pem)
    }

    /// Create TLS configuration directly from certificates and key
    public init(certificateChain: [NIOSSLCertificate], privateKey: NIOSSLPrivateKey) {
        self.certificateChain = certificateChain
        self.privateKey = privateKey
    }
}

/// Configuration options for transports
public enum TransportConfiguration: Sendable {
    case webSocket(host: String = "0.0.0.0", port: UInt16, tls: TLSConfiguration? = nil)
    case tcp(host: String = "0.0.0.0", port: UInt16)

    public var endpoint: Endpoint {
        switch self {
        case .webSocket(let host, let port, _):
            return Endpoint(host: host, port: port)
        case .tcp(let host, let port):
            return Endpoint(host: host, port: port)
        }
    }

    /// Whether TLS is enabled for this transport
    public var tlsEnabled: Bool {
        switch self {
        case .webSocket(_, _, let tls):
            return tls != nil
        case .tcp:
            return false
        }
    }

    /// The TLS configuration, if any
    public var tlsConfiguration: TLSConfiguration? {
        switch self {
        case .webSocket(_, _, let tls):
            return tls
        case .tcp:
            return nil
        }
    }
}
