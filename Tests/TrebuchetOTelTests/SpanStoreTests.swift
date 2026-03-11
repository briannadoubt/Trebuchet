import Testing
import Foundation
@testable import TrebuchetOTel

@Suite("SpanStore Tests")
struct SpanStoreTests {

    // MARK: - Helpers

    private func makeTempPath() -> String {
        NSTemporaryDirectory() + "otel-test-\(UUID().uuidString).sqlite"
    }

    private func makeSpan(
        traceId: String = "trace-aabbccdd11223344",
        spanId: String? = nil,
        parentSpanId: String? = nil,
        operationName: String = "test-op",
        serviceName: String = "test-svc",
        spanKind: Int = 2,
        startTimeNano: Int64 = 1_700_000_000_000_000_000,
        endTimeNano: Int64 = 1_700_000_001_000_000_000,
        statusCode: Int = 1
    ) -> SpanRecord {
        let sid = spanId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        let duration = endTimeNano - startTimeNano
        return SpanRecord(
            traceId: traceId,
            spanId: String(sid),
            parentSpanId: parentSpanId,
            operationName: operationName,
            serviceName: serviceName,
            spanKind: spanKind,
            startTimeNano: startTimeNano,
            endTimeNano: endTimeNano,
            durationNano: duration,
            statusCode: statusCode
        )
    }

    private func makeLog(
        timestamp: Int64 = 1_700_000_000_000_000_000,
        traceId: String? = nil,
        spanId: String? = nil,
        severityNumber: Int = 9,
        severityText: String = "INFO",
        body: String = "test log message",
        serviceName: String = "test-svc"
    ) -> LogRecord {
        LogRecord(
            timestamp: timestamp,
            traceId: traceId,
            spanId: spanId,
            severityNumber: severityNumber,
            severityText: severityText,
            body: body,
            serviceName: serviceName
        )
    }

    // MARK: - Span Tests

    @Test func testInsertAndRetrieveSpans() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)
        let traceId = "aabbccdd11223344aabbccdd11223344"

        let spans = [
            makeSpan(traceId: traceId, spanId: "span000000000001", operationName: "root", startTimeNano: 1_700_000_000_000_000_000, endTimeNano: 1_700_000_003_000_000_000),
            makeSpan(traceId: traceId, spanId: "span000000000002", parentSpanId: "span000000000001", operationName: "child-1", startTimeNano: 1_700_000_000_500_000_000, endTimeNano: 1_700_000_001_500_000_000),
            makeSpan(traceId: traceId, spanId: "span000000000003", parentSpanId: "span000000000001", operationName: "child-2", startTimeNano: 1_700_000_001_000_000_000, endTimeNano: 1_700_000_002_000_000_000),
        ]
        try await store.insertSpans(spans)

        let retrieved = try await store.getTrace(traceId: traceId)
        #expect(retrieved.count == 3)
        // Should be ordered by startTimeNano ascending
        #expect(retrieved[0].operationName == "root")
        #expect(retrieved[1].operationName == "child-1")
        #expect(retrieved[2].operationName == "child-2")
    }

    @Test func testListTraces() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        // 3 traces with different characteristics
        let spans = [
            // Trace 1: 2 spans, 1 error
            makeSpan(traceId: "trace111111111111trace111111111111", spanId: "span1aaaaaaa00001", operationName: "handle-request", startTimeNano: 1_700_000_000_000_000_000, endTimeNano: 1_700_000_002_000_000_000, statusCode: 1),
            makeSpan(traceId: "trace111111111111trace111111111111", spanId: "span1aaaaaaa00002", parentSpanId: "span1aaaaaaa00001", operationName: "db-query", startTimeNano: 1_700_000_000_500_000_000, endTimeNano: 1_700_000_001_500_000_000, statusCode: 2),
            // Trace 2: 1 span, no errors
            makeSpan(traceId: "trace222222222222trace222222222222", spanId: "span2aaaaaaa00001", operationName: "healthcheck", startTimeNano: 1_700_000_003_000_000_000, endTimeNano: 1_700_000_003_100_000_000, statusCode: 1),
            // Trace 3: 1 span
            makeSpan(traceId: "trace333333333333trace333333333333", spanId: "span3aaaaaaa00001", operationName: "process-event", startTimeNano: 1_700_000_005_000_000_000, endTimeNano: 1_700_000_006_000_000_000, statusCode: 1),
        ]
        try await store.insertSpans(spans)

        let page = try await store.listTraces()
        #expect(page.traces.count == 3)

        // Ordered by startTimeNano descending, so trace3 first
        #expect(page.traces[0].traceId == "trace333333333333trace333333333333")
        #expect(page.traces[0].rootOperation == "process-event")
        #expect(page.traces[0].spanCount == 1)
        #expect(page.traces[0].errorCount == 0)

        // Trace 1 has 2 spans and 1 error
        let trace1 = page.traces.first(where: { $0.traceId == "trace111111111111trace111111111111" })!
        #expect(trace1.spanCount == 2)
        #expect(trace1.errorCount == 1)
        #expect(trace1.rootOperation == "handle-request")
    }

    @Test func testListTracesServiceFilter() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let spans = [
            makeSpan(traceId: "svcfilter1111111111111111aaaaaaaa", spanId: "span00000000aa01", serviceName: "alpha-svc", startTimeNano: 1_700_000_000_000_000_000, endTimeNano: 1_700_000_001_000_000_000),
            makeSpan(traceId: "svcfilter2222222222222222bbbbbbbb", spanId: "span00000000bb01", serviceName: "beta-svc", startTimeNano: 1_700_000_002_000_000_000, endTimeNano: 1_700_000_003_000_000_000),
            makeSpan(traceId: "svcfilter3333333333333333cccccccc", spanId: "span00000000cc01", serviceName: "alpha-svc", startTimeNano: 1_700_000_004_000_000_000, endTimeNano: 1_700_000_005_000_000_000),
        ]
        try await store.insertSpans(spans)

        let page = try await store.listTraces(service: "alpha-svc")
        #expect(page.traces.count == 2)
        #expect(page.traces.allSatisfy { $0.serviceName == "alpha-svc" })
    }

    @Test func testListTracesStatusFilter() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let spans = [
            makeSpan(traceId: "statusfilt111111111111111111aaaaaa", spanId: "span000000sf0001", startTimeNano: 1_700_000_000_000_000_000, endTimeNano: 1_700_000_001_000_000_000, statusCode: 1),
            makeSpan(traceId: "statusfilt222222222222222222bbbbbb", spanId: "span000000sf0002", startTimeNano: 1_700_000_002_000_000_000, endTimeNano: 1_700_000_003_000_000_000, statusCode: 2),
            makeSpan(traceId: "statusfilt333333333333333333cccccc", spanId: "span000000sf0003", startTimeNano: 1_700_000_004_000_000_000, endTimeNano: 1_700_000_005_000_000_000, statusCode: 2),
        ]
        try await store.insertSpans(spans)

        let page = try await store.listTraces(status: 2)
        #expect(page.traces.count == 2)
    }

    @Test func testListTracesPagination() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        // Insert 10 traces
        var spans: [SpanRecord] = []
        for i in 0..<10 {
            let traceId = String(format: "pagetrace%022d", i)
            let spanId = String(format: "pagespan%08d", i)
            spans.append(makeSpan(
                traceId: traceId,
                spanId: spanId,
                operationName: "op-\(i)",
                startTimeNano: 1_700_000_000_000_000_000 + Int64(i) * 1_000_000_000,
                endTimeNano: 1_700_000_000_500_000_000 + Int64(i) * 1_000_000_000
            ))
        }
        try await store.insertSpans(spans)

        // First page
        let page1 = try await store.listTraces(limit: 3)
        #expect(page1.traces.count == 3)
        #expect(page1.nextCursor != nil)

        // Second page using cursor
        let page2 = try await store.listTraces(limit: 3, cursor: page1.nextCursor)
        #expect(page2.traces.count == 3)
        // Pages should not overlap
        let page1Ids = Set(page1.traces.map(\.traceId))
        let page2Ids = Set(page2.traces.map(\.traceId))
        #expect(page1Ids.isDisjoint(with: page2Ids))
    }

    @Test func testSearchSpans() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let spans = [
            makeSpan(traceId: "search11111111111111111111aaaaaa", spanId: "srch00000000aa01", operationName: "user-login", startTimeNano: 1_700_000_000_000_000_000, endTimeNano: 1_700_000_001_000_000_000),
            makeSpan(traceId: "search22222222222222222222bbbbbb", spanId: "srch00000000bb01", operationName: "user-logout", startTimeNano: 1_700_000_002_000_000_000, endTimeNano: 1_700_000_003_000_000_000),
            makeSpan(traceId: "search33333333333333333333cccccc", spanId: "srch00000000cc01", operationName: "process-payment", startTimeNano: 1_700_000_004_000_000_000, endTimeNano: 1_700_000_005_000_000_000),
        ]
        try await store.insertSpans(spans)

        let results = try await store.searchSpans(query: "user")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.operationName.contains("user") })
    }

    @Test func testGetStats() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let baseTime: Int64 = 1_700_000_000_000_000_000
        let spans = [
            makeSpan(traceId: "stats1111111111111111111111aaaaaa", spanId: "stat00000000aa01", startTimeNano: baseTime, endTimeNano: baseTime + 100_000_000, statusCode: 1),         // 100ms
            makeSpan(traceId: "stats2222222222222222222222bbbbbb", spanId: "stat00000000bb01", startTimeNano: baseTime + 1_000_000_000, endTimeNano: baseTime + 1_200_000_000, statusCode: 1),  // 200ms
            makeSpan(traceId: "stats3333333333333333333333cccccc", spanId: "stat00000000cc01", startTimeNano: baseTime + 2_000_000_000, endTimeNano: baseTime + 2_500_000_000, statusCode: 2),  // 500ms, error
            makeSpan(traceId: "stats4444444444444444444444dddddd", spanId: "stat00000000dd01", startTimeNano: baseTime + 3_000_000_000, endTimeNano: baseTime + 4_000_000_000, statusCode: 1),  // 1000ms
        ]
        try await store.insertSpans(spans)

        let stats = try await store.getStats(since: baseTime - 1)
        #expect(stats.totalCount == 4)
        #expect(stats.errorCount == 1)
        #expect(stats.p50DurationNano > 0)
        #expect(stats.p95DurationNano >= stats.p50DurationNano)
    }

    @Test func testListServices() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let spans = [
            makeSpan(traceId: "svc11111111111111111111111aaaaaa", spanId: "svcs00000000aa01", serviceName: "gamma-svc"),
            makeSpan(traceId: "svc22222222222222222222222bbbbbb", spanId: "svcs00000000bb01", serviceName: "alpha-svc"),
            makeSpan(traceId: "svc33333333333333333333333cccccc", spanId: "svcs00000000cc01", serviceName: "beta-svc"),
            makeSpan(traceId: "svc44444444444444444444444dddddd", spanId: "svcs00000000dd01", serviceName: "alpha-svc"),
        ]
        try await store.insertSpans(spans)

        let services = try await store.listServices()
        #expect(services == ["alpha-svc", "beta-svc", "gamma-svc"])
    }

    @Test func testDeleteOlderThan() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let cutoff: Int64 = 1_700_000_005_000_000_000
        let spans = [
            makeSpan(traceId: "del11111111111111111111111aaaaaa", spanId: "del000000000aa01", startTimeNano: 1_700_000_001_000_000_000, endTimeNano: 1_700_000_002_000_000_000), // old
            makeSpan(traceId: "del22222222222222222222222bbbbbb", spanId: "del000000000bb01", startTimeNano: 1_700_000_003_000_000_000, endTimeNano: 1_700_000_004_000_000_000), // old
            makeSpan(traceId: "del33333333333333333333333cccccc", spanId: "del000000000cc01", startTimeNano: 1_700_000_006_000_000_000, endTimeNano: 1_700_000_007_000_000_000), // recent
            makeSpan(traceId: "del44444444444444444444444dddddd", spanId: "del000000000dd01", startTimeNano: 1_700_000_008_000_000_000, endTimeNano: 1_700_000_009_000_000_000), // recent
        ]
        try await store.insertSpans(spans)

        try await store.deleteOlderThan(cutoff)

        let page = try await store.listTraces()
        #expect(page.traces.count == 2)
    }

    // MARK: - Log Tests

    @Test func testInsertAndRetrieveLogs() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, body: "First log"),
            makeLog(timestamp: 1_700_000_001_000_000_000, body: "Second log"),
            makeLog(timestamp: 1_700_000_002_000_000_000, body: "Third log"),
        ]
        try await store.insertLogs(logs)

        let page = try await store.listLogs()
        #expect(page.logs.count == 3)
    }

    @Test func testListLogsServiceFilter() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, body: "alpha log", serviceName: "alpha-svc"),
            makeLog(timestamp: 1_700_000_001_000_000_000, body: "beta log", serviceName: "beta-svc"),
            makeLog(timestamp: 1_700_000_002_000_000_000, body: "alpha log 2", serviceName: "alpha-svc"),
        ]
        try await store.insertLogs(logs)

        let page = try await store.listLogs(service: "alpha-svc")
        #expect(page.logs.count == 2)
        #expect(page.logs.allSatisfy { $0.serviceName == "alpha-svc" })
    }

    @Test func testListLogsSeverityFilter() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, severityNumber: 5, severityText: "DEBUG", body: "debug msg"),
            makeLog(timestamp: 1_700_000_001_000_000_000, severityNumber: 9, severityText: "INFO", body: "info msg"),
            makeLog(timestamp: 1_700_000_002_000_000_000, severityNumber: 17, severityText: "ERROR", body: "error msg"),
            makeLog(timestamp: 1_700_000_003_000_000_000, severityNumber: 13, severityText: "WARN", body: "warn msg"),
        ]
        try await store.insertLogs(logs)

        // Filter for WARN and above (>= 13)
        let page = try await store.listLogs(minSeverity: 13)
        #expect(page.logs.count == 2)
        #expect(page.logs.allSatisfy { $0.severityNumber >= 13 })
    }

    @Test func testListLogsSearchFilter() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, body: "Connection established to database"),
            makeLog(timestamp: 1_700_000_001_000_000_000, body: "User authenticated successfully"),
            makeLog(timestamp: 1_700_000_002_000_000_000, body: "Connection timeout on database"),
        ]
        try await store.insertLogs(logs)

        let page = try await store.listLogs(search: "Connection")
        #expect(page.logs.count == 2)
        #expect(page.logs.allSatisfy { $0.body.contains("Connection") })
    }

    @Test func testGetLogsForTrace() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)
        let targetTraceId = "logtrace1111111111111111aaaaaaaa"

        let logs = [
            makeLog(timestamp: 1_700_000_000_000_000_000, traceId: targetTraceId, body: "trace log 1"),
            makeLog(timestamp: 1_700_000_001_000_000_000, traceId: targetTraceId, body: "trace log 2"),
            makeLog(timestamp: 1_700_000_002_000_000_000, traceId: "othertracebbbbbbbbbbbbbbbbbbbbbbbb", body: "other trace log"),
            makeLog(timestamp: 1_700_000_003_000_000_000, body: "no trace log"),
        ]
        try await store.insertLogs(logs)

        let traceLogs = try await store.getLogsForTrace(traceId: targetTraceId)
        #expect(traceLogs.count == 2)
        #expect(traceLogs.allSatisfy { $0.traceId == targetTraceId })
        // Should be ordered by timestamp ascending
        #expect(traceLogs[0].body == "trace log 1")
        #expect(traceLogs[1].body == "trace log 2")
    }

    @Test func testDeleteAlsoRemovesLogs() async throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SpanStore(path: path)

        let cutoff: Int64 = 1_700_000_005_000_000_000

        // Insert spans and logs at various timestamps
        let spans = [
            makeSpan(traceId: "dellog111111111111111111111aaaaa", spanId: "dlsp0000000aa001", startTimeNano: 1_700_000_001_000_000_000, endTimeNano: 1_700_000_002_000_000_000),
            makeSpan(traceId: "dellog222222222222222222222bbbbb", spanId: "dlsp0000000bb001", startTimeNano: 1_700_000_008_000_000_000, endTimeNano: 1_700_000_009_000_000_000),
        ]
        let logs = [
            makeLog(timestamp: 1_700_000_001_000_000_000, body: "old log"),
            makeLog(timestamp: 1_700_000_008_000_000_000, body: "recent log"),
        ]

        try await store.insertSpans(spans)
        try await store.insertLogs(logs)

        try await store.deleteOlderThan(cutoff)

        let logPage = try await store.listLogs()
        #expect(logPage.logs.count == 1)
        #expect(logPage.logs[0].body == "recent log")

        let tracePage = try await store.listTraces()
        #expect(tracePage.traces.count == 1)
    }
}
