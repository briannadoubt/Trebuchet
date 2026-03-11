import Foundation

/// Periodically deletes telemetry data older than a configured retention period.
///
/// ``RetentionSweeper`` runs an hourly sweep loop that removes expired spans, logs, and
/// metrics from the backing ``SpanStore`` by calling ``SpanStore/deleteOlderThan(_:)``.
public actor RetentionSweeper {
    private let store: SpanStore
    private let maxAge: Duration

    /// Creates a new retention sweeper.
    ///
    /// - Parameters:
    ///   - store: The ``SpanStore`` to sweep expired data from.
    ///   - maxAge: The maximum age of telemetry data to retain.
    public init(store: SpanStore, maxAge: Duration) {
        self.store = store
        self.maxAge = maxAge
    }

    /// Starts the retention sweep loop.
    ///
    /// Runs indefinitely, sweeping once per hour until the enclosing task is cancelled.
    /// Each sweep deletes all records older than ``maxAge`` from the current time.
    public func start() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
            let cutoffNano = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
                - Int64(maxAge.components.seconds) * 1_000_000_000
            try? await store.deleteOlderThan(cutoffNano)
        }
    }
}
