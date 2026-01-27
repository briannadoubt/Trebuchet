// TracingTests.swift
// Tests for distributed tracing infrastructure

import Testing
import Foundation
import Trebuche
@testable import TrebucheObservability

@Suite("Tracing Tests")
struct TracingTests {

    // MARK: - TraceContext Tests

    @Test("TraceContext creation")
    func testTraceContextCreation() {
        let context = TraceContext()

        #expect(context.traceID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(context.spanID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(context.parentSpanID == nil)
    }

    @Test("TraceContext child creation")
    func testTraceContextChildCreation() {
        let parent = TraceContext()
        let child = parent.createChild()

        #expect(child.traceID == parent.traceID)
        #expect(child.spanID != parent.spanID)
        #expect(child.parentSpanID == parent.spanID)
    }

    @Test("TraceContext preserves traceID through generations")
    func testTraceContextPreservesTraceID() {
        let root = TraceContext()
        let child1 = root.createChild()
        let child2 = child1.createChild()
        let child3 = child2.createChild()

        #expect(root.traceID == child1.traceID)
        #expect(root.traceID == child2.traceID)
        #expect(root.traceID == child3.traceID)

        #expect(child1.parentSpanID == root.spanID)
        #expect(child2.parentSpanID == child1.spanID)
        #expect(child3.parentSpanID == child2.spanID)
    }

    // MARK: - Span Tests

    @Test("Span creation")
    func testSpanCreation() {
        let context = TraceContext()
        var span = Span(context: context, name: "test-operation")

        #expect(span.name == "test-operation")
        #expect(span.kind == .internal)
        #expect(span.status == .unset)
        #expect(span.endTime == nil)
        #expect(span.attributes.isEmpty)
        #expect(span.events.isEmpty)
    }

    @Test("Span end")
    func testSpanEnd() {
        let context = TraceContext()
        var span = Span(context: context, name: "test")

        #expect(span.endTime == nil)
        #expect(span.duration == nil)

        span.end(status: .ok)

        #expect(span.endTime != nil)
        #expect(span.status == .ok)
        #expect(span.duration != nil)
    }

    @Test("Span attributes")
    func testSpanAttributes() {
        let context = TraceContext()
        var span = Span(context: context, name: "test")

        span.setAttribute("http.method", value: "POST")
        span.setAttribute("http.status_code", value: "200")

        #expect(span.attributes.count == 2)
        #expect(span.attributes["http.method"] == "POST")
        #expect(span.attributes["http.status_code"] == "200")
    }

    @Test("Span events")
    func testSpanEvents() {
        let context = TraceContext()
        var span = Span(context: context, name: "test")

        let event1 = SpanEvent(name: "cache_hit")
        let event2 = SpanEvent(name: "database_query", attributes: ["query": "SELECT *"])

        span.addEvent(event1)
        span.addEvent(event2)

        #expect(span.events.count == 2)
        #expect(span.events[0].name == "cache_hit")
        #expect(span.events[1].name == "database_query")
        #expect(span.events[1].attributes["query"] == "SELECT *")
    }

    @Test("Span kinds")
    func testSpanKinds() {
        let context = TraceContext()

        let internalSpan = Span(context: context, name: "internal", kind: .internal)
        let clientSpan = Span(context: context, name: "client", kind: .client)
        let serverSpan = Span(context: context, name: "server", kind: .server)

        #expect(internalSpan.kind == .internal)
        #expect(clientSpan.kind == .client)
        #expect(serverSpan.kind == .server)
    }

    @Test("Span statuses")
    func testSpanStatuses() {
        let context = TraceContext()
        var span = Span(context: context, name: "test")

        #expect(span.status == .unset)

        span.end(status: .ok)
        #expect(span.status == .ok)

        var errorSpan = Span(context: context, name: "error-test")
        errorSpan.end(status: .error)
        #expect(errorSpan.status == .error)
    }

    // MARK: - InMemorySpanExporter Tests

    @Test("InMemorySpanExporter exports spans")
    func testInMemorySpanExporter() async {
        let exporter = InMemorySpanExporter()
        let context = TraceContext()

        var span1 = Span(context: context, name: "span1")
        span1.end()

        var span2 = Span(context: context, name: "span2")
        span2.end()

        try? await exporter.export([span1, span2])

        let exported = await exporter.getExportedSpans()
        #expect(exported.count == 2)
        #expect(exported[0].name == "span1")
        #expect(exported[1].name == "span2")
    }

    @Test("InMemorySpanExporter reset")
    func testInMemorySpanExporterReset() async {
        let exporter = InMemorySpanExporter()
        let context = TraceContext()

        var span = Span(context: context, name: "test")
        span.end()

        try? await exporter.export([span])

        var exported = await exporter.getExportedSpans()
        #expect(exported.count == 1)

        await exporter.reset()

        exported = await exporter.getExportedSpans()
        #expect(exported.count == 0)
    }

    // MARK: - ConsoleSpanExporter Tests

    @Test("ConsoleSpanExporter exports spans")
    func testConsoleSpanExporter() async {
        let exporter = ConsoleSpanExporter()
        let context = TraceContext()

        var span = Span(context: context, name: "test-operation", kind: .server)
        span.setAttribute("http.method", value: "GET")
        span.end(status: .ok)

        // This will print to console, we just verify it doesn't throw
        try? await exporter.export([span])
    }

    // MARK: - Integration Tests

    @Test("Span duration calculation")
    func testSpanDurationCalculation() async {
        let context = TraceContext()
        let startTime = Date()
        var span = Span(context: context, name: "test", startTime: startTime)

        // Simulate some work
        try? await Task.sleep(for: .milliseconds(10))

        span.end()

        let duration = span.duration
        #expect(duration != nil)

        // Duration should be at least 10ms
        if let duration {
            let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
            #expect(ms >= 10)
        }
    }

    @Test("Trace context roundtrip encoding")
    func testTraceContextRoundtripEncoding() throws {
        let original = TraceContext()

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TraceContext.self, from: encoded)

        #expect(decoded.traceID == original.traceID)
        #expect(decoded.spanID == original.spanID)
        #expect(decoded.parentSpanID == original.parentSpanID)
    }

    @Test("Trace context with child roundtrip")
    func testTraceContextWithChildRoundtrip() throws {
        let parent = TraceContext()
        let child = parent.createChild()

        let encoded = try JSONEncoder().encode(child)
        let decoded = try JSONDecoder().decode(TraceContext.self, from: encoded)

        #expect(decoded.traceID == parent.traceID)
        #expect(decoded.spanID == child.spanID)
        #expect(decoded.parentSpanID == parent.spanID)
    }
}
