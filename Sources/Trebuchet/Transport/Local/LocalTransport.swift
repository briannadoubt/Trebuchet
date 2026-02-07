//===----------------------------------------------------------------------===//
//
// This source file is part of the Trebuchet open source project
//
// Copyright (c) 2024 Trebuchet project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// An in-process transport implementation for local development and testing.
///
/// `LocalTransport` provides a zero-overhead transport mechanism that routes messages
/// directly within the same process without any network overhead. This is ideal for:
///
/// - Unit testing distributed actors
/// - Local development workflows
/// - Single-process deployments
/// - Performance benchmarking (eliminates network latency)
///
/// ## Usage
///
/// The transport provides a shared singleton instance and a convenience server:
///
/// ```swift
/// // Using the shared instance directly
/// let client = TrebuchetClient(transport: .local)
/// try await client.connect()
///
/// // Access the built-in server
/// let room = GameRoom(actorSystem: LocalTransport.shared.server.actorSystem)
/// await LocalTransport.shared.server.expose(room, as: "main-room")
///
/// // Resolve from client
/// let remoteRoom = try client.resolve(GameRoom.self, id: "main-room")
/// ```
///
/// ## Architecture
///
/// Unlike network-based transports (WebSocket, TCP), LocalTransport bypasses serialization
/// and routes messages through in-memory channels:
///
/// 1. **send(_:to:)** decodes the envelope and delivers it directly to the server's message handler
/// 2. **incoming** yields messages from an `AsyncStream` that the server writes to
/// 3. **connect(to:)** and **listen(on:)** are no-ops since everything is in-process
///
/// ## Thread Safety
///
/// LocalTransport is an actor that provides thread-safe access to all mutable state:
/// - The `continuation` is isolated to the actor
/// - The `server` property is initialized during init and never mutated
/// - All message handling is async and uses actor isolation
///
/// ## Performance
///
/// This transport has near-zero overhead:
/// - No serialization/deserialization overhead (direct message passing)
/// - No socket I/O
/// - No network stack traversal
/// - Direct in-memory routing
///
/// Use this for benchmarking to measure pure actor system performance without
/// transport overhead contaminating results.
public actor LocalTransport: TrebuchetTransport {
    /// The shared singleton instance for local transport.
    ///
    /// Use this instance when you want to share a single in-process transport
    /// across your application.
    public static let shared = LocalTransport()

    /// The async stream for receiving messages.
    public nonisolated let incoming: AsyncStream<TransportMessage>

    /// The continuation for writing messages to the stream.
    ///
    /// This is optional because it's finished during shutdown and becomes nil.
    /// Access is synchronized through actor isolation.
    private var continuation: AsyncStream<TransportMessage>.Continuation?

    /// The shared server instance for this transport.
    ///
    /// This provides a convenient way to access a TrebuchetServer configured with
    /// local transport, useful for testing and SwiftUI previews.
    public nonisolated let server: TrebuchetServer

    /// Creates a new local transport instance.
    ///
    /// In most cases, you should use `LocalTransport.shared` instead of creating
    /// new instances. Creating multiple instances can lead to actor isolation since
    /// each transport maintains its own message routing.
    private init() {
        var continuation: AsyncStream<TransportMessage>.Continuation?
        self.incoming = AsyncStream { cont in
            continuation = cont
        }
        self.continuation = continuation
        self.server = TrebuchetServer(transport: .local)
    }

    /// Connects to the specified endpoint.
    ///
    /// For local transport, this is a no-op since everything is in-process.
    /// The transport is always "connected" and ready to route messages.
    ///
    /// - Parameter endpoint: The endpoint to connect to (ignored for local transport).
    public func connect(to endpoint: Endpoint) async throws {
        // No-op: local transport is always connected
    }

    /// Sends data to the specified endpoint.
    ///
    /// This creates a `TransportMessage` and delivers it directly to any registered
    /// message handlers via the incoming stream.
    ///
    /// - Parameters:
    ///   - data: The serialized message envelope to send.
    ///   - endpoint: The destination endpoint (ignored for local transport).
    ///
    /// ## Implementation Notes
    ///
    /// Unlike network transports, this doesn't actually "send" anything over a wire.
    /// Instead, it:
    /// 1. Creates a TransportMessage from the provided data
    /// 2. Sets up a response handler that routes responses back through the stream
    /// 3. Yields it to the AsyncStream that message handlers consume from
    ///
    /// This bypasses all network I/O and provides direct in-memory routing.
    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        // Create a message with a response handler that routes back through our stream
        let message = TransportMessage(
            data: data,
            source: endpoint,
            respond: { [weak self] responseData in
                Task {
                    guard let self = self else { return }
                    let responseMessage = TransportMessage(
                        data: responseData,
                        source: nil,
                        respond: { _ in } // No response to responses
                    )
                    await self.deliver(responseMessage)
                }
            }
        )

        continuation?.yield(message)
    }

    /// Starts listening for incoming connections on the specified endpoint.
    ///
    /// For local transport, this is a no-op since there are no network ports
    /// to bind or connections to accept. The transport is always ready to
    /// route messages through the incoming stream.
    ///
    /// - Parameter endpoint: The endpoint to listen on (ignored for local transport).
    public func listen(on endpoint: Endpoint) async throws {
        // No-op: local transport doesn't bind to ports
    }

    /// Shuts down the transport.
    ///
    /// This finishes the message stream continuation, signaling that no more
    /// messages will be delivered. Any pending messages in the stream will still
    /// be processed by consumers.
    ///
    /// After shutdown, the transport cannot be reused. Create a new instance
    /// if you need to restart communication.
    public func shutdown() async {
        continuation?.finish()
        continuation = nil
    }

    /// Writes a message directly to the incoming stream.
    ///
    /// This is an internal API used for delivering messages without going through
    /// the send path. It bypasses serialization and routes the message directly
    /// through the continuation.
    ///
    /// - Parameter message: The transport message to deliver.
    ///
    /// ## Thread Safety
    ///
    /// This method is actor-isolated, ensuring thread-safe access to the continuation.
    internal func deliver(_ message: TransportMessage) async {
        continuation?.yield(message)
    }
}
