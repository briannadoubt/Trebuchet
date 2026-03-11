import Foundation

public actor SpanIngester {
    private let store: SpanStore
    private var buffer: [SpanRecord] = []
    private let maxBatchSize = 500
    private let flushInterval: Duration = .seconds(1)
    private var flushTask: Task<Void, Never>?

    public init(store: SpanStore) {
        self.store = store
    }

    public func ingest(_ spans: [SpanRecord]) async {
        buffer.append(contentsOf: spans)
        if buffer.count >= maxBatchSize {
            await flush()
        } else if flushTask == nil {
            startFlushTimer()
        }
    }

    public func flush() async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil

        do {
            try await store.insertSpans(batch)
        } catch {
            FileHandle.standardError.write(Data("[OTel] Failed to write spans: \(error)\n".utf8))
        }
    }

    public func ingestLogs(_ logs: [LogRecord]) async {
        guard !logs.isEmpty else { return }
        do {
            try await store.insertLogs(logs)
        } catch {
            FileHandle.standardError.write(Data("[OTel] Failed to write logs: \(error)\n".utf8))
        }
    }

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
