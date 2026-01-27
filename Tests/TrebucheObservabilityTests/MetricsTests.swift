// MetricsTests.swift
// Tests for metrics collection infrastructure

import Testing
import Foundation
@testable import TrebucheObservability

@Suite("Metrics Tests")
struct MetricsTests {

    // MARK: - Counter Tests

    @Test("Counter increments")
    func testCounterIncrements() async {
        let counter = Counter(name: "test.counter")

        await counter.increment()
        #expect(await counter.value() == 1)

        await counter.increment(by: 5)
        #expect(await counter.value() == 6)

        await counter.increment(by: 10)
        #expect(await counter.value() == 16)
    }

    @Test("Counter with tags")
    func testCounterWithTags() async {
        let counter = Counter(name: "requests")

        await counter.increment(tags: ["method": "GET"])
        await counter.increment(tags: ["method": "POST"])
        await counter.increment(tags: ["method": "GET"])

        #expect(await counter.value(for: ["method": "GET"]) == 2)
        #expect(await counter.value(for: ["method": "POST"]) == 1)
    }

    @Test("Counter reset")
    func testCounterReset() async {
        let counter = Counter(name: "test")

        await counter.increment(by: 10)
        #expect(await counter.value() == 10)

        await counter.reset()
        #expect(await counter.value() == 0)
    }

    @Test("Counter all values")
    func testCounterAllValues() async {
        let counter = Counter(name: "test")

        await counter.increment(tags: ["status": "200"])
        await counter.increment(tags: ["status": "404"])
        await counter.increment(tags: ["status": "200"])

        let values = await counter.allValues()
        #expect(values.count == 2)

        let sorted = values.sorted { $0.value > $1.value }
        #expect(sorted[0].value == 2)
        #expect(sorted[1].value == 1)
    }

    // MARK: - Gauge Tests

    @Test("Gauge set and get")
    func testGaugeSetAndGet() async {
        let gauge = Gauge(name: "memory")

        await gauge.set(to: 100.0)
        #expect(await gauge.value() == 100.0)

        await gauge.set(to: 250.5)
        #expect(await gauge.value() == 250.5)
    }

    @Test("Gauge increment and decrement")
    func testGaugeIncrementDecrement() async {
        let gauge = Gauge(name: "connections")

        await gauge.set(to: 10.0)
        await gauge.increment(by: 5.0)
        #expect(await gauge.value() == 15.0)

        await gauge.decrement(by: 3.0)
        #expect(await gauge.value() == 12.0)
    }

    @Test("Gauge with tags")
    func testGaugeWithTags() async {
        let gauge = Gauge(name: "active_users")

        await gauge.set(to: 100, tags: ["region": "us-east"])
        await gauge.set(to: 50, tags: ["region": "eu-west"])

        #expect(await gauge.value(for: ["region": "us-east"]) == 100)
        #expect(await gauge.value(for: ["region": "eu-west"]) == 50)
    }

    // MARK: - Histogram Tests

    @Test("Histogram records values")
    func testHistogramRecordsValues() async {
        let histogram = Histogram(name: "latency")

        await histogram.record(10.0)
        await histogram.record(20.0)
        await histogram.record(30.0)

        let stats = await histogram.statistics()
        #expect(stats != nil)
        #expect(stats!.count == 3)
        #expect(stats!.min == 10.0)
        #expect(stats!.max == 30.0)
        #expect(stats!.mean == 20.0)
    }

    @Test("Histogram percentiles")
    func testHistogramPercentiles() async {
        let histogram = Histogram(name: "response_time")

        // Record 100 values: 1, 2, 3, ..., 100
        for i in 1...100 {
            await histogram.record(Double(i))
        }

        let stats = await histogram.statistics()
        #expect(stats != nil)
        #expect(stats!.count == 100)
        // With interpolation, p50 of 100 values (1-100) is 50.5
        #expect(abs(stats!.p50 - 50.5) < 0.1)
        #expect(abs(stats!.p95 - 95.05) < 0.1)
        #expect(abs(stats!.p99 - 99.01) < 0.1)
    }

    @Test("Histogram with duration")
    func testHistogramWithDuration() async {
        let histogram = Histogram(name: "duration")

        await histogram.record(.milliseconds(100))
        await histogram.record(.milliseconds(200))
        await histogram.record(.milliseconds(300))

        let stats = await histogram.statistics()
        #expect(stats != nil)
        #expect(stats!.min == 100.0)
        #expect(stats!.max == 300.0)
    }

    @Test("Histogram with tags")
    func testHistogramWithTags() async {
        let histogram = Histogram(name: "latency")

        await histogram.record(10.0, tags: ["endpoint": "/api/users"])
        await histogram.record(20.0, tags: ["endpoint": "/api/users"])
        await histogram.record(100.0, tags: ["endpoint": "/api/posts"])

        let userStats = await histogram.statistics(for: ["endpoint": "/api/users"])
        #expect(userStats != nil)
        #expect(userStats!.count == 2)
        #expect(userStats!.mean == 15.0)

        let postStats = await histogram.statistics(for: ["endpoint": "/api/posts"])
        #expect(postStats != nil)
        #expect(postStats!.count == 1)
        #expect(postStats!.mean == 100.0)
    }

    // MARK: - InMemoryCollector Tests

    @Test("InMemoryCollector counter")
    func testInMemoryCollectorCounter() async {
        let collector = InMemoryMetricsCollector()

        await collector.incrementCounter("requests", by: 1, tags: [:])
        await collector.incrementCounter("requests", by: 2, tags: [:])

        let counter = await collector.counter("requests")
        #expect(counter != nil)

        // Give async operations time to complete
        try? await Task.sleep(for: .milliseconds(10))

        let value = await counter!.value()
        #expect(value == 3)
    }

    @Test("InMemoryCollector gauge")
    func testInMemoryCollectorGauge() async {
        let collector = InMemoryMetricsCollector()

        await collector.recordGauge("memory", value: 512.0, tags: [:])

        let gauge = await collector.gauge("memory")
        #expect(gauge != nil)

        // Give async operations time to complete
        try? await Task.sleep(for: .milliseconds(10))

        let value = await gauge!.value()
        #expect(value == 512.0)
    }

    @Test("InMemoryCollector histogram")
    func testInMemoryCollectorHistogram() async {
        let collector = InMemoryMetricsCollector()

        await collector.recordHistogram("latency", value: .milliseconds(100), tags: [:])
        await collector.recordHistogram("latency", value: .milliseconds(200), tags: [:])

        let histogram = await collector.histogram("latency")
        #expect(histogram != nil)

        // Give async operations time to complete
        try? await Task.sleep(for: .milliseconds(10))

        let stats = await histogram!.statistics()
        #expect(stats != nil)
        #expect(stats!.count == 2)
    }

    @Test("InMemoryCollector summary")
    func testInMemoryCollectorSummary() async {
        let collector = InMemoryMetricsCollector()

        await collector.incrementCounter("requests", by: 5, tags: ["method": "GET"])
        await collector.recordGauge("memory", value: 1024.0, tags: [:])
        await collector.recordHistogram("latency", value: .milliseconds(150), tags: [:])

        // Give async operations time to complete
        try? await Task.sleep(for: .milliseconds(10))

        let summary = await collector.summary()
        #expect(summary.contains("requests"))
        #expect(summary.contains("memory"))
        #expect(summary.contains("latency"))
    }

    @Test("InMemoryCollector reset")
    func testInMemoryCollectorReset() async {
        let collector = InMemoryMetricsCollector()

        await collector.incrementCounter("test", by: 10, tags: [:])
        try? await Task.sleep(for: .milliseconds(10))

        let counterBefore = await collector.counter("test")
        #expect(counterBefore != nil)

        await collector.reset()

        let counterAfter = await collector.counter("test")
        #expect(counterAfter == nil)
    }

    // MARK: - Standard Metrics Tests

    @Test("Standard metric names")
    func testStandardMetricNames() {
        // Verify standard metric names are defined
        #expect(TrebucheMetrics.invocationsCount == "trebuche.invocations.count")
        #expect(TrebucheMetrics.invocationsLatency == "trebuche.invocations.latency")
        #expect(TrebucheMetrics.invocationsErrors == "trebuche.invocations.errors")
        #expect(TrebucheMetrics.connectionsActive == "trebuche.connections.active")
        #expect(TrebucheMetrics.stateOperationsCount == "trebuche.state.operations.count")
    }

    // MARK: - CloudWatch Configuration Tests

    @Test("CloudWatch configuration")
    func testCloudWatchConfiguration() {
        let config = CloudWatchConfiguration(
            namespace: "Trebuche/Production",
            region: "us-east-1",
            flushInterval: .seconds(60),
            maxBatchSize: 20
        )

        #expect(config.namespace == "Trebuche/Production")
        #expect(config.region == "us-east-1")
        #expect(config.flushInterval == .seconds(60))
        #expect(config.maxBatchSize == 20)
    }

    @Test("CloudWatch configuration defaults")
    func testCloudWatchConfigurationDefaults() {
        let config = CloudWatchConfiguration(namespace: "Test")

        #expect(config.region == "us-east-1")
        #expect(config.flushInterval == .seconds(60))
        #expect(config.maxBatchSize == 20)
    }

    // MARK: - Integration Tests

    @Test("MetricsCollector convenience methods")
    func testMetricsCollectorConvenienceMethods() async {
        let collector = InMemoryMetricsCollector()

        // Test convenience increment by 1
        await collector.incrementCounter("clicks")
        try? await Task.sleep(for: .milliseconds(10))

        let counter = await collector.counter("clicks")
        #expect(counter != nil)
        let value = await counter!.value()
        #expect(value == 1)

        // Test convenience histogram milliseconds
        await collector.recordHistogramMilliseconds("api_latency", milliseconds: 250.5)
        try? await Task.sleep(for: .milliseconds(10))

        let histogram = await collector.histogram("api_latency")
        #expect(histogram != nil)
        let stats = await histogram!.statistics()
        #expect(stats != nil)
        #expect(stats!.mean == 250.5)
    }
}
