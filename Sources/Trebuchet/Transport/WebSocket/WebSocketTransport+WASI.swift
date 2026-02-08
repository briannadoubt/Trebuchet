#if os(WASI)
import Foundation

/// WASI fallback transport.
///
/// Networking transport implementations for WASI are runtime-dependent and are not
/// provided by the NIO/WebSocketKit implementation used on native platforms.
/// This placeholder keeps the API surface available for compilation.
public final class WebSocketTransport: TrebuchetTransport, @unchecked Sendable {
    public let incoming: AsyncStream<TransportMessage> = AsyncStream { continuation in
        continuation.finish()
    }

    public init(tlsConfiguration: TLSConfiguration? = nil) {}

    public func connect(to endpoint: Endpoint) async throws {
        throw TrebuchetError.invalidConfiguration("WebSocket transport is not available on WASI in this build")
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        throw TrebuchetError.invalidConfiguration("WebSocket transport is not available on WASI in this build")
    }

    public func listen(on endpoint: Endpoint) async throws {
        throw TrebuchetError.invalidConfiguration("WebSocket transport is not available on WASI in this build")
    }

    public func shutdown() async {}
}
#endif
