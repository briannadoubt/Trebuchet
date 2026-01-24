import Foundation

/// Represents a checkpoint in a stream for resumption after reconnection
public struct StreamCheckpoint: Codable, Sendable, Equatable {
    /// The unique identifier for the stream
    public let streamID: UUID

    /// The last sequence number successfully received
    public let lastSequence: UInt64

    /// The actor ID being observed
    public let actorID: TrebuchetActorID

    /// The method being called (e.g., "observeState")
    public let targetIdentifier: String

    /// When this checkpoint was created
    public let timestamp: Date

    public init(
        streamID: UUID,
        lastSequence: UInt64,
        actorID: TrebuchetActorID,
        targetIdentifier: String,
        timestamp: Date = Date()
    ) {
        self.streamID = streamID
        self.lastSequence = lastSequence
        self.actorID = actorID
        self.targetIdentifier = targetIdentifier
        self.timestamp = timestamp
    }
}

/// Storage for stream checkpoints
public actor StreamCheckpointStorage {
    private var checkpoints: [UUID: StreamCheckpoint] = [:]

    /// Maximum age of checkpoints before they expire
    private let maxAge: TimeInterval

    public init(maxAge: TimeInterval = 300) { // 5 minutes default
        self.maxAge = maxAge
    }

    /// Save a checkpoint for later resumption
    public func save(_ checkpoint: StreamCheckpoint) {
        checkpoints[checkpoint.streamID] = checkpoint
    }

    /// Get a checkpoint if it exists and hasn't expired
    public func get(streamID: UUID) -> StreamCheckpoint? {
        guard let checkpoint = checkpoints[streamID] else {
            return nil
        }

        // Check if expired
        if Date().timeIntervalSince(checkpoint.timestamp) > maxAge {
            checkpoints.removeValue(forKey: streamID)
            return nil
        }

        return checkpoint
    }

    /// Remove a checkpoint (e.g., when stream completes normally)
    public func remove(streamID: UUID) {
        checkpoints.removeValue(forKey: streamID)
    }

    /// Get all active checkpoints (not expired)
    public func allActive() -> [StreamCheckpoint] {
        let now = Date()
        return checkpoints.values.filter { checkpoint in
            now.timeIntervalSince(checkpoint.timestamp) <= maxAge
        }
    }

    /// Clean up expired checkpoints
    public func cleanup() {
        let now = Date()
        let expiredIDs = checkpoints.filter { _, checkpoint in
            now.timeIntervalSince(checkpoint.timestamp) > maxAge
        }.map(\.key)

        for id in expiredIDs {
            checkpoints.removeValue(forKey: id)
        }
    }
}
