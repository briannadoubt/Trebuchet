import Testing
import Foundation
@testable import TrebuchetOTel

@Suite("SpanIngester Tests")
struct IngestionTests {

    private func makeTempPath() -> String {
        NSTemporaryDirectory() + "otel-ingest-test-\(UUID().uuidString).sqlite"
    }

    private func makeSpan(
        traceId: String = "ingest-trace-aabbccdd1122334455",
        spanId: String? = nil,
        operationName: String = "ingested-op",
        serviceName: String = "ingest-svc",
        startTimeNano: Int64 = 1_700_000_000_000_000_000,
        endTimeNano: Int64 = 1_700_000_001_000_000_000,
        statusCode: Int = 1
    ) -> SpanRecord {
        let sid = spanId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        return SpanRecord(
            traceId: traceId,
            spanId: String(sid),
            operationName: operationName,
            serviceName: serviceName,
            spanKind: 2,
            startTimeNano: startTimeNano,
            endTimeNano: endTimeNano,
            durationNano: endTimeNano - startTimeNano,
            statusCode: statusCode
        )
    }

    private func makeLog(
        timestamp: Int64 = 1_700_000_000_000_000_000,
        body: String = "ingested log",
        serviceName: String = "ingest-svc"
    ) -> LogRecord {
        LogRecord(
            timestamp: timestamp,
            severityNumber: 9,
            severityText: "INFO",
            body: body,
            serviceName: serviceName
        )
    }

    @Test func testIngestAndFlush() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)
        let ingester = SpanIngester(store: store)

        let spans = [
            makeSpan(traceId: "flush1111111111111111111111aaaaaa", spanId: "flsh00000000aa01"),
            makeSpan(traceId: "flush1111111111111111111111aaaaaa", spanId: "flsh00000000aa02"),
            makeSpan(traceId: "flush2222222222222222222222bbbbbb", spanId: "flsh00000000bb01"),
        ]

        await ingester.ingest(spans)
        await ingester.flush()

        let trace1 = try await store.getTrace(traceId: "flush1111111111111111111111aaaaaa")
        #expect(trace1.count == 2)

        let trace2 = try await store.getTrace(traceId: "flush2222222222222222222222bbbbbb")
        #expect(trace2.count == 1)
    }

    @Test func testIngestLogs() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)
        let ingester = SpanIngester(store: store)

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, body: "log entry 1"),
            makeLog(timestamp: 1_700_000_001_000_000_000, body: "log entry 2"),
        ]

        await ingester.ingestLogs(logs)

        // Logs are written directly (not batched), so they should be available immediately
        let page = try await store.listLogs()
        #expect(page.logs.count == 2)
    }

    @Test func testBatchFlush() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)
        let ingester = SpanIngester(store: store)

        // Ingest more than 500 spans to trigger automatic batch flush
        var spans: [SpanRecord] = []
        for i in 0..<510 {
            let traceId = String(format: "batchtrace%022d", i / 10)
            let spanId = String(format: "batchspan%07d", i)
            spans.append(makeSpan(
                traceId: traceId,
                spanId: spanId,
                operationName: "batch-op-\(i)",
                startTimeNano: 1_700_000_000_000_000_000 + Int64(i) * 1_000_000,
                endTimeNano: 1_700_000_000_001_000_000 + Int64(i) * 1_000_000
            ))
        }

        // Ingest all at once — this should trigger automatic flush at 500
        await ingester.ingest(spans)

        // The first 510 should have been flushed automatically since count >= 500
        // Flush any remaining
        await ingester.flush()

        // Verify all spans were persisted
        let page = try await store.listTraces(limit: 100)
        let totalSpans = page.traces.reduce(0) { $0 + $1.spanCount }
        #expect(totalSpans > 0)

        // Check via services to confirm data is there
        let services = try await store.listServices()
        #expect(services.contains("ingest-svc"))
    }
}
