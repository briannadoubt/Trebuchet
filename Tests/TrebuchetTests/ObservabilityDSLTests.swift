import Foundation
import Testing
@testable import Trebuchet

// MARK: - Test Systems

struct ObservableSystem: System {
    var topology: some Topology {
        SystemCats.self
            .expose(as: "cats")
        SystemDogs.self
            .expose(as: "dogs")
    }

    var observability: some ObservabilityConfiguration {
        Log(.info, format: .json)
        Metric(exportTo: .otlp(endpoint: "http://localhost:4318"))
        Trace(exportTo: .otlp(endpoint: "http://localhost:4318"))
    }
}

struct MinimalObservableSystem: System {
    var topology: some Topology {
        SystemCats.self
            .expose(as: "cats")
    }

    var observability: some ObservabilityConfiguration {
        Log(.debug)
    }
}

struct NoObservabilitySystem: System {
    var topology: some Topology {
        SystemCats.self
            .expose(as: "cats")
    }
}

struct PerActorObservabilitySystem: System {
    var topology: some Topology {
        SystemCats.self
            .expose(as: "cats")
            .observability {
                Log(.debug)
            }

        SystemDogs.self
            .expose(as: "dogs")
            .observability {
                Log(.error, format: .json)
                Trace(exportTo: .console)
            }
    }

    var observability: some ObservabilityConfiguration {
        Log(.info)
        Trace(exportTo: .otlp(endpoint: "http://localhost:4318"))
    }
}

// MARK: - Tests

@Suite("Observability DSL")
struct ObservabilityDSLTests {
    @Test("System-level observability collects all declarations")
    func systemLevelObservability() throws {
        let descriptor = try ObservableSystem.descriptor()
        _ = descriptor // System compiles and describes successfully

        // Verify by collecting the config directly
        let system = ObservableSystem()
        var config = ResolvedObservability()
        system.observability.collect(into: &config)

        #expect(config.logging?.level == .info)
        #expect(config.logging?.format == .json)
        #expect(config.metrics?.exporter == .otlp(endpoint: "http://localhost:4318"))
        #expect(config.tracing?.exporter == .otlp(endpoint: "http://localhost:4318"))
    }

    @Test("Minimal observability with only logging")
    func minimalObservability() {
        let system = MinimalObservableSystem()
        var config = ResolvedObservability()
        system.observability.collect(into: &config)

        #expect(config.logging?.level == .debug)
        #expect(config.logging?.format == .console)
        #expect(config.metrics == nil)
        #expect(config.tracing == nil)
    }

    @Test("System without observability uses empty default")
    func noObservability() throws {
        let system = NoObservabilitySystem()
        var config = ResolvedObservability()
        system.observability.collect(into: &config)

        #expect(config.logging == nil)
        #expect(config.metrics == nil)
        #expect(config.tracing == nil)

        // Should still describe and build correctly
        let descriptor = try NoObservabilitySystem.descriptor()
        #expect(descriptor.actors.count == 1)
    }

    @Test("Per-actor observability overrides appear in descriptors")
    func perActorObservability() throws {
        let descriptor = try PerActorObservabilitySystem.descriptor()

        let cats = descriptor.actors.first(where: { $0.exposeName == "cats" })
        let dogs = descriptor.actors.first(where: { $0.exposeName == "dogs" })

        #expect(cats?.observability?.logging?.level == .debug)
        #expect(cats?.observability?.tracing == nil) // Not overridden

        #expect(dogs?.observability?.logging?.level == .error)
        #expect(dogs?.observability?.logging?.format == .json)
        #expect(dogs?.observability?.tracing?.exporter == .console)
    }

    @Test("ResolvedObservability merging works correctly")
    func configMerging() {
        let base = ResolvedObservability(
            logging: LoggingDeclaration(.info, format: .console),
            metrics: MetricsDeclaration(exportTo: .inMemory),
            tracing: TracingDeclaration(exportTo: .otlp(endpoint: "http://localhost:4318"))
        )

        let override = ResolvedObservability(
            logging: LoggingDeclaration(.debug, format: .json)
        )

        let merged = base.merging(override)

        // Overridden
        #expect(merged.logging?.level == .debug)
        #expect(merged.logging?.format == .json)
        // Preserved from base
        #expect(merged.metrics?.exporter == .inMemory)
        #expect(merged.tracing?.exporter == .otlp(endpoint: "http://localhost:4318"))
    }

    @Test("ObservabilityBuilder supports conditionals")
    func conditionalObservability() {
        let isProduction = false

        @ObservabilityBuilder
        func buildConfig() -> some ObservabilityConfiguration {
            if isProduction {
                Log(.warning, format: .json)
            } else {
                Log(.debug)
            }
            Trace(exportTo: .console)
        }

        var config = ResolvedObservability()
        buildConfig().collect(into: &config)

        #expect(config.logging?.level == .debug)
        #expect(config.logging?.format == .console)
        #expect(config.tracing?.exporter == .console)
    }

    @Test("ObservabilityDescriptor round-trips through Codable")
    func descriptorCodable() throws {
        let original = ObservabilityDescriptor(from: ResolvedObservability(
            logging: LoggingDeclaration(.info, format: .json),
            metrics: MetricsDeclaration(exportTo: .otlp(endpoint: "http://localhost:4318")),
            tracing: TracingDeclaration(exportTo: .console)
        ))

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ObservabilityDescriptor.self, from: data)

        #expect(decoded.logging?.level == .info)
        #expect(decoded.logging?.format == .json)
        #expect(decoded.metrics?.exporter == .otlp(endpoint: "http://localhost:4318"))
        #expect(decoded.tracing?.exporter == .console)
    }

    @Test("Log, Metric, Trace DSL types collect correctly")
    func dslTypes() {
        var config = ResolvedObservability()

        Log(.warning, format: .json).collect(into: &config)
        #expect(config.logging?.level == .warning)

        Metric(exportTo: .otlp(endpoint: "http://otel:4318")).collect(into: &config)
        #expect(config.metrics?.exporter == .otlp(endpoint: "http://otel:4318"))

        Trace(exportTo: .console).collect(into: &config)
        #expect(config.tracing?.exporter == .console)
    }

    @Test("Default DSL values are sensible")
    func defaultValues() {
        var config = ResolvedObservability()

        Log().collect(into: &config)
        #expect(config.logging?.level == .info)
        #expect(config.logging?.format == .console)

        Metric().collect(into: &config)
        #expect(config.metrics?.exporter == .inMemory)

        Trace().collect(into: &config)
        #expect(config.tracing?.exporter == .console)
    }
}
