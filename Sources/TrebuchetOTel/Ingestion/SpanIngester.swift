import Foundation

/// Buffers incoming spans and flushes them to a ``SpanStore`` in batches.
///
/// ``SpanIngester`` accumulates spans in memory and writes them to the backing store either
/// when the batch reaches 500 spans or after a 1-second flush interval, whichever comes first.
/// Logs and metrics are forwarded to the store immediately without buffering.
public actor SpanIngester {
    private let store: SpanStore
    private var buffer: [SpanRecord] = []
    private let maxBatchSize = 500
    private let flushInterval: Duration = .seconds(1)
    private var flushTask: Task<Void, Never>?

    /// Creates a new span ingester backed by the given store.
    ///
    /// - Parameter store: The ``SpanStore`` to persist telemetry data into.
    public init(store: SpanStore) {
        self.store = store
    }

    /// Ingests a batch of spans into the buffer.
    ///
    /// Triggers an immediate flush if the buffer reaches the maximum batch size,
    /// otherwise starts a timer-based flush if one is not already scheduled.
    ///
    /// - Parameter spans: The span records to buffer for writing.
    public func ingest(_ spans: [SpanRecord]) async {
        buffer.append(contentsOf: spans)
        if buffer.count >= maxBatchSize {
            await flush()
        } else if flushTask == nil {
            startFlushTimer()
        }
    }

    /// Flushes all buffered spans to the backing ``SpanStore``.
    ///
    /// Cancels any pending flush timer and writes the current buffer contents.
    /// Errors are logged to stderr rather than thrown, to avoid losing subsequent data.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil

        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        do {
            try await store.insertSpans(batch)
        } catch {
            FileHandle.standardError.write(Data("[OTel] Failed to write spans: \(error)\n".utf8))
        }

        if !buffer.isEmpty {
            startFlushTimer()
        }
    }

    /// Writes log records directly to the backing ``SpanStore``.
    ///
    /// Unlike spans, logs are not buffered and are inserted immediately.
    ///
    /// - Parameter logs: The log records to persist.
    public func ingestLogs(_ logs: [LogRecord]) async {
        guard !logs.isEmpty else { return }
        do {
            try await store.insertLogs(logs)
        } catch {
            FileHandle.standardError.write(Data("[OTel] Failed to write logs: \(error)\n".utf8))
        }
    }

    /// Writes metric records directly to the backing ``SpanStore``.
    ///
    /// Unlike spans, metrics are not buffered and are inserted immediately.
    ///
    /// - Parameter metrics: The metric records to persist.
    public func ingestMetrics(_ metrics: [MetricRecord]) async {
        guard !metrics.isEmpty else { return }
        do {
            try await store.insertMetrics(metrics)
        } catch {
            FileHandle.standardError.write(Data("[OTel] Failed to write metrics: \(error)\n".utf8))
        }
    }

    private func startFlushTimer() {
        flushTask = Task { [weak self, flushInterval] in
            try? await Task.sleep(for: flushInterval)
            await self?.flush()
        }
    }
}
