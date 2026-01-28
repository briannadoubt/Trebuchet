import Foundation

// MARK: - Request Info

/// Information about an in-flight request
public struct RequestInfo: Sendable {
    /// Unique identifier for this request
    public let callID: UUID

    /// When the request started
    public let startTime: ContinuousClock.Instant

    /// The actor ID being called
    public let actorID: String

    /// The method being called
    public let method: String

    public init(callID: UUID, startTime: ContinuousClock.Instant, actorID: String, method: String) {
        self.callID = callID
        self.startTime = startTime
        self.actorID = actorID
        self.method = method
    }

    /// How long this request has been running
    public var duration: Duration {
        startTime.duration(to: .now)
    }
}

// MARK: - Inflight Request Tracker

/// Tracks in-flight requests for graceful shutdown
public actor InflightRequestTracker {
    /// All currently active requests
    private var requests: [UUID: RequestInfo] = [:]

    /// Tasks that should be cancelled on shutdown
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Begin tracking a request
    /// - Parameters:
    ///   - callID: Unique identifier for the request
    ///   - actorID: The actor being called
    ///   - method: The method being called
    public func begin(callID: UUID, actorID: String, method: String) {
        requests[callID] = RequestInfo(
            callID: callID,
            startTime: .now,
            actorID: actorID,
            method: method
        )
    }

    /// Mark a request as completed
    /// - Parameter callID: The request identifier
    public func complete(callID: UUID) {
        requests.removeValue(forKey: callID)
    }

    /// Get the number of in-flight requests
    /// - Returns: Count of active requests
    public func count() -> Int {
        requests.count
    }

    /// Get all pending requests
    /// - Returns: Array of request info for all active requests
    public func pendingRequests() -> [RequestInfo] {
        Array(requests.values)
    }

    /// Cancel all in-flight requests
    public func cancelAll() {
        requests.removeAll()

        // Cancel all background tasks
        for task in backgroundTasks.values {
            task.cancel()
        }
        backgroundTasks.removeAll()
    }

    /// Track a background task that should be cancelled on shutdown
    /// - Parameters:
    ///   - id: Unique identifier for the task
    ///   - task: The task to track
    public func trackBackgroundTask(id: UUID, task: Task<Void, Never>) {
        backgroundTasks[id] = task
    }

    /// Stop tracking a background task
    /// - Parameter id: The task identifier
    public func completeBackgroundTask(id: UUID) {
        backgroundTasks.removeValue(forKey: id)
    }

    /// Get statistics about in-flight requests
    /// - Returns: Statistics summary
    public func statistics() -> RequestStatistics {
        let now = ContinuousClock.now
        let durations = requests.values.map { req in
            req.startTime.duration(to: now)
        }

        return RequestStatistics(
            totalRequests: requests.count,
            averageDuration: durations.isEmpty ? .zero : durations.reduce(.zero, +) / durations.count,
            maxDuration: durations.max() ?? .zero,
            byActor: Dictionary(grouping: requests.values) { $0.actorID }
                .mapValues { $0.count }
        )
    }
}

// MARK: - Request Statistics

/// Statistics about in-flight requests
public struct RequestStatistics: Sendable {
    /// Total number of in-flight requests
    public let totalRequests: Int

    /// Average duration of active requests
    public let averageDuration: Duration

    /// Maximum duration of any active request
    public let maxDuration: Duration

    /// Number of requests per actor ID
    public let byActor: [String: Int]

    public init(
        totalRequests: Int,
        averageDuration: Duration,
        maxDuration: Duration,
        byActor: [String: Int]
    ) {
        self.totalRequests = totalRequests
        self.averageDuration = averageDuration
        self.maxDuration = maxDuration
        self.byActor = byActor
    }
}
