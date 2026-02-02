import Distributed
import Foundation

/// Manages active streams and their continuations
public actor StreamRegistry {
    /// Debug logging helper (automatically enabled in DEBUG builds)
    private static func debugLog(_ message: String, metadata: [String: String] = [:]) {
        #if DEBUG
        var output = "[StreamRegistry] \(message)"
        if !metadata.isEmpty {
            let metadataStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            output += " | \(metadataStr)"
        }
        fputs(output + "\n", stderr)
        fflush(stderr)
        #endif
    }

    /// State for an active stream
    private class StreamState {
        var continuation: AsyncStream<Data>.Continuation?
        var sequenceNumber: UInt64
        let decoder: JSONDecoder
        let streamID: UUID
        let callID: UUID
        var recentData: [(sequence: UInt64, data: Data)] = []
        var pendingData: [(sequence: UInt64, data: Data)] = []
        var lastActivity: Date

        init(streamID: UUID, callID: UUID) {
            self.continuation = nil
            self.sequenceNumber = 0
            self.decoder = JSONDecoder()
            self.decoder.dateDecodingStrategy = .iso8601
            self.streamID = streamID
            self.callID = callID
            self.lastActivity = Date()
        }

        func buffer(_ data: Data, sequence: UInt64, maxBufferSize: Int) {
            recentData.append((sequence, data))
            // Keep only recent items
            if recentData.count > maxBufferSize {
                recentData.removeFirst()
            }
        }

        func updateActivity() {
            lastActivity = Date()
        }
    }

    private var streams: [UUID: StreamState] = [:]
    private var callIDToStreamID: [UUID: UUID] = [:]

    /// Maximum number of recent data items to buffer for catch-up
    private let maxBufferSize: Int

    /// Time-to-live for inactive streams (in seconds)
    private let streamTTL: TimeInterval

    /// Cleanup task handle
    private var cleanupTask: Task<Void, Never>?

    /// Whether cleanup task has been started
    private var cleanupStarted = false

    public init(maxBufferSize: Int = 100, streamTTL: TimeInterval = 300) {
        self.maxBufferSize = maxBufferSize
        self.streamTTL = streamTTL
    }

    deinit {
        cleanupTask?.cancel()
    }

    /// Start the periodic cleanup task (called automatically on first stream creation)
    private func startCleanupTaskIfNeeded() {
        guard !cleanupStarted else { return }
        cleanupStarted = true

        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.cleanupStaleStreams()
            }
        }
    }

    /// Create a new remote stream for receiving data
    public func createRemoteStream(callID: UUID) -> (streamID: UUID, stream: AsyncStream<Data>) {
        // Start cleanup task on first stream creation
        startCleanupTaskIfNeeded()

        let streamID = UUID()

        Self.debugLog("Creating remote stream", metadata: [
            "streamID": streamID.uuidString,
            "callID": callID.uuidString
        ])

        // Pre-register the stream before creating the AsyncStream
        // This prevents race conditions where data arrives before registration
        let state = StreamState(streamID: streamID, callID: callID)
        streams[streamID] = state
        callIDToStreamID[callID] = streamID

        let stream = AsyncStream<Data> { continuation in
            Self.debugLog("Registering continuation for stream", metadata: ["streamID": streamID.uuidString])

            // CRITICAL: Register continuation SYNCHRONOUSLY
            // We can't call the async registerContinuation method here because we're in the StreamContinuation closure
            // Instead, we need to register directly

            // Update activity timestamp
            state.updateActivity()

            // Set continuation IMMEDIATELY (synchronous)
            state.continuation = continuation

            // No pending data at this point since this is a new stream

            continuation.onTermination = { @Sendable [weak self] _ in
                Self.debugLog("Stream terminated", metadata: ["streamID": streamID.uuidString])
                Task {
                    await self?.removeStream(streamID: streamID)
                }
            }
        }

        return (streamID, stream)
    }

    /// Create a resumed stream using a specific streamID from a checkpoint
    ///
    /// This is used when resuming a stream after reconnection. The streamID
    /// should match the one in the checkpoint so the server's replayed data
    /// can be routed correctly.
    public func createResumedStream(streamID: UUID, callID: UUID) -> AsyncStream<Data> {
        // Start cleanup task on first stream creation
        startCleanupTaskIfNeeded()

        // Pre-register the stream with the checkpoint's streamID
        let state = StreamState(streamID: streamID, callID: callID)
        streams[streamID] = state
        callIDToStreamID[callID] = streamID

        let stream = AsyncStream<Data> { continuation in
            // CRITICAL: Register continuation SYNCHRONOUSLY
            // Update activity timestamp
            state.updateActivity()

            // Set continuation IMMEDIATELY (synchronous)
            state.continuation = continuation

            // Flush any pending data that arrived before the continuation was ready
            let pendingData = state.pendingData
            for (_, data) in pendingData {
                continuation.yield(data)
            }
            state.pendingData.removeAll()

            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeStream(streamID: streamID)
                }
            }
        }

        return stream
    }

    private func registerContinuation(_ continuation: AsyncStream<Data>.Continuation, streamID: UUID) {
        guard streams[streamID] != nil else {
            // Stream was removed before continuation was registered
            continuation.finish()
            return
        }

        // Update activity timestamp
        streams[streamID]?.updateActivity()

        // Set continuation
        streams[streamID]?.continuation = continuation

        // Flush any pending data that arrived before the continuation was ready
        let pendingData = streams[streamID]?.pendingData ?? []
        for (_, data) in pendingData {
            continuation.yield(data)
        }
        streams[streamID]?.pendingData.removeAll()
    }

    /// Handle a StreamStartEnvelope from the server
    public func handleStreamStart(_ envelope: StreamStartEnvelope) {
        Self.debugLog("Received StreamStart", metadata: [
            "callID": envelope.callID.uuidString,
            "serverStreamID": envelope.streamID.uuidString
        ])

        // The server sends its own streamID, but we pre-registered with a client-generated streamID
        // We need to create an alias from the server's streamID to our existing stream state

        guard let clientStreamID = callIDToStreamID[envelope.callID] else {
            Self.debugLog("No client stream found for callID", metadata: ["callID": envelope.callID.uuidString])
            return
        }

        Self.debugLog("Creating stream alias", metadata: [
            "serverStreamID": envelope.streamID.uuidString,
            "clientStreamID": clientStreamID.uuidString
        ])

        guard let state = streams[clientStreamID] else {
            Self.debugLog("No stream state found for client stream ID", metadata: ["clientStreamID": clientStreamID.uuidString])
            return
        }

        // Add an alias under the server's streamID (don't remove the client entry!)
        // Both IDs now point to the same stream state
        streams[envelope.streamID] = state
        // Keep the mapping for future data that will use the server's streamID
        callIDToStreamID[envelope.callID] = envelope.streamID
        Self.debugLog("Stream aliased successfully", metadata: ["streamID": envelope.streamID.uuidString])
    }

    /// Handle a StreamDataEnvelope and yield to the appropriate stream
    public func handleStreamData(_ envelope: StreamDataEnvelope) {
        Self.debugLog("Received StreamData", metadata: [
            "streamID": envelope.streamID.uuidString,
            "sequence": String(envelope.sequenceNumber)
        ])

        guard streams[envelope.streamID] != nil else {
            // Stream not found, possibly already terminated
            Self.debugLog("Stream not found for data envelope", metadata: ["streamID": envelope.streamID.uuidString])
            return
        }

        // Check sequence number to prevent duplicates/out-of-order delivery
        if let currentSeq = streams[envelope.streamID]?.sequenceNumber,
           envelope.sequenceNumber <= currentSeq {
            // Duplicate or out-of-order message, ignore
            Self.debugLog("Ignoring duplicate or out-of-order data", metadata: [
                "streamID": envelope.streamID.uuidString,
                "received": String(envelope.sequenceNumber),
                "current": String(currentSeq)
            ])
            return
        }

        // Update activity timestamp
        streams[envelope.streamID]?.updateActivity()

        // Update sequence number (in-place mutation to avoid copy-on-write issues)
        streams[envelope.streamID]?.sequenceNumber = envelope.sequenceNumber

        // Buffer for potential resumption
        streams[envelope.streamID]?.buffer(envelope.data, sequence: envelope.sequenceNumber, maxBufferSize: maxBufferSize)

        // If continuation is ready, yield immediately
        if let continuation = streams[envelope.streamID]?.continuation {
            Self.debugLog("Yielding data to continuation", metadata: ["streamID": envelope.streamID.uuidString])
            continuation.yield(envelope.data)
        } else {
            // Continuation not ready yet, buffer the data
            Self.debugLog("Buffering data (continuation not ready)", metadata: ["streamID": envelope.streamID.uuidString])
            streams[envelope.streamID]?.pendingData.append((envelope.sequenceNumber, envelope.data))
        }
    }

    /// Handle a StreamEndEnvelope and finish the stream
    public func handleStreamEnd(_ envelope: StreamEndEnvelope) {
        Self.debugLog("Received StreamEnd", metadata: [
            "streamID": envelope.streamID.uuidString,
            "reason": String(describing: envelope.reason)
        ])

        guard let state = streams[envelope.streamID] else {
            Self.debugLog("No stream found for StreamEnd", metadata: ["streamID": envelope.streamID.uuidString])
            return
        }

        Self.debugLog("Finishing stream continuation", metadata: ["streamID": envelope.streamID.uuidString])
        state.continuation?.finish()
        removeStreamInternal(streamID: envelope.streamID)
    }

    /// Handle a StreamErrorEnvelope and finish the stream with error
    public func handleStreamError(_ envelope: StreamErrorEnvelope) {
        guard let state = streams[envelope.streamID] else {
            return
        }

        // For now, just finish the stream. In the future, we could yield an error marker
        state.continuation?.finish()
        removeStreamInternal(streamID: envelope.streamID)
    }

    /// Remove a stream from the registry
    public func removeStream(streamID: UUID) {
        removeStreamInternal(streamID: streamID)
    }

    private func removeStreamInternal(streamID: UUID) {
        if let state = streams.removeValue(forKey: streamID) {
            callIDToStreamID.removeValue(forKey: state.callID)
        }
    }

    /// Get stream ID for a call ID
    public func streamID(for callID: UUID) -> UUID? {
        callIDToStreamID[callID]
    }

    /// Get the last sequence number for a stream
    public func getLastSequence(streamID: UUID) -> UInt64? {
        streams[streamID]?.sequenceNumber
    }

    /// Clean up stale streams that haven't had activity within TTL
    private func cleanupStaleStreams() {
        let now = Date()
        var staleStreamIDs: [UUID] = []

        for (streamID, state) in streams {
            if now.timeIntervalSince(state.lastActivity) > streamTTL {
                staleStreamIDs.append(streamID)
            }
        }

        for streamID in staleStreamIDs {
            if let state = streams[streamID] {
                state.continuation?.finish()
            }
            removeStreamInternal(streamID: streamID)
        }
    }

    /// Remove all streams (for cleanup)
    public func removeAllStreams() {
        for (_, state) in streams {
            state.continuation?.finish()
        }
        streams.removeAll()
        callIDToStreamID.removeAll()
    }

    /// Resume a stream from a checkpoint, replaying missed data if available
    public func resumeStream(streamID: UUID, lastSequence: UInt64) -> [(sequence: UInt64, data: Data)]? {
        guard let state = streams[streamID] else {
            return nil
        }

        // Find buffered data after the last sequence number
        let missedData = state.recentData.filter { $0.sequence > lastSequence }

        return missedData
    }

    /// Get buffered data for a stream (for manual catch-up)
    public func getBufferedData(streamID: UUID) -> [(sequence: UInt64, data: Data)]? {
        guard let state = streams[streamID] else {
            return nil
        }
        return state.recentData
    }

    /// Get the count of active streams
    public func activeStreamCount() -> Int {
        streams.count
    }
}
