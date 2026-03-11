import Foundation

public enum OTLPDecoder {
    public static func decodeTraces(from data: Data) throws -> [SpanRecord] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceSpans = json["resourceSpans"] as? [[String: Any]] else {
            return []
        }

        var records: [SpanRecord] = []

        for resourceSpan in resourceSpans {
            let serviceName = extractServiceName(from: resourceSpan)
            let resourceAttrs = extractResourceAttrs(from: resourceSpan)

            guard let scopeSpans = resourceSpan["scopeSpans"] as? [[String: Any]] else { continue }

            for scopeSpan in scopeSpans {
                guard let spans = scopeSpan["spans"] as? [[String: Any]] else { continue }

                for span in spans {
                    if let record = parseSpan(span, serviceName: serviceName, resourceAttrs: resourceAttrs) {
                        records.append(record)
                    }
                }
            }
        }

        return records
    }

    public static func decodeLogs(from data: Data) throws -> [LogRecord] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceLogs = json["resourceLogs"] as? [[String: Any]] else {
            return []
        }

        var records: [LogRecord] = []

        for resourceLog in resourceLogs {
            let serviceName = extractServiceName(from: resourceLog)

            guard let scopeLogs = resourceLog["scopeLogs"] as? [[String: Any]] else { continue }

            for scopeLog in scopeLogs {
                guard let logRecords = scopeLog["logRecords"] as? [[String: Any]] else { continue }

                for logRecord in logRecords {
                    if let record = parseLogRecord(logRecord, serviceName: serviceName) {
                        records.append(record)
                    }
                }
            }
        }

        return records
    }

    public static func decodeMetrics(from data: Data) throws -> [MetricRecord] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceMetrics = json["resourceMetrics"] as? [[String: Any]] else {
            return []
        }

        var records: [MetricRecord] = []

        for resourceMetric in resourceMetrics {
            let serviceName = extractServiceName(from: resourceMetric)

            guard let scopeMetrics = resourceMetric["scopeMetrics"] as? [[String: Any]] else { continue }

            for scopeMetric in scopeMetrics {
                guard let metrics = scopeMetric["metrics"] as? [[String: Any]] else { continue }

                for metric in metrics {
                    guard let name = metric["name"] as? String else { continue }

                    // Determine metric type and extract data points
                    let metricTypeAndPoints: [(String, [String: Any])]
                    if let gauge = metric["gauge"] as? [String: Any],
                       let dataPoints = gauge["dataPoints"] as? [[String: Any]] {
                        metricTypeAndPoints = dataPoints.map { ("gauge", $0) }
                    } else if let sum = metric["sum"] as? [String: Any],
                              let dataPoints = sum["dataPoints"] as? [[String: Any]] {
                        metricTypeAndPoints = dataPoints.map { ("sum", $0) }
                    } else if let histogram = metric["histogram"] as? [String: Any],
                              let dataPoints = histogram["dataPoints"] as? [[String: Any]] {
                        metricTypeAndPoints = dataPoints.map { ("histogram", $0) }
                    } else if let expHistogram = metric["exponentialHistogram"] as? [String: Any],
                              let dataPoints = expHistogram["dataPoints"] as? [[String: Any]] {
                        metricTypeAndPoints = dataPoints.map { ("exponentialHistogram", $0) }
                    } else if let summary = metric["summary"] as? [String: Any],
                              let dataPoints = summary["dataPoints"] as? [[String: Any]] {
                        metricTypeAndPoints = dataPoints.map { ("summary", $0) }
                    } else {
                        continue
                    }

                    for (metricType, dataPoint) in metricTypeAndPoints {
                        let timestamp = parseNanoTimestamp(dataPoint["timeUnixNano"])

                        let attributes: String?
                        if let attrs = dataPoint["attributes"] as? [[String: Any]], !attrs.isEmpty {
                            attributes = serializeJSON(flattenAttributes(attrs))
                        } else {
                            attributes = nil
                        }

                        let dataJSON = serializeJSON(dataPoint) ?? "{}"

                        records.append(MetricRecord(
                            timestamp: timestamp,
                            name: name,
                            metricType: metricType,
                            serviceName: serviceName,
                            attributes: attributes,
                            dataJSON: dataJSON
                        ))
                    }
                }
            }
        }

        return records
    }

    // MARK: - Log Parsing

    private static func parseLogRecord(
        _ log: [String: Any],
        serviceName: String
    ) -> LogRecord? {
        let timestamp = parseNanoTimestamp(log["timeUnixNano"])
        let severityNumber = log["severityNumber"] as? Int ?? 0
        let severityText = log["severityText"] as? String ?? severityTextFromNumber(severityNumber)

        let body: String
        if let bodyObj = log["body"] as? [String: Any],
           let stringValue = bodyObj["stringValue"] as? String {
            body = stringValue
        } else if let bodyStr = log["body"] as? String {
            body = bodyStr
        } else {
            body = ""
        }

        let traceId = log["traceId"] as? String
        let spanId = log["spanId"] as? String

        let attributes: String?
        if let attrs = log["attributes"] as? [[String: Any]], !attrs.isEmpty {
            attributes = serializeJSON(flattenAttributes(attrs))
        } else {
            attributes = nil
        }

        return LogRecord(
            timestamp: timestamp,
            traceId: traceId.flatMap { $0.isEmpty ? nil : $0 },
            spanId: spanId.flatMap { $0.isEmpty ? nil : $0 },
            severityNumber: severityNumber,
            severityText: severityText,
            body: body,
            serviceName: serviceName,
            attributes: attributes
        )
    }

    private static func severityTextFromNumber(_ number: Int) -> String {
        switch number {
        case 1...4: return "TRACE"
        case 5...8: return "DEBUG"
        case 9...12: return "INFO"
        case 13...16: return "WARN"
        case 17...20: return "ERROR"
        case 21...24: return "FATAL"
        default: return "UNSPECIFIED"
        }
    }

    // MARK: - Resource Extraction

    private static func extractServiceName(from resourceSpan: [String: Any]) -> String {
        guard let resource = resourceSpan["resource"] as? [String: Any],
              let attributes = resource["attributes"] as? [[String: Any]] else {
            return "unknown"
        }

        for attr in attributes {
            if attr["key"] as? String == "service.name",
               let value = attr["value"] as? [String: Any],
               let stringValue = value["stringValue"] as? String {
                return stringValue
            }
        }

        return "unknown"
    }

    private static func extractResourceAttrs(from resourceSpan: [String: Any]) -> String? {
        guard let resource = resourceSpan["resource"] as? [String: Any],
              let attributes = resource["attributes"] as? [[String: Any]],
              !attributes.isEmpty else {
            return nil
        }

        return serializeJSON(flattenAttributes(attributes))
    }

    // MARK: - Span Parsing

    private static func parseSpan(
        _ span: [String: Any],
        serviceName: String,
        resourceAttrs: String?
    ) -> SpanRecord? {
        guard let traceId = span["traceId"] as? String,
              let spanId = span["spanId"] as? String,
              let name = span["name"] as? String else {
            return nil
        }

        let startTimeNano = parseNanoTimestamp(span["startTimeUnixNano"])
        let endTimeNano = parseNanoTimestamp(span["endTimeUnixNano"])
        let durationNano = endTimeNano - startTimeNano

        let statusCode: Int
        let statusMessage: String?
        if let status = span["status"] as? [String: Any] {
            statusCode = status["code"] as? Int ?? 0
            statusMessage = status["message"] as? String
        } else {
            statusCode = 0
            statusMessage = nil
        }

        let attributes: String?
        if let attrs = span["attributes"] as? [[String: Any]], !attrs.isEmpty {
            attributes = serializeJSON(flattenAttributes(attrs))
        } else {
            attributes = nil
        }

        let events: String?
        if let evts = span["events"] as? [[String: Any]], !evts.isEmpty {
            events = serializeJSON(evts)
        } else {
            events = nil
        }

        return SpanRecord(
            traceId: traceId,
            spanId: spanId,
            parentSpanId: span["parentSpanId"] as? String,
            operationName: name,
            serviceName: serviceName,
            spanKind: span["kind"] as? Int ?? 0,
            startTimeNano: startTimeNano,
            endTimeNano: endTimeNano,
            durationNano: durationNano,
            statusCode: statusCode,
            statusMessage: statusMessage,
            attributes: attributes,
            events: events,
            resourceAttrs: resourceAttrs
        )
    }

    // MARK: - Helpers

    /// OTLP spec encodes nanosecond timestamps as strings to avoid JSON integer precision loss.
    private static func parseNanoTimestamp(_ value: Any?) -> Int64 {
        if let str = value as? String {
            return Int64(str) ?? 0
        }
        if let num = value as? Int64 {
            return num
        }
        if let num = value as? NSNumber {
            return num.int64Value
        }
        return 0
    }

    /// Converts OTLP key/value attribute arrays into a flat dictionary for compact storage.
    private static func flattenAttributes(_ attributes: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for attr in attributes {
            guard let key = attr["key"] as? String,
                  let value = attr["value"] as? [String: Any] else { continue }

            if let v = value["stringValue"] as? String {
                result[key] = v
            } else if let v = value["intValue"] {
                // OTLP sends intValue as string
                if let str = v as? String {
                    result[key] = Int64(str) ?? str
                } else {
                    result[key] = v
                }
            } else if let v = value["doubleValue"] {
                result[key] = v
            } else if let v = value["boolValue"] {
                result[key] = v
            } else if let v = value["arrayValue"] as? [String: Any],
                      let values = v["values"] as? [[String: Any]] {
                result[key] = values
            } else if let v = value["kvlistValue"] as? [String: Any],
                      let values = v["values"] as? [[String: Any]] {
                result[key] = flattenAttributes(values)
            }
        }
        return result
    }

    private static func serializeJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
