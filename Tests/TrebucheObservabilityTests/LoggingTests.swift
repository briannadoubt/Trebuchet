// LoggingTests.swift
// Tests for structured logging infrastructure

import Testing
import Foundation
@testable import TrebucheObservability

/// Thread-safe message collector for testing
final class MessageCollector: @unchecked Sendable {
    private var messages: [String] = []
    private let lock = NSLock()

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func getMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        messages.removeAll()
    }
}

@Suite("Logging Tests")
struct LoggingTests {

    // MARK: - Log Level Tests

    @Test("Log level comparison")
    func testLogLevelComparison() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warning)
        #expect(LogLevel.warning < LogLevel.error)
        #expect(LogLevel.error < LogLevel.critical)
    }

    @Test("Log level filtering")
    func testLogLevelFiltering() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(level: .warning),
            output: { collector.append($0) }
        )

        await logger.debug("debug message")
        await logger.info("info message")
        await logger.warning("warning message")
        await logger.error("error message")

        let messages = collector.getMessages()
        #expect(messages.count == 2)
        #expect(messages[0].contains("warning message"))
        #expect(messages[1].contains("error message"))
    }

    // MARK: - Metadata Tests

    @Test("Metadata attachment")
    func testMetadataAttachment() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("test message", metadata: ["key1": "value1", "key2": "value2"])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(json.contains("\"key1\":\"value1\""))
        #expect(json.contains("\"key2\":\"value2\""))
    }

    @Test("Metadata inclusion control")
    func testMetadataInclusionControl() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(includeMetadata: false),
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("test message", metadata: ["key": "value"])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(!json.contains("\"metadata\""))
    }

    // MARK: - Sensitive Data Redaction Tests

    @Test("Sensitive data redaction")
    func testSensitiveDataRedaction() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(redactSensitiveData: true),
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("login attempt", metadata: [
            "username": "alice",
            "password": "super-secret",
            "token": "abc123"
        ])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(json.contains("\"username\":\"alice\""))
        #expect(json.contains("\"password\":\"[REDACTED]\""))
        #expect(json.contains("\"token\":\"[REDACTED]\""))
        #expect(!json.contains("super-secret"))
        #expect(!json.contains("abc123"))
    }

    @Test("Case-insensitive redaction")
    func testCaseInsensitiveRedaction() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(redactSensitiveData: true),
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("api call", metadata: [
            "apiKey": "key123",
            "ApiKeyValue": "key456",
            "AUTHORIZATION": "Bearer token"
        ])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(json.contains("[REDACTED]"))
        #expect(!json.contains("key123"))
        #expect(!json.contains("key456"))
        #expect(!json.contains("Bearer token"))
    }

    @Test("Redaction can be disabled")
    func testRedactionDisabled() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(redactSensitiveData: false),
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("test", metadata: ["password": "visible"])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(json.contains("\"password\":\"visible\""))
    }

    // MARK: - Correlation ID Tests

    @Test("Correlation ID propagation")
    func testCorrelationIDPropagation() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        let correlationID = UUID()
        await logger.info("test message", correlationID: correlationID)

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let json = messages[0]
        #expect(json.contains("\"correlation_id\":\"\(correlationID.uuidString)\""))
    }

    // MARK: - Formatter Tests

    @Test("JSON formatter output structure")
    func testJSONFormatterOutput() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test-logger",
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("test message", metadata: ["key": "value"])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let jsonData = messages[0].data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

        #expect(parsed["level"] as? String == "info")
        #expect(parsed["label"] as? String == "test-logger")
        #expect(parsed["message"] as? String == "test message")
        #expect((parsed["metadata"] as? [String: String])?["key"] == "value")
        #expect(parsed["timestamp"] != nil)
    }

    @Test("Console formatter output")
    func testConsoleFormatterOutput() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test-logger",
            formatter: ConsoleFormatter(),
            output: { collector.append($0) }
        )

        await logger.info("test message", metadata: ["key": "value"])

        let messages = collector.getMessages()
        #expect(messages.count == 1)
        let output = messages[0]
        #expect(output.contains("[INFO]"))
        #expect(output.contains("[test-logger]"))
        #expect(output.contains("test message"))
        #expect(output.contains("key=value"))
    }

    @Test("Console formatter with colors")
    func testConsoleFormatterColors() {
        let formatter = ConsoleFormatter(colorEnabled: true)
        let context = LogContext(label: "test")

        let debugOutput = formatter.format(level: .debug, message: "debug", context: context)
        #expect(debugOutput.contains("\u{001B}[0;36m")) // Cyan

        let errorOutput = formatter.format(level: .error, message: "error", context: context)
        #expect(errorOutput.contains("\u{001B}[0;31m")) // Red
    }

    // MARK: - Configuration Tests

    @Test("Default configuration")
    func testDefaultConfiguration() {
        let config = LoggingConfiguration.default
        #expect(config.level == .info)
        #expect(config.includeMetadata == true)
        #expect(config.redactSensitiveData == true)
        #expect(config.sensitiveKeys.contains("password"))
        #expect(config.sensitiveKeys.contains("token"))
    }

    @Test("Development configuration")
    func testDevelopmentConfiguration() {
        let config = LoggingConfiguration.development
        #expect(config.level == .debug)
        #expect(config.redactSensitiveData == false)
    }

    // MARK: - Convenience Methods Tests

    @Test("Convenience log methods")
    func testConvenienceMethods() async {
        let collector = MessageCollector()
        let logger = TrebucheLogger(
            label: "test",
            configuration: .init(level: .debug),
            formatter: JSONFormatter(),
            output: { collector.append($0) }
        )

        await logger.debug("debug msg")
        await logger.info("info msg")
        await logger.warning("warning msg")
        await logger.error("error msg")
        await logger.critical("critical msg")

        let messages = collector.getMessages()
        #expect(messages.count == 5)
        #expect(messages[0].contains("\"level\":\"debug\""))
        #expect(messages[1].contains("\"level\":\"info\""))
        #expect(messages[2].contains("\"level\":\"warning\""))
        #expect(messages[3].contains("\"level\":\"error\""))
        #expect(messages[4].contains("\"level\":\"critical\""))
    }
}
