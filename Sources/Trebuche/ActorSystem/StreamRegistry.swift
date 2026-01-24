import Distributed
import Foundation

/// Manages active streams and their continuations
public actor StreamRegistry {
    /// State for an active stream
    private struct StreamState {
        var continuation: AsyncStream<Data>.Continuation?
        var sequenceNumber: UInt64
        let decoder: JSONDecoder
        let streamID: UUID
        let callID: UUID
        var recentData: [(sequence: UInt64, data: Data)] = []
        var pendingData: [(sequence: UInt64, data: Data)] = []

        init(streamID: UUID, callID: UUID) {
            self.continuation = nil
            self.sequenceNumber = 0
            self.decoder = JSONDecoder()
            self.decoder.dateDecodingStrategy = .iso8601
            self.streamID = streamID
            self.callID = callID
        }

        mutating func buffer(_ data: Data, sequence: UInt64, maxBufferSize: Int) {
            recentData.append((sequence, data))
            // Keep only recent items
            if recentData.count > maxBufferSize {
                recentData.removeFirst()
            }
        }
    }

    private var streams: [UUID: StreamState] = [:]
    private var callIDToStreamID: [UUID: UUID] = [:]

    /// Maximum number of recent data items to buffer for catch-up
    private let maxBufferSize: Int

    public init(maxBufferSize: Int = 100) {
        self.maxBufferSize = maxBufferSize
    }

    /// Create a new remote stream for receiving data
    public func createRemoteStream(callID: UUID) -> (streamID: UUID, stream: AsyncStream<Data>) {
        let streamID = UUID()

        // Pre-register the stream before creating the AsyncStream
        // This prevents race conditions where data arrives before registration
        let state = StreamState(streamID: streamID, callID: callID)
        streams[streamID] = state
        callIDToStreamID[callID] = streamID

        let stream = AsyncStream<Data> { continuation in
            Task {
                await self.registerContinuation(continuation, streamID: streamID)

                continuation.onTermination = { @Sendable [weak self] _ in
                    Task {
                        await self?.removeStream(streamID: streamID)
                    }
                }
            }
        }

        return (streamID, stream)
    }

    private func registerContinuation(_ continuation: AsyncStream<Data>.Continuation, streamID: UUID) {
        guard var state = streams[streamID] else {
            // Stream was removed before continuation was registered
            continuation.finish()
            return
        }

        state.continuation = continuation

        // Flush any pending data that arrived before the continuation was ready
        for (_, data) in state.pendingData {
            continuation.yield(data)
        }
        state.pendingData.removeAll()

        streams[streamID] = state
    }

    /// Handle a StreamStartEnvelope from the server
    public func handleStreamStart(_ envelope: StreamStartEnvelope) {
        // The server sends its own streamID, but we pre-registered with a client-generated streamID
        // We need to remap from our streamID to the server's streamID

        guard let clientStreamID = callIDToStreamID[envelope.callID] else {
            return
        }

        guard let state = streams.removeValue(forKey: clientStreamID) else {
            return
        }

        // Re-register under the server's streamID
        streams[envelope.streamID] = state
        callIDToStreamID[envelope.callID] = envelope.streamID
    }

    /// Handle a StreamDataEnvelope and yield to the appropriate stream
    public func handleStreamData(_ envelope: StreamDataEnvelope) {
        guard var state = streams[envelope.streamID] else {
            // Stream not found, possibly already terminated
            return
        }

        // Check sequence number to prevent duplicates/out-of-order delivery
        guard envelope.sequenceNumber > state.sequenceNumber else {
            // Duplicate or out-of-order message, ignore
            return
        }

        state.sequenceNumber = envelope.sequenceNumber

        // Buffer for potential resumption
        state.buffer(envelope.data, sequence: envelope.sequenceNumber, maxBufferSize: maxBufferSize)

        // If continuation is ready, yield immediately
        if let continuation = state.continuation {
            continuation.yield(envelope.data)
        } else {
            // Continuation not ready yet, buffer the data
            state.pendingData.append((envelope.sequenceNumber, envelope.data))
        }

        streams[envelope.streamID] = state
    }

    /// Handle a StreamEndEnvelope and finish the stream
    public func handleStreamEnd(_ envelope: StreamEndEnvelope) {
        guard let state = streams[envelope.streamID] else {
            return
        }

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
}
