import Distributed
import Foundation

// MARK: - System API

public protocol System {
    associatedtype TopologyBody: Topology
    associatedtype DeploymentsBody: Deployments = EmptyDeployments
    associatedtype ObservabilityBody: ObservabilityConfiguration = EmptyObservability

    @TopologyBuilder
    var topology: TopologyBody { get }

    @DeploymentsBuilder
    var deployments: DeploymentsBody { get }

    /// Declare observability configuration for this system.
    ///
    /// The observability declaration automatically bootstraps swift-log,
    /// swift-metrics, and swift-distributed-tracing when the system starts.
    ///
    /// ```swift
    /// var observability: some ObservabilityConfiguration {
    ///     Log(.info, format: .json)
    ///     Metric(exportTo: .otlp(endpoint: "localhost:4318"))
    ///     Trace(exportTo: .otlp(endpoint: "localhost:4318"))
    /// }
    /// ```
    @ObservabilityBuilder
    var observability: ObservabilityBody { get }

    /// Create a state store from the topology's ``StateConfiguration``.
    ///
    /// Override this to provide persistence. Downstream modules like
    /// `TrebuchetSQLite` offer one-liner convenience methods:
    ///
    /// ```swift
    /// static func makeStateStore(
    ///     for config: StateConfiguration
    /// ) async throws -> (any Sendable)? {
    ///     try await Self.makeSQLiteStateStore(for: config)
    /// }
    /// ```
    ///
    /// The returned value is stored on the actor system and accessible via
    /// `actorSystem.stateStore` (when `TrebuchetCloud` is imported).
    static func makeStateStore(for config: StateConfiguration) async throws -> (any Sendable)?

    init()
}

public extension System {
    var deployments: EmptyDeployments {
        EmptyDeployments()
    }

    var observability: EmptyObservability {
        EmptyObservability()
    }

    static func makeStateStore(for config: StateConfiguration) async throws -> (any Sendable)? {
        nil
    }

    static func descriptor() throws -> SystemDescriptor {
        try TrebuchetSystemEntrypoint.describe(systemType: Self.self)
    }

    static func deploymentPlan(provider: String?, environment: String?) throws -> DeploymentPlan {
        let descriptor = try TrebuchetSystemEntrypoint.describe(systemType: Self.self)
        return descriptor.deploymentPlan(provider: provider, environment: environment)
    }

    static func main() async throws {
        try await TrebuchetSystemEntrypoint.run(systemType: Self.self)
    }
}

@available(*, deprecated, renamed: "System")
public typealias Service = System

// MARK: - Topology DSL

public protocol Topology {
    func collect(into collector: TopologyCollector, context: TopologyBuildContext)
}

public struct AnyTopology: Topology {
    private let collectorClosure: (TopologyCollector, TopologyBuildContext) -> Void

    public init(_ collectorClosure: @escaping (TopologyCollector, TopologyBuildContext) -> Void) {
        self.collectorClosure = collectorClosure
    }

    public func collect(into collector: TopologyCollector, context: TopologyBuildContext) {
        collectorClosure(collector, context)
    }

    private func applying(_ mutation: @escaping (inout InlineDeploymentMetadata) -> Void) -> AnyTopology {
        AnyTopology { collector, context in
            var next = context
            mutation(&next.metadata)
            self.collect(into: collector, context: next)
        }
    }

    public func expose(as name: String) -> AnyTopology {
        applying { $0.exposeName = name }
    }

    public func state(_ state: StateConfiguration) -> AnyTopology {
        applying { $0.state = state }
    }

    public func network(_ network: NetworkConfiguration) -> AnyTopology {
        applying { $0.network = network }
    }

    public func secrets(_ names: [String]) -> AnyTopology {
        applying { metadata in
            metadata.secrets = Array(Set(metadata.secrets).union(names)).sorted()
        }
    }

    public func deploy(_ hint: DeploymentHint) -> AnyTopology {
        applying { metadata in
            if var existing = metadata.deploymentHints[hint.provider] {
                existing.merge(from: hint)
                metadata.deploymentHints[hint.provider] = existing
            } else {
                metadata.deploymentHints[hint.provider] = hint
            }
        }
    }

    /// Override observability configuration for this specific actor.
    ///
    /// Per-actor overrides are merged on top of the system-level observability
    /// configuration. Only the fields you declare are overridden.
    ///
    /// ```swift
    /// GameRoom.self
    ///     .expose(as: "game-room")
    ///     .observability {
    ///         Log(.debug)  // debug logging just for this actor
    ///     }
    /// ```
    public func observability(@ObservabilityBuilder _ config: () -> some ObservabilityConfiguration) -> AnyTopology {
        let built = config()
        var resolved = ResolvedObservability()
        built.collect(into: &resolved)
        return applying { $0.observability = resolved }
    }
}

public extension Topology {
    func eraseToAnyTopology() -> AnyTopology {
        if let any = self as? AnyTopology {
            return any
        }
        return AnyTopology { collector, context in
            self.collect(into: collector, context: context)
        }
    }

    func expose(as name: String) -> AnyTopology {
        eraseToAnyTopology().expose(as: name)
    }

    func state(_ state: StateConfiguration) -> AnyTopology {
        eraseToAnyTopology().state(state)
    }

    func network(_ network: NetworkConfiguration) -> AnyTopology {
        eraseToAnyTopology().network(network)
    }

    func secrets(_ names: [String]) -> AnyTopology {
        eraseToAnyTopology().secrets(names)
    }

    func deploy(_ hint: DeploymentHint) -> AnyTopology {
        eraseToAnyTopology().deploy(hint)
    }

    func observability(@ObservabilityBuilder _ config: () -> some ObservabilityConfiguration) -> AnyTopology {
        eraseToAnyTopology().observability(config)
    }
}

public struct Cluster<Content: Topology>: Topology {
    public let name: String?
    private let content: Content

    public init(@TopologyBuilder _ content: () -> Content) {
        self.name = nil
        self.content = content()
    }

    public init(_ name: String, @TopologyBuilder _ content: () -> Content) {
        self.name = name
        self.content = content()
    }

    public func collect(into collector: TopologyCollector, context: TopologyBuildContext) {
        var next = context
        if let name {
            next.clusterPath.append(name)
        }
        content.collect(into: collector, context: next)
    }
}

struct DynamicActorDefinition: Sendable {
    let prefix: String
    let instantiateAndExpose: @Sendable (TrebuchetServer, TrebuchetActorID) async throws -> Void
}

private func actorExpression<A: TrebuchetActor>(
    _ actorType: A.Type,
    dynamicRegistration: DynamicActorDefinition? = nil
) -> AnyTopology {
    AnyTopology { collector, context in
        var next = context
        if let dynamicRegistration {
            next.metadata.dynamicRegistration = dynamicRegistration
        }
        collector.addActor(actorType, context: next)
    }
}

public extension TrebuchetActor {
    static func asTopology() -> AnyTopology {
        actorExpression(Self.self)
    }

    static func expose(as name: String) -> AnyTopology {
        asTopology().expose(as: name)
    }

    static func state(_ state: StateConfiguration) -> AnyTopology {
        asTopology().state(state)
    }

    static func network(_ network: NetworkConfiguration) -> AnyTopology {
        asTopology().network(network)
    }

    static func secrets(_ names: [String]) -> AnyTopology {
        asTopology().secrets(names)
    }

    static func deploy(_ hint: DeploymentHint) -> AnyTopology {
        asTopology().deploy(hint)
    }

    static func dynamic(
        prefix: String,
        _ factory: @escaping @Sendable (TrebuchetRuntime, String) async throws -> Self
    ) -> AnyTopology {
        actorExpression(
            Self.self,
            dynamicRegistration: DynamicActorDefinition(
                prefix: prefix,
                instantiateAndExpose: { server, actorID in
                    let actor = try await factory(server.actorSystem, actorID.id)
                    await server.expose(actor, as: actorID.id)
                }
            )
        )
    }
}

@resultBuilder
public enum TopologyBuilder {
    public static func buildExpression<T: Topology>(_ expression: T) -> AnyTopology {
        expression.eraseToAnyTopology()
    }

    public static func buildExpression<A: TrebuchetActor>(_ actorType: A.Type) -> AnyTopology {
        actorExpression(actorType)
    }

    public static func buildBlock(_ components: AnyTopology...) -> AnyTopology {
        AnyTopology { collector, context in
            for component in components {
                component.collect(into: collector, context: context)
            }
        }
    }

    public static func buildEither(first: AnyTopology) -> AnyTopology {
        first
    }

    public static func buildEither(second: AnyTopology) -> AnyTopology {
        second
    }

    public static func buildOptional(_ component: AnyTopology?) -> AnyTopology {
        component ?? AnyTopology { _, _ in }
    }

    public static func buildArray(_ components: [AnyTopology]) -> AnyTopology {
        AnyTopology { collector, context in
            for component in components {
                component.collect(into: collector, context: context)
            }
        }
    }
}

// MARK: - Deployments DSL

public protocol Deployments {
    func collect(into rules: inout [DeploymentRule], environment: String?)
}

public struct AnyDeployments: Deployments {
    private let collectClosure: (inout [DeploymentRule], String?) -> Void

    public init(_ collectClosure: @escaping (inout [DeploymentRule], String?) -> Void) {
        self.collectClosure = collectClosure
    }

    public func collect(into rules: inout [DeploymentRule], environment: String?) {
        collectClosure(&rules, environment)
    }
}

public struct EmptyDeployments: Deployments {
    public init() {}

    public func collect(into rules: inout [DeploymentRule], environment: String?) {
        _ = environment
    }
}

public struct DeploymentOverride: Deployments {
    public let selector: DeploymentSelector
    public var hints: [DeploymentHint]

    public init(selector: DeploymentSelector, hints: [DeploymentHint] = []) {
        self.selector = selector
        self.hints = hints
    }

    public func deploy(_ hint: DeploymentHint) -> DeploymentOverride {
        var next = self
        next.hints.append(hint)
        return next
    }

    public func collect(into rules: inout [DeploymentRule], environment: String?) {
        rules.append(DeploymentRule(environment: environment, selector: selector, hints: hints))
    }
}

public struct DeploymentEnvironment<Content: Deployments>: Deployments {
    public let name: String
    private let content: Content

    public init(_ name: String, @DeploymentsBuilder _ content: () -> Content) {
        self.name = name
        self.content = content()
    }

    public func collect(into rules: inout [DeploymentRule], environment: String?) {
        _ = environment
        content.collect(into: &rules, environment: name)
    }
}

public func Environment<Content: Deployments>(
    _ name: String,
    @DeploymentsBuilder _ content: () -> Content
) -> DeploymentEnvironment<Content> {
    DeploymentEnvironment(name, content)
}

public func ClusterSelector(_ name: String) -> DeploymentOverride {
    DeploymentOverride(selector: .cluster(name))
}

public func Actor(_ name: String) -> DeploymentOverride {
    DeploymentOverride(selector: .actor(name))
}

public var All: DeploymentOverride {
    DeploymentOverride(selector: .all)
}

@resultBuilder
public enum DeploymentsBuilder {
    public static func buildExpression<D: Deployments>(_ expression: D) -> AnyDeployments {
        AnyDeployments { rules, environment in
            expression.collect(into: &rules, environment: environment)
        }
    }

    public static func buildBlock(_ components: AnyDeployments...) -> AnyDeployments {
        AnyDeployments { rules, environment in
            for component in components {
                component.collect(into: &rules, environment: environment)
            }
        }
    }

    public static func buildEither(first: AnyDeployments) -> AnyDeployments {
        first
    }

    public static func buildEither(second: AnyDeployments) -> AnyDeployments {
        second
    }

    public static func buildOptional(_ component: AnyDeployments?) -> AnyDeployments {
        component ?? AnyDeployments { _, _ in }
    }

    public static func buildArray(_ components: [AnyDeployments]) -> AnyDeployments {
        AnyDeployments { rules, environment in
            for component in components {
                component.collect(into: &rules, environment: environment)
            }
        }
    }
}

// MARK: - Descriptor Types

public struct SystemDescriptor: Codable, Sendable {
    public var systemName: String
    public var actors: [ActorDescriptor]
    public var deploymentRules: [DeploymentRule]

    public init(systemName: String, actors: [ActorDescriptor], deploymentRules: [DeploymentRule]) {
        self.systemName = systemName
        self.actors = actors
        self.deploymentRules = deploymentRules
    }

    public func deploymentPlan(provider: String?, environment: String?) -> DeploymentPlan {
        let normalizedProvider = provider?.lowercased()
        var warnings: [String] = []
        var actorPlans: [DeploymentActorPlan] = []

        for actor in actors {
            var mergedByProvider: [String: DeploymentMergeState] = [:]
            for hint in actor.inlineDeploymentHints {
                mergedByProvider[hint.provider] = DeploymentMergeState(hint: hint, source: .inline)
            }

            for rule in deploymentRules {
                guard rule.matches(environment: environment, actor: actor) else { continue }
                for hint in rule.hints {
                    let key = hint.provider
                    if var existing = mergedByProvider[key] {
                        let conflicts = existing.hint.mergeFillingMissing(from: hint)
                        if existing.source == .inline {
                            for field in conflicts {
                                warnings.append("Inline deployment for actor '\(actor.exposeName)' overrides deployments block field '\(field)' for provider '\(key)'.")
                            }
                        }
                        mergedByProvider[key] = existing
                    } else {
                        mergedByProvider[key] = DeploymentMergeState(hint: hint, source: .deploymentBlock)
                    }
                }
            }

            let providerHints = mergedByProvider.values.map(\.hint)
            var aws = providerHints.first(where: { $0.provider == "aws" })?.aws
            var fly = providerHints.first(where: { $0.provider == "fly" })?.fly

            if let normalizedProvider {
                switch normalizedProvider {
                case "aws":
                    fly = nil
                case "fly":
                    aws = nil
                default:
                    break
                }
            }

            actorPlans.append(DeploymentActorPlan(
                actorType: actor.actorType,
                exposeName: actor.exposeName,
                clusterPath: actor.clusterPath,
                state: actor.state,
                network: actor.network,
                secrets: actor.secrets,
                aws: aws,
                fly: fly
            ))
        }

        return DeploymentPlan(
            systemName: systemName,
            provider: normalizedProvider,
            environment: environment,
            actors: actorPlans,
            warnings: warnings
        )
    }
}

public struct ActorDescriptor: Codable, Sendable, Hashable {
    public var actorType: String
    public var exposeName: String
    public var clusterPath: [String]
    public var state: StateConfiguration?
    public var network: NetworkConfiguration?
    public var secrets: [String]
    public var inlineDeploymentHints: [DeploymentHint]
    public var observability: ObservabilityDescriptor?

    public init(
        actorType: String,
        exposeName: String,
        clusterPath: [String],
        state: StateConfiguration?,
        network: NetworkConfiguration?,
        secrets: [String],
        inlineDeploymentHints: [DeploymentHint],
        observability: ObservabilityDescriptor? = nil
    ) {
        self.actorType = actorType
        self.exposeName = exposeName
        self.clusterPath = clusterPath
        self.state = state
        self.network = network
        self.secrets = secrets
        self.inlineDeploymentHints = inlineDeploymentHints
        self.observability = observability
    }

    public var shortActorName: String {
        actorType.split(separator: ".").last.map(String.init) ?? actorType
    }
}

public struct DeploymentPlan: Codable, Sendable {
    public var systemName: String
    public var provider: String?
    public var environment: String?
    public var actors: [DeploymentActorPlan]
    public var warnings: [String]

    public init(
        systemName: String,
        provider: String?,
        environment: String?,
        actors: [DeploymentActorPlan],
        warnings: [String]
    ) {
        self.systemName = systemName
        self.provider = provider
        self.environment = environment
        self.actors = actors
        self.warnings = warnings
    }
}

public struct DeploymentActorPlan: Codable, Sendable {
    public var actorType: String
    public var exposeName: String
    public var clusterPath: [String]
    public var state: StateConfiguration?
    public var network: NetworkConfiguration?
    public var secrets: [String]
    public var aws: AWSDeploymentOptions?
    public var fly: FlyDeploymentOptions?

    public init(
        actorType: String,
        exposeName: String,
        clusterPath: [String],
        state: StateConfiguration?,
        network: NetworkConfiguration?,
        secrets: [String],
        aws: AWSDeploymentOptions?,
        fly: FlyDeploymentOptions?
    ) {
        self.actorType = actorType
        self.exposeName = exposeName
        self.clusterPath = clusterPath
        self.state = state
        self.network = network
        self.secrets = secrets
        self.aws = aws
        self.fly = fly
    }
}

public struct DeploymentRule: Codable, Sendable, Hashable {
    public var environment: String?
    public var selector: DeploymentSelector
    public var hints: [DeploymentHint]

    public init(environment: String?, selector: DeploymentSelector, hints: [DeploymentHint]) {
        self.environment = environment
        self.selector = selector
        self.hints = hints
    }

    func matches(environment selectedEnvironment: String?, actor: ActorDescriptor) -> Bool {
        if let environment, environment != selectedEnvironment {
            return false
        }
        return selector.matches(actor: actor)
    }
}

public enum DeploymentSelector: Codable, Sendable, Hashable {
    case all
    case cluster(String)
    case actor(String)

    func matches(actor: ActorDescriptor) -> Bool {
        switch self {
        case .all:
            return true
        case .cluster(let name):
            return actor.clusterPath.contains(name)
        case .actor(let name):
            return actor.shortActorName == name || actor.exposeName == name || actor.actorType == name
        }
    }

    fileprivate var diagnosticDescription: String {
        switch self {
        case .all:
            return "All"
        case .cluster(let name):
            return "ClusterSelector(\"\(name)\")"
        case .actor(let name):
            return "Actor(\"\(name)\")"
        }
    }
}

public struct DeploymentHint: Codable, Sendable, Hashable {
    public var provider: String
    public var aws: AWSDeploymentOptions?
    public var fly: FlyDeploymentOptions?

    public init(provider: String, aws: AWSDeploymentOptions? = nil, fly: FlyDeploymentOptions? = nil) {
        self.provider = provider.lowercased()
        self.aws = aws
        self.fly = fly
    }

    public static func aws(
        region: String? = nil,
        lambda: AWSLambdaOptions? = nil,
        apiGateway: AWSAPIGatewayMode? = nil,
        websocketGateway: AWSWebSocketGatewayMode? = nil
    ) -> DeploymentHint {
        DeploymentHint(
            provider: "aws",
            aws: AWSDeploymentOptions(
                region: region,
                memory: lambda?.memory,
                timeout: lambda?.timeout,
                reservedConcurrency: lambda?.reservedConcurrency,
                apiGateway: apiGateway,
                websocketGateway: websocketGateway
            )
        )
    }

    public static func fly(
        app: String? = nil,
        region: String? = nil,
        machine: FlyMachineOptions? = nil,
        healthCheck: String? = nil
    ) -> DeploymentHint {
        DeploymentHint(
            provider: "fly",
            fly: FlyDeploymentOptions(
                app: app,
                region: region,
                memoryMB: machine?.memoryMB,
                min: machine?.min,
                max: machine?.max,
                healthCheck: healthCheck
            )
        )
    }

    mutating func merge(from other: DeploymentHint) {
        _ = mergeFillingMissing(from: other)
    }

    mutating func mergeFillingMissing(from other: DeploymentHint) -> [String] {
        guard provider == other.provider else { return [] }

        switch provider {
        case "aws":
            var conflicts: [String] = []
            var lhs = aws ?? AWSDeploymentOptions()
            let rhs = other.aws ?? AWSDeploymentOptions()
            lhs.merge(from: rhs, conflicts: &conflicts)
            aws = lhs
            return conflicts
        case "fly":
            var conflicts: [String] = []
            var lhs = fly ?? FlyDeploymentOptions()
            let rhs = other.fly ?? FlyDeploymentOptions()
            lhs.merge(from: rhs, conflicts: &conflicts)
            fly = lhs
            return conflicts
        default:
            return []
        }
    }
}

public struct AWSLambdaOptions: Codable, Sendable, Hashable {
    public var memory: Int?
    public var timeout: Int?
    public var reservedConcurrency: Int?

    public init(memory: Int? = nil, timeout: Int? = nil, reservedConcurrency: Int? = nil) {
        self.memory = memory
        self.timeout = timeout
        self.reservedConcurrency = reservedConcurrency
    }
}

public struct AWSDeploymentOptions: Codable, Sendable, Hashable {
    public var region: String?
    public var memory: Int?
    public var timeout: Int?
    public var reservedConcurrency: Int?
    public var apiGateway: AWSAPIGatewayMode?
    public var websocketGateway: AWSWebSocketGatewayMode?

    public init(
        region: String? = nil,
        memory: Int? = nil,
        timeout: Int? = nil,
        reservedConcurrency: Int? = nil,
        apiGateway: AWSAPIGatewayMode? = nil,
        websocketGateway: AWSWebSocketGatewayMode? = nil
    ) {
        self.region = region
        self.memory = memory
        self.timeout = timeout
        self.reservedConcurrency = reservedConcurrency
        self.apiGateway = apiGateway
        self.websocketGateway = websocketGateway
    }

    mutating func merge(from other: AWSDeploymentOptions, conflicts: inout [String]) {
        mergeField(current: &region, incoming: other.region, field: "region", conflicts: &conflicts)
        mergeField(current: &memory, incoming: other.memory, field: "memory", conflicts: &conflicts)
        mergeField(current: &timeout, incoming: other.timeout, field: "timeout", conflicts: &conflicts)
        mergeField(current: &reservedConcurrency, incoming: other.reservedConcurrency, field: "reservedConcurrency", conflicts: &conflicts)
        mergeField(current: &apiGateway, incoming: other.apiGateway, field: "apiGateway", conflicts: &conflicts)
        mergeField(current: &websocketGateway, incoming: other.websocketGateway, field: "websocketGateway", conflicts: &conflicts)
    }
}

public enum AWSAPIGatewayMode: String, Codable, Sendable, Hashable {
    case http
    case disabled
}

public enum AWSWebSocketGatewayMode: String, Codable, Sendable, Hashable {
    case enabled
    case disabled
}

public struct FlyMachineOptions: Codable, Sendable, Hashable {
    public var memoryMB: Int?
    public var min: Int?
    public var max: Int?

    public init(memoryMB: Int? = nil, min: Int? = nil, max: Int? = nil) {
        self.memoryMB = memoryMB
        self.min = min
        self.max = max
    }
}

public struct FlyDeploymentOptions: Codable, Sendable, Hashable {
    public var app: String?
    public var region: String?
    public var memoryMB: Int?
    public var min: Int?
    public var max: Int?
    public var healthCheck: String?

    public init(
        app: String? = nil,
        region: String? = nil,
        memoryMB: Int? = nil,
        min: Int? = nil,
        max: Int? = nil,
        healthCheck: String? = nil
    ) {
        self.app = app
        self.region = region
        self.memoryMB = memoryMB
        self.min = min
        self.max = max
        self.healthCheck = healthCheck
    }

    mutating func merge(from other: FlyDeploymentOptions, conflicts: inout [String]) {
        mergeField(current: &app, incoming: other.app, field: "app", conflicts: &conflicts)
        mergeField(current: &region, incoming: other.region, field: "region", conflicts: &conflicts)
        mergeField(current: &memoryMB, incoming: other.memoryMB, field: "memoryMB", conflicts: &conflicts)
        mergeField(current: &min, incoming: other.min, field: "min", conflicts: &conflicts)
        mergeField(current: &max, incoming: other.max, field: "max", conflicts: &conflicts)
        mergeField(current: &healthCheck, incoming: other.healthCheck, field: "healthCheck", conflicts: &conflicts)
    }
}

public enum StateConfiguration: Codable, Sendable, Hashable {
    case memory
    case dynamoDB(table: String)
    case postgres(databaseURL: String?)
    case surrealDB(url: String?)
    case sqlite(path: String? = nil, shards: Int = 1)
}

public enum NetworkConfiguration: Codable, Sendable, Hashable {
    case `public`
    case `private`(vpc: String, subnets: [String])
}

// MARK: - Runtime Entrypoint

enum TrebuchetSystemEntrypoint {
    static func describe<S: System>(systemType: S.Type) throws -> SystemDescriptor {
        let system = systemType.init()
        return try buildGraph(for: system).descriptor
    }

    static func run<S: System>(systemType: S.Type) async throws {
        let options = TrebuchetSystemOptions(arguments: CommandLine.arguments)
        let system = systemType.init()
        let graph = try buildGraph(for: system)

        switch options.mode {
        case .descriptor:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(graph.descriptor)
            FileHandle.standardOutput.write(data)
        case .plan:
            let plan = graph.descriptor.deploymentPlan(provider: options.provider, environment: options.environment)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(plan)
            FileHandle.standardOutput.write(data)
        case .dev, .run:
            let host = options.host ?? ProcessInfo.processInfo.environment["TREBUCHET_HOST"] ?? "127.0.0.1"
            let port = options.port ?? UInt16(ProcessInfo.processInfo.environment["TREBUCHET_PORT"] ?? "8080") ?? 8080
            try await runDev(graph: graph, systemType: systemType, host: host, port: port)
        }
    }

    private static func runDev<S: System>(graph: BuiltSystemGraph, systemType: S.Type, host: String, port: UInt16) async throws {
        // Bootstrap observability before anything else
        #if !os(WASI)
        ObservabilityBootstrap.apply(graph.observabilityConfig, serviceName: graph.descriptor.systemName)
        #endif

        let server = TrebuchetServer(transport: .webSocket(host: host, port: port))

        // Resolve state store from topology configuration
        if let config = graph.stateConfig {
            if let store = try await S.makeStateStore(for: config) {
                server.actorSystem._stateStoreBox = store
            }
        }

        if !graph.dynamicRegistrations.isEmpty {
            let dynamicRegistrations = graph.dynamicRegistrations
            server.onActorRequest = { actorID in
                guard let registration = dynamicRegistrations.first(where: { actorID.id.hasPrefix($0.prefix) }) else {
                    return
                }
                try await registration.instantiateAndExpose(server, actorID)
            }
        }

        for registration in graph.runtimeRegistrations {
            try await registration.expose(server, registration.exposeName)
        }

        print("Trebuchet System running on ws://\(host):\(port)")
        try await server.run()
    }

    private static func buildGraph<S: System>(for system: S) throws -> BuiltSystemGraph {
        let collector = TopologyCollector()
        let rootContext = TopologyBuildContext()
        system.topology.collect(into: collector, context: rootContext)

        var rules: [DeploymentRule] = []
        system.deployments.collect(into: &rules, environment: nil)

        // Collect system-level observability configuration
        var observabilityConfig = ResolvedObservability()
        system.observability.collect(into: &observabilityConfig)

        var diagnostics = collector.diagnostics
        diagnostics.append(contentsOf: deploymentRuleDiagnostics(rules: rules, actors: collector.descriptors))

        if !diagnostics.isEmpty {
            throw TrebuchetError.invalidConfiguration(diagnostics.joined(separator: "\n"))
        }

        let descriptor = SystemDescriptor(
            systemName: String(describing: S.self),
            actors: collector.descriptors,
            deploymentRules: rules
        )

        // Extract the state configuration from the topology (use the first one found)
        let stateConfig = collector.descriptors.compactMap(\.state).first

        return BuiltSystemGraph(
            descriptor: descriptor,
            runtimeRegistrations: collector.runtimeRegistrations,
            dynamicRegistrations: collector.dynamicRegistrations,
            stateConfig: stateConfig,
            observabilityConfig: observabilityConfig
        )
    }

    private static func deploymentRuleDiagnostics(
        rules: [DeploymentRule],
        actors: [ActorDescriptor]
    ) -> [String] {
        var diagnostics: [String] = []

        for rule in rules {
            if rule.selector == .all {
                continue
            }

            let hasMatch = actors.contains { rule.selector.matches(actor: $0) }
            guard !hasMatch else { continue }

            let envContext = rule.environment.map { " in environment '\($0)'" } ?? ""
            diagnostics.append(
                "Deployment selector '\(rule.selector.diagnosticDescription)' matched no actors\(envContext)."
            )
        }

        return diagnostics
    }
}

private enum TrebuchetMode: String {
    case run
    case dev
    case descriptor
    case plan
}

private struct TrebuchetSystemOptions {
    var mode: TrebuchetMode = .run
    var host: String?
    var port: UInt16?
    var provider: String?
    var environment: String?

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--_trebuchet-mode":
                if index + 1 < arguments.count, let parsed = TrebuchetMode(rawValue: arguments[index + 1]) {
                    mode = parsed
                    index += 1
                }
            case "--_trebuchet-host":
                if index + 1 < arguments.count {
                    host = arguments[index + 1]
                    index += 1
                }
            case "--_trebuchet-port":
                if index + 1 < arguments.count {
                    port = UInt16(arguments[index + 1])
                    index += 1
                }
            case "--_trebuchet-provider":
                if index + 1 < arguments.count {
                    provider = arguments[index + 1].lowercased()
                    index += 1
                }
            case "--_trebuchet-environment":
                if index + 1 < arguments.count {
                    environment = arguments[index + 1]
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
    }
}

// MARK: - Internal Collectors

public struct TopologyBuildContext {
    var clusterPath: [String] = []
    var metadata = InlineDeploymentMetadata()
}

public final class TopologyCollector {
    fileprivate var runtimeRegistrations: [RuntimeActorRegistration] = []
    fileprivate var dynamicRegistrations: [RuntimeDynamicRegistration] = []
    fileprivate var descriptors: [ActorDescriptor] = []
    fileprivate var seenExposeNames: Set<String> = []
    fileprivate var seenDynamicPrefixes: Set<String> = []
    fileprivate var diagnostics: [String] = []

    fileprivate init() {}

    fileprivate func addActor<A: TrebuchetActor>(_ actorType: A.Type, context: TopologyBuildContext) {
        let actorTypeName = String(reflecting: actorType)
        let shortName = actorTypeName.split(separator: ".").last.map(String.init) ?? actorTypeName
        let inferredExpose = shortName.prefix(1).lowercased() + shortName.dropFirst()
        let exposeName = context.metadata.exposeName ?? inferredExpose

        if seenExposeNames.contains(exposeName) {
            diagnostics.append("Duplicate actor expose name detected: '\(exposeName)'.")
            return
        }

        seenExposeNames.insert(exposeName)

        if let dynamicRegistration = context.metadata.dynamicRegistration {
            if dynamicRegistration.prefix.isEmpty {
                diagnostics.append("Dynamic actor prefix cannot be empty for actor expose '\(exposeName)'.")
                return
            }

            if seenDynamicPrefixes.contains(dynamicRegistration.prefix) {
                diagnostics.append("Duplicate dynamic actor prefix detected: '\(dynamicRegistration.prefix)'.")
                return
            }

            seenDynamicPrefixes.insert(dynamicRegistration.prefix)
            dynamicRegistrations.append(RuntimeDynamicRegistration(
                prefix: dynamicRegistration.prefix,
                actorType: actorTypeName,
                instantiateAndExpose: dynamicRegistration.instantiateAndExpose
            ))
        }

        let descriptor = ActorDescriptor(
            actorType: actorTypeName,
            exposeName: exposeName,
            clusterPath: context.clusterPath,
            state: context.metadata.state,
            network: context.metadata.network,
            secrets: context.metadata.secrets.sorted(),
            inlineDeploymentHints: context.metadata.deploymentHints.values.sorted { $0.provider < $1.provider },
            observability: context.metadata.observability.map { ObservabilityDescriptor(from: $0) }
        )

        descriptors.append(descriptor)
        runtimeRegistrations.append(RuntimeActorRegistration(
            actorType: actorType,
            exposeName: exposeName
        ))
    }
}

struct InlineDeploymentMetadata {
    var exposeName: String?
    var state: StateConfiguration?
    var network: NetworkConfiguration?
    var secrets: [String] = []
    var deploymentHints: [String: DeploymentHint] = [:]
    var dynamicRegistration: DynamicActorDefinition?
    var observability: ResolvedObservability?
}

private struct RuntimeActorRegistration {
    let exposeName: String
    let expose: (TrebuchetServer, String) async throws -> Void

    init<A: TrebuchetActor>(actorType: A.Type, exposeName: String) {
        self.exposeName = exposeName
        self.expose = { server, resolvedName in
            let actor = A(actorSystem: server.actorSystem)
            await server.expose(actor, as: resolvedName)
        }
    }
}

private struct RuntimeDynamicRegistration: Sendable {
    let prefix: String
    let actorType: String
    let instantiateAndExpose: @Sendable (TrebuchetServer, TrebuchetActorID) async throws -> Void
}

private struct BuiltSystemGraph {
    let descriptor: SystemDescriptor
    let runtimeRegistrations: [RuntimeActorRegistration]
    let dynamicRegistrations: [RuntimeDynamicRegistration]
    let stateConfig: StateConfiguration?
    let observabilityConfig: ResolvedObservability
}

private enum DeploymentRuleSource {
    case inline
    case deploymentBlock
}

private struct DeploymentMergeState {
    var hint: DeploymentHint
    var source: DeploymentRuleSource
}

private func mergeField<Value: Equatable>(
    current: inout Value?,
    incoming: Value?,
    field: String,
    conflicts: inout [String]
) {
    guard let incoming else { return }
    if current == nil {
        current = incoming
        return
    }
    if current != incoming {
        conflicts.append(field)
    }
}
