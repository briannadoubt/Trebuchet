import Testing
import Foundation
@testable import TrebuchetOTel

@Suite("Metrics")
struct MetricsTests {

    // MARK: - Decoder Tests

    @Test func testDecodeGaugeMetric() throws {
        let json = """
        {
          "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test-svc"}}]},
            "scopeMetrics": [{
              "metrics": [{
                "name": "cpu.usage",
                "gauge": {
                  "dataPoints": [{
                    "timeUnixNano": "1700000000000000000",
                    "asDouble": 0.75,
                    "attributes": [{"key": "host", "value": {"stringValue": "server-1"}}]
                  }]
                }
              }]
            }]
          }]
        }
        """
        let records = try OTLPDecoder.decodeMetrics(from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records[0].name == "cpu.usage")
        #expect(records[0].metricType == "gauge")
        #expect(records[0].serviceName == "test-svc")
        #expect(records[0].timestamp == 1700000000000000000)
        #expect(records[0].attributes?.contains("server-1") == true)
    }

    @Test func testDecodeSumMetric() throws {
        let json = """
        {
          "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test-svc"}}]},
            "scopeMetrics": [{
              "metrics": [{
                "name": "requests.total",
                "sum": {
                  "dataPoints": [{
                    "timeUnixNano": "1700000000000000000",
                    "asInt": "42"
                  }],
                  "aggregationTemporality": 2,
                  "isMonotonic": true
                }
              }]
            }]
          }]
        }
        """
        let records = try OTLPDecoder.decodeMetrics(from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records[0].name == "requests.total")
        #expect(records[0].metricType == "sum")
    }

    @Test func testDecodeHistogramMetric() throws {
        let json = """
        {
          "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test-svc"}}]},
            "scopeMetrics": [{
              "metrics": [{
                "name": "request.duration",
                "histogram": {
                  "dataPoints": [{
                    "timeUnixNano": "1700000000000000000",
                    "count": "100",
                    "sum": 5.5,
                    "bucketCounts": ["10", "20", "30", "40"],
                    "explicitBounds": [0.1, 0.5, 1.0]
                  }]
                }
              }]
            }]
          }]
        }
        """
        let records = try OTLPDecoder.decodeMetrics(from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records[0].name == "request.duration")
        #expect(records[0].metricType == "histogram")
        #expect(records[0].dataJSON.contains("bucketCounts"))
    }

    @Test func testDecodeMultipleMetrics() throws {
        let json = """
        {
          "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "svc"}}]},
            "scopeMetrics": [{
              "metrics": [
                {
                  "name": "metric.a",
                  "gauge": {"dataPoints": [{"timeUnixNano": "1700000000000000000", "asDouble": 1.0}]}
                },
                {
                  "name": "metric.b",
                  "sum": {"dataPoints": [{"timeUnixNano": "1700000000000000000", "asInt": "5"}]}
                }
              ]
            }]
          }]
        }
        """
        let records = try OTLPDecoder.decodeMetrics(from: Data(json.utf8))
        #expect(records.count == 2)
        let names = Set(records.map(\.name))
        #expect(names == Set(["metric.a", "metric.b"]))
    }

    @Test func testDecodeEmptyMetrics() throws {
        let json = """
        {"resourceMetrics": []}
        """
        let records = try OTLPDecoder.decodeMetrics(from: Data(json.utf8))
        #expect(records.isEmpty)
    }

    // MARK: - Store Tests

    @Test func testMetricInsertAndQuery() async throws {
        let path = NSTemporaryDirectory() + "metrics-test-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)

        let metric = MetricRecord(
            timestamp: 1700000000000000000,
            name: "cpu.usage",
            metricType: "gauge",
            serviceName: "test-svc",
            attributes: nil,
            dataJSON: "{\"asDouble\": 0.75}"
        )

        try await store.insertMetrics([metric])

        let page = try await store.listMetrics()
        #expect(page.metrics.count == 1)
        #expect(page.metrics[0].name == "cpu.usage")
        #expect(page.metrics[0].metricType == "gauge")
    }

    @Test func testListMetricNames() async throws {
        let path = NSTemporaryDirectory() + "metrics-names-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)

        let metrics = [
            MetricRecord(timestamp: 1700000000000000000, name: "cpu.usage", metricType: "gauge", serviceName: "svc", dataJSON: "{}"),
            MetricRecord(timestamp: 1700000000000000001, name: "memory.used", metricType: "gauge", serviceName: "svc", dataJSON: "{}"),
            MetricRecord(timestamp: 1700000000000000002, name: "cpu.usage", metricType: "gauge", serviceName: "svc", dataJSON: "{}"),
        ]

        try await store.insertMetrics(metrics)

        let names = try await store.listMetricNames()
        #expect(names.count == 2)
        #expect(names.contains("cpu.usage"))
        #expect(names.contains("memory.used"))
    }

    @Test func testMetricFilterByName() async throws {
        let path = NSTemporaryDirectory() + "metrics-filter-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)

        let metrics = [
            MetricRecord(timestamp: 1700000000000000000, name: "cpu.usage", metricType: "gauge", serviceName: "svc", dataJSON: "{}"),
            MetricRecord(timestamp: 1700000000000000001, name: "memory.used", metricType: "gauge", serviceName: "svc", dataJSON: "{}"),
        ]

        try await store.insertMetrics(metrics)

        let page = try await store.listMetrics(name: "cpu.usage")
        #expect(page.metrics.count == 1)
        #expect(page.metrics[0].name == "cpu.usage")
    }

    @Test func testMetricRetentionCleanup() async throws {
        let path = NSTemporaryDirectory() + "metrics-retention-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)

        let oldMetric = MetricRecord(timestamp: 100, name: "old.metric", metricType: "gauge", serviceName: "svc", dataJSON: "{}")
        let newMetric = MetricRecord(timestamp: 1700000000000000000, name: "new.metric", metricType: "gauge", serviceName: "svc", dataJSON: "{}")

        try await store.insertMetrics([oldMetric, newMetric])
        try await store.deleteOlderThan(1000)

        let page = try await store.listMetrics()
        #expect(page.metrics.count == 1)
        #expect(page.metrics[0].name == "new.metric")
    }

    // MARK: - HTTP Integration Test

    @Test func testMetricsHTTPIngestion() async throws {
        let path = NSTemporaryDirectory() + "metrics-http-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)
        let ingester = SpanIngester(store: store)
        let port = Int.random(in: 40000...50000)
        let server = try await OTelHTTPServer(host: "127.0.0.1", port: port, ingester: ingester, store: store, authToken: nil)
        Task { try await server.run() }
        defer { Task { try? await server.shutdown() } }
        try await Task.sleep(for: .milliseconds(100))

        let metricsJSON = """
        {
          "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "http-test"}}]},
            "scopeMetrics": [{
              "metrics": [{
                "name": "http.requests",
                "sum": {
                  "dataPoints": [{
                    "timeUnixNano": "1700000000000000000",
                    "asInt": "42"
                  }]
                }
              }]
            }]
          }]
        }
        """

        // POST metrics
        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/metrics")!
        var request = URLRequest(url: ingestURL)
        request.httpMethod = "POST"
        request.httpBody = Data(metricsJSON.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        // GET metrics
        let queryURL = URL(string: "http://127.0.0.1:\(port)/api/metrics")!
        let (queryData, queryResponse) = try await URLSession.shared.data(from: queryURL)
        let queryHTTP = queryResponse as! HTTPURLResponse
        #expect(queryHTTP.statusCode == 200)

        let page = try JSONDecoder().decode(MetricPage.self, from: queryData)
        #expect(page.metrics.count == 1)
        #expect(page.metrics[0].name == "http.requests")

        // GET metric names
        let namesURL = URL(string: "http://127.0.0.1:\(port)/api/metric-names")!
        let (namesData, namesResponse) = try await URLSession.shared.data(from: namesURL)
        let namesHTTP = namesResponse as! HTTPURLResponse
        #expect(namesHTTP.statusCode == 200)

        let names = try JSONDecoder().decode([String].self, from: namesData)
        #expect(names.contains("http.requests"))
    }
}
