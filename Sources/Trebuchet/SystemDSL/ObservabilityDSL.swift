// MARK: - Observability DSL

/// Protocol for observability configuration declarations.
///
/// Conforming types (``Log``, ``Metric``, ``Trace``) are composed
/// via ``ObservabilityBuilder`` inside a ``System``'s `observability` property.
public protocol ObservabilityConfiguration: Sendable {
    func collect(into config: inout ResolvedObservability)
}

/// The resolved observability configuration after collecting all declarations.
public struct ResolvedObservability: Sendable {
    public var logging: LoggingDeclaration?
    public var metrics: MetricsDeclaration?
    public var tracing: TracingDeclaration?

    public init(
        logging: LoggingDeclaration? = nil,
        metrics: MetricsDeclaration? = nil,
        tracing: TracingDeclaration? = nil
    ) {
        self.logging = logging
        self.metrics = metrics
        self.tracing = tracing
    }

    /// Merge another config on top, with `other` taking precedence for non-nil fields.
    public func merging(_ other: ResolvedObservability) -> ResolvedObservability {
        ResolvedObservability(
            logging: other.logging ?? logging,
            metrics: other.metrics ?? metrics,
            tracing: other.tracing ?? tracing
        )
    }
}

// MARK: - Declarations

public struct LoggingDeclaration: Sendable, Codable, Hashable {
    public var level: LoggingLevel
    public var format: LogFormat
    public var endpoint: String?
    public var authToken: String?

    public init(_ level: LoggingLevel = .info, format: LogFormat = .console, endpoint: String? = nil, authToken: String? = nil) {
        self.level = level
        self.format = format
        self.endpoint = endpoint
        self.authToken = authToken
    }
}

public enum LoggingLevel: String, Sendable, Codable, Hashable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public enum LogFormat: String, Sendable, Codable, Hashable {
    case console
    case json
}

public struct MetricsDeclaration: Sendable, Codable, Hashable {
    public var exporter: MetricsExporterType

    public init(exportTo exporter: MetricsExporterType = .inMemory) {
        self.exporter = exporter
    }
}

public enum MetricsExporterType: Sendable, Codable, Hashable {
    case inMemory
    case otlp(endpoint: String)
}

public struct TracingDeclaration: Sendable, Codable, Hashable {
    public var exporter: TracingExporterType

    public init(exportTo exporter: TracingExporterType = .console) {
        self.exporter = exporter
    }
}

public enum TracingExporterType: Sendable, Codable, Hashable {
    case console
    case otlp(endpoint: String, authToken: String? = nil)
}

// MARK: - DSL Types

/// Declare logging configuration in a System's observability block.
///
/// ```swift
/// var observability: some ObservabilityConfiguration {
///     Log(.info, format: .json)
/// }
/// ```
public struct Log: ObservabilityConfiguration {
    private let declaration: LoggingDeclaration

    public init(_ level: LoggingLevel = .info, format: LogFormat = .console, exportTo endpoint: String? = nil, authToken: String? = nil) {
        self.declaration = LoggingDeclaration(level, format: format, endpoint: endpoint, authToken: authToken)
    }

    public func collect(into config: inout ResolvedObservability) {
        config.logging = declaration
    }
}

/// Declare metrics collection in a System's observability block.
///
/// ```swift
/// var observability: some ObservabilityConfiguration {
///     Metric(exportTo: .otlp(endpoint: "localhost:4317"))
/// }
/// ```
public struct Metric: ObservabilityConfiguration {
    private let declaration: MetricsDeclaration

    public init(exportTo exporter: MetricsExporterType = .inMemory) {
        self.declaration = MetricsDeclaration(exportTo: exporter)
    }

    public func collect(into config: inout ResolvedObservability) {
        config.metrics = declaration
    }
}

/// Declare distributed tracing in a System's observability block.
///
/// ```swift
/// var observability: some ObservabilityConfiguration {
///     Trace(exportTo: .otlp(endpoint: "localhost:4317"))
/// }
/// ```
public struct Trace: ObservabilityConfiguration {
    private let declaration: TracingDeclaration

    public init(exportTo exporter: TracingExporterType = .console) {
        self.declaration = TracingDeclaration(exportTo: exporter)
    }

    public func collect(into config: inout ResolvedObservability) {
        config.tracing = declaration
    }
}

// MARK: - Type Erasure

public struct AnyObservability: ObservabilityConfiguration, Sendable {
    private let collectClosure: @Sendable (inout ResolvedObservability) -> Void

    public init(_ collectClosure: @escaping @Sendable (inout ResolvedObservability) -> Void) {
        self.collectClosure = collectClosure
    }

    public func collect(into config: inout ResolvedObservability) {
        collectClosure(&config)
    }
}

public struct EmptyObservability: ObservabilityConfiguration {
    public init() {}
    public func collect(into config: inout ResolvedObservability) {}
}

// MARK: - Result Builder

@resultBuilder
public enum ObservabilityBuilder {
    public static func buildExpression<O: ObservabilityConfiguration>(_ expression: O) -> AnyObservability {
        AnyObservability { config in
            expression.collect(into: &config)
        }
    }

    public static func buildBlock(_ components: AnyObservability...) -> AnyObservability {
        AnyObservability { config in
            for component in components {
                component.collect(into: &config)
            }
        }
    }

    public static func buildEither(first: AnyObservability) -> AnyObservability {
        first
    }

    public static func buildEither(second: AnyObservability) -> AnyObservability {
        second
    }

    public static func buildOptional(_ component: AnyObservability?) -> AnyObservability {
        component ?? AnyObservability { _ in }
    }

    public static func buildArray(_ components: [AnyObservability]) -> AnyObservability {
        AnyObservability { config in
            for component in components {
                component.collect(into: &config)
            }
        }
    }
}

// MARK: - Observability Descriptor (Codable, for deployment plans)

public struct ObservabilityDescriptor: Codable, Sendable, Hashable {
    public var logging: LoggingDeclaration?
    public var metrics: MetricsDeclaration?
    public var tracing: TracingDeclaration?

    public init(from resolved: ResolvedObservability) {
        self.logging = resolved.logging
        self.metrics = resolved.metrics
        self.tracing = resolved.tracing
    }
}
