import Testing
import Foundation
@testable import TrebuchetOTel

@Suite("OTLPDecoder Tests")
struct OTLPDecoderTests {

    // MARK: - Traces

    @Test func testDecodeTracesMinimal() throws {
        let json = """
        {
          "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test-svc"}}]},
            "scopeSpans": [{
              "scope": {"name": "test"},
              "spans": [{
                "traceId": "aaaabbbbccccdddd1111222233334444",
                "spanId": "1111222233334444",
                "name": "test-operation",
                "kind": 2,
                "startTimeUnixNano": "1700000000000000000",
                "endTimeUnixNano": "1700000001000000000",
                "status": {"code": 1}
              }]
            }]
          }]
        }
        """
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.count == 1)

        let span = spans[0]
        #expect(span.traceId == "aaaabbbbccccdddd1111222233334444")
        #expect(span.spanId == "1111222233334444")
        #expect(span.parentSpanId == nil || span.parentSpanId == "")
        #expect(span.operationName == "test-operation")
        #expect(span.serviceName == "test-svc")
        #expect(span.spanKind == 2)
        #expect(span.startTimeNano == 1_700_000_000_000_000_000)
        #expect(span.endTimeNano == 1_700_000_001_000_000_000)
        #expect(span.durationNano == 1_000_000_000)
        #expect(span.statusCode == 1)
    }

    @Test func testDecodeTracesWithAttributes() throws {
        let json = """
        {
          "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "attr-svc"}}]},
            "scopeSpans": [{
              "spans": [{
                "traceId": "aaaa000000000000aaaa000000000000",
                "spanId": "bbbb000000000000",
                "name": "with-attrs",
                "kind": 1,
                "startTimeUnixNano": "1700000000000000000",
                "endTimeUnixNano": "1700000000500000000",
                "status": {"code": 0},
                "attributes": [
                  {"key": "rpc.method", "value": {"stringValue": "join"}},
                  {"key": "player.count", "value": {"intValue": "42"}},
                  {"key": "is.active", "value": {"boolValue": true}}
                ]
              }]
            }]
          }]
        }
        """
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.count == 1)

        let span = spans[0]
        #expect(span.attributes != nil)
        // Parse the serialized JSON attributes to verify content
        let attrsData = Data(span.attributes!.utf8)
        let attrs = try JSONSerialization.jsonObject(with: attrsData) as! [String: Any]
        #expect(attrs["rpc.method"] as? String == "join")
        #expect(attrs["is.active"] as? Bool == true)
        // intValue is parsed from string "42" to Int64
        #expect(attrs["player.count"] as? Int64 == 42 || attrs["player.count"] as? Int == 42)
    }

    @Test func testDecodeTracesMultipleSpans() throws {
        let json = """
        {
          "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "multi-svc"}}]},
            "scopeSpans": [{
              "spans": [
                {
                  "traceId": "trace1trace1trace1trace1trace1aa",
                  "spanId": "span1span1span1aa",
                  "name": "op-1",
                  "kind": 2,
                  "startTimeUnixNano": "1700000000000000000",
                  "endTimeUnixNano": "1700000001000000000",
                  "status": {"code": 1}
                },
                {
                  "traceId": "trace1trace1trace1trace1trace1aa",
                  "spanId": "span2span2span2aa",
                  "parentSpanId": "span1span1span1aa",
                  "name": "op-2",
                  "kind": 3,
                  "startTimeUnixNano": "1700000000100000000",
                  "endTimeUnixNano": "1700000000900000000",
                  "status": {"code": 0}
                },
                {
                  "traceId": "trace2trace2trace2trace2trace2bb",
                  "spanId": "span3span3span3bb",
                  "name": "op-3",
                  "kind": 1,
                  "startTimeUnixNano": "1700000002000000000",
                  "endTimeUnixNano": "1700000003000000000",
                  "status": {"code": 2}
                }
              ]
            }]
          }]
        }
        """
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.count == 3)

        let traceIds = Set(spans.map(\.traceId))
        #expect(traceIds.count == 2)

        let secondSpan = spans.first(where: { $0.spanId == "span2span2span2aa" })!
        #expect(secondSpan.parentSpanId == "span1span1span1aa")
    }

    @Test func testDecodeTracesEmptyPayload() throws {
        let json = "{}"
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.isEmpty)
    }

    @Test func testDecodeTracesInvalidJSON() throws {
        let garbage = Data("not valid json!!!".utf8)
        #expect(throws: (any Error).self) {
            try OTLPDecoder.decodeTraces(from: garbage)
        }
    }

    @Test func testDecodeTracesWithEvents() throws {
        let json = """
        {
          "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "event-svc"}}]},
            "scopeSpans": [{
              "spans": [{
                "traceId": "eeeeeeee00000000eeeeeeee00000000",
                "spanId": "eeee111122223333",
                "name": "with-events",
                "kind": 1,
                "startTimeUnixNano": "1700000000000000000",
                "endTimeUnixNano": "1700000001000000000",
                "status": {"code": 1},
                "events": [
                  {
                    "name": "exception",
                    "timeUnixNano": "1700000000500000000",
                    "attributes": [
                      {"key": "exception.message", "value": {"stringValue": "Something broke"}}
                    ]
                  }
                ]
              }]
            }]
          }]
        }
        """
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.count == 1)
        #expect(spans[0].events != nil)

        let eventsData = Data(spans[0].events!.utf8)
        let events = try JSONSerialization.jsonObject(with: eventsData) as! [[String: Any]]
        #expect(events.count == 1)
        #expect(events[0]["name"] as? String == "exception")
    }

    @Test func testDecodeTracesServiceName() throws {
        let json = """
        {
          "resourceSpans": [{
            "resource": {
              "attributes": [
                {"key": "service.name", "value": {"stringValue": "my-awesome-service"}},
                {"key": "service.version", "value": {"stringValue": "1.2.3"}}
              ]
            },
            "scopeSpans": [{
              "spans": [{
                "traceId": "aaaa000000000000bbbb000000000000",
                "spanId": "cccc000000000000",
                "name": "hello",
                "kind": 1,
                "startTimeUnixNano": "1700000000000000000",
                "endTimeUnixNano": "1700000000100000000",
                "status": {"code": 0}
              }]
            }]
          }]
        }
        """
        let spans = try OTLPDecoder.decodeTraces(from: Data(json.utf8))
        #expect(spans.count == 1)
        #expect(spans[0].serviceName == "my-awesome-service")
        // Resource attributes should also be captured
        #expect(spans[0].resourceAttrs != nil)
        let resData = Data(spans[0].resourceAttrs!.utf8)
        let resAttrs = try JSONSerialization.jsonObject(with: resData) as! [String: Any]
        #expect(resAttrs["service.name"] as? String == "my-awesome-service")
        #expect(resAttrs["service.version"] as? String == "1.2.3")
    }

    // MARK: - Logs

    @Test func testDecodeLogsMinimal() throws {
        let json = """
        {
          "resourceLogs": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "log-svc"}}]},
            "scopeLogs": [{
              "logRecords": [{
                "timeUnixNano": "1700000000000000000",
                "severityNumber": 9,
                "severityText": "INFO",
                "body": {"stringValue": "Server started"}
              }]
            }]
          }]
        }
        """
        let logs = try OTLPDecoder.decodeLogs(from: Data(json.utf8))
        #expect(logs.count == 1)

        let log = logs[0]
        #expect(log.timestamp == 1_700_000_000_000_000_000)
        #expect(log.severityNumber == 9)
        #expect(log.severityText == "INFO")
        #expect(log.body == "Server started")
        #expect(log.serviceName == "log-svc")
        #expect(log.traceId == nil)
        #expect(log.spanId == nil)
    }

    @Test func testDecodeLogsWithTraceContext() throws {
        let json = """
        {
          "resourceLogs": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "ctx-svc"}}]},
            "scopeLogs": [{
              "logRecords": [{
                "timeUnixNano": "1700000000000000000",
                "severityNumber": 9,
                "severityText": "INFO",
                "body": {"stringValue": "Handling request"},
                "traceId": "aaaabbbbccccdddd1111222233334444",
                "spanId": "1111222233334444"
              }]
            }]
          }]
        }
        """
        let logs = try OTLPDecoder.decodeLogs(from: Data(json.utf8))
        #expect(logs.count == 1)
        #expect(logs[0].traceId == "aaaabbbbccccdddd1111222233334444")
        #expect(logs[0].spanId == "1111222233334444")
    }

    @Test func testDecodeLogsSeverityLevels() throws {
        // Test that severityNumber maps to correct text when severityText is not provided
        let json = """
        {
          "resourceLogs": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "sev-svc"}}]},
            "scopeLogs": [{
              "logRecords": [
                {
                  "timeUnixNano": "1700000000000000000",
                  "severityNumber": 9,
                  "body": {"stringValue": "info message"}
                },
                {
                  "timeUnixNano": "1700000000100000000",
                  "severityNumber": 17,
                  "body": {"stringValue": "error message"}
                },
                {
                  "timeUnixNano": "1700000000200000000",
                  "severityNumber": 5,
                  "body": {"stringValue": "debug message"}
                },
                {
                  "timeUnixNano": "1700000000300000000",
                  "severityNumber": 13,
                  "body": {"stringValue": "warn message"}
                },
                {
                  "timeUnixNano": "1700000000400000000",
                  "severityNumber": 21,
                  "body": {"stringValue": "fatal message"}
                }
              ]
            }]
          }]
        }
        """
        let logs = try OTLPDecoder.decodeLogs(from: Data(json.utf8))
        #expect(logs.count == 5)

        let bySeverity = Dictionary(uniqueKeysWithValues: logs.map { ($0.severityNumber, $0.severityText) })
        #expect(bySeverity[9] == "INFO")
        #expect(bySeverity[17] == "ERROR")
        #expect(bySeverity[5] == "DEBUG")
        #expect(bySeverity[13] == "WARN")
        #expect(bySeverity[21] == "FATAL")
    }

    @Test func testDecodeLogsEmptyPayload() throws {
        let json = "{}"
        let logs = try OTLPDecoder.decodeLogs(from: Data(json.utf8))
        #expect(logs.isEmpty)
    }
}
