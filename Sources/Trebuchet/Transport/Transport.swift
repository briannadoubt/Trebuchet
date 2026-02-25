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

/// Resolution options for ``TransportConfiguration/auto(_:)``.
public struct AutoTransportOptions: Sendable {
    /// Environment variable used for host override.
    public let environmentHostKey: String

    /// Environment variable used for port override.
    public let environmentPortKey: String

    /// Fallback host when env overrides are not available.
    public let fallbackHost: String

    /// Fallback port when env overrides are not available.
    public let fallbackPort: UInt16

    /// Whether localhost fallback is allowed when env values are missing.
    public let allowLocalhostFallback: Bool

    public init(
        environmentHostKey: String = "TREBUCHET_HOST",
        environmentPortKey: String = "TREBUCHET_PORT",
        fallbackHost: String = "127.0.0.1",
        fallbackPort: UInt16 = 8080,
        allowLocalhostFallback: Bool = true
    ) {
        self.environmentHostKey = environmentHostKey
        self.environmentPortKey = environmentPortKey
        self.fallbackHost = fallbackHost
        self.fallbackPort = fallbackPort
        self.allowLocalhostFallback = allowLocalhostFallback
    }

    public static let `default` = AutoTransportOptions()
}

/// Configuration options for transports
public enum TransportConfiguration: Sendable {
    case webSocket(host: String = "0.0.0.0", port: UInt16, tls: TLSConfiguration? = nil)
#if !os(WASI)
    case tcp(host: String = "0.0.0.0", port: UInt16)
#endif
    case local
    case auto(AutoTransportOptions = .default)

    public var endpoint: Endpoint {
        switch resolvedForRuntime().resolved {
        case .webSocket(let host, let port, _):
            return Endpoint(host: host, port: port)
#if !os(WASI)
        case .tcp(let host, let port):
            return Endpoint(host: host, port: port)
#endif
        case .local:
            return Endpoint(host: "local", port: 0)
        case .auto:
            return Endpoint(host: "localhost", port: 8080)
        }
    }

    /// Whether TLS is enabled for this transport
    public var tlsEnabled: Bool {
        switch resolvedForRuntime().resolved {
        case .webSocket(_, _, let tls):
            return tls != nil
#if !os(WASI)
        case .tcp:
            return false
#endif
        case .local:
            return false
        case .auto:
            return false
        }
    }

    /// The TLS configuration, if any
    public var tlsConfiguration: TLSConfiguration? {
        switch resolvedForRuntime().resolved {
        case .webSocket(_, _, let tls):
            return tls
#if !os(WASI)
        case .tcp:
            return nil
#endif
        case .local:
            return nil
        case .auto:
            return nil
        }
    }

    /// Resolve `.auto` into a concrete transport for runtime use.
    ///
    /// - Parameter environment: Optional environment map used for deterministic tests.
    /// - Returns: A concrete runtime transport plus an optional validation error.
    public func resolvedForRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (resolved: TransportConfiguration, error: TrebuchetError?) {
        switch self {
        case .auto(let options):
            let envHost = environment[options.environmentHostKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let envPortRaw = environment[options.environmentPortKey]?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let envHost, !envHost.isEmpty, let envPortRaw, !envPortRaw.isEmpty {
                guard let envPort = UInt16(envPortRaw) else {
                    return (
                        .webSocket(host: options.fallbackHost, port: options.fallbackPort),
                        .invalidConfiguration(
                            "Environment variable \(options.environmentPortKey) must be a UInt16 port. Received '\(envPortRaw)'."
                        )
                    )
                }
                return (.webSocket(host: envHost, port: envPort), nil)
            }

            if envHost != nil || envPortRaw != nil {
                if options.allowLocalhostFallback {
                    return (.webSocket(host: options.fallbackHost, port: options.fallbackPort), nil)
                }
                return (
                    .webSocket(host: options.fallbackHost, port: options.fallbackPort),
                    .invalidConfiguration(
                        "Both \(options.environmentHostKey) and \(options.environmentPortKey) must be set when localhost fallback is disabled."
                    )
                )
            }

            if options.allowLocalhostFallback {
                return (.webSocket(host: options.fallbackHost, port: options.fallbackPort), nil)
            }
            return (
                .webSocket(host: options.fallbackHost, port: options.fallbackPort),
                .invalidConfiguration(
                    "No automatic transport endpoint found. Set \(options.environmentHostKey) and \(options.environmentPortKey), or enable localhost fallback."
                )
            )
        default:
            return (self, nil)
        }
    }

    /// Resolve `.auto` and throw if configuration is invalid.
    ///
    /// - Parameter environment: Optional environment map used for deterministic tests.
    /// - Throws: ``TrebuchetError/invalidConfiguration(_:)`` when auto resolution fails.
    public func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TransportConfiguration {
        let result = resolvedForRuntime(environment: environment)
        if let error = result.error {
            throw error
        }
        return result.resolved
    }
}
