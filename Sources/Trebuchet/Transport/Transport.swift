import Foundation

#if canImport(NIOSSL)
import NIOSSL
#endif

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
    /// Establish a connection to an endpoint (for clients).
    ///
    /// This method should perform the actual network handshake and throw
    /// if the connection cannot be established.
    func connect(to endpoint: Endpoint) async throws

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

#if canImport(NIOSSL)
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
#else
/// Placeholder TLS configuration for platforms without NIOSSL support.
public struct TLSConfiguration: Sendable {
    public init() {}
}
#endif

/// Configuration options for transports
public enum TransportConfiguration: Sendable {
    case webSocket(host: String = "0.0.0.0", port: UInt16, tls: TLSConfiguration? = nil)
#if !os(WASI)
    case tcp(host: String = "0.0.0.0", port: UInt16)
#endif
    case local

    public var endpoint: Endpoint {
        switch self {
        case .webSocket(let host, let port, _):
            return Endpoint(host: host, port: port)
#if !os(WASI)
        case .tcp(let host, let port):
            return Endpoint(host: host, port: port)
#endif
        case .local:
            return Endpoint(host: "local", port: 0)
        }
    }

    /// Whether TLS is enabled for this transport
    public var tlsEnabled: Bool {
        switch self {
        case .webSocket(_, _, let tls):
            return tls != nil
#if !os(WASI)
        case .tcp:
            return false
#endif
        case .local:
            return false
        }
    }

    /// The TLS configuration, if any
    public var tlsConfiguration: TLSConfiguration? {
        switch self {
        case .webSocket(_, _, let tls):
            return tls
#if !os(WASI)
        case .tcp:
            return nil
#endif
        case .local:
            return nil
        }
    }
}
