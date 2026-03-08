import Foundation

/// Minimal compose representation used by Trebuchet CLI without a hard CompoteCore dependency.
public struct ComposeFile: Sendable, Encodable {
    public let version: String
    public let services: [String: Service]
    public let volumes: [String: Volume]?

    public init(version: String, services: [String: Service], volumes: [String: Volume]? = nil) {
        self.version = version
        self.services = services
        self.volumes = volumes
    }
}

public struct Service: Sendable, Encodable {
    public let image: String?
    public let container_name: String?
    public let command: Command?
    public let environment: Environment?
    public let ports: [String]?
    public let volumes: [String]?
    public let healthcheck: HealthCheck?
    public let restart: String?

    public init(
        image: String?,
        container_name: String? = nil,
        command: Command? = nil,
        environment: Environment? = nil,
        ports: [String]? = nil,
        volumes: [String]? = nil,
        healthcheck: HealthCheck? = nil,
        restart: String? = nil
    ) {
        self.image = image
        self.container_name = container_name
        self.command = command
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.healthcheck = healthcheck
        self.restart = restart
    }
}

public struct Volume: Sendable, Encodable {
    public let driver: String?

    public init(driver: String? = nil) {
        self.driver = driver
    }
}

public struct HealthCheck: Sendable, Encodable {
    public let test: Command
    public let interval: String?
    public let timeout: String?
    public let retries: Int?

    public init(test: Command, interval: String? = nil, timeout: String? = nil, retries: Int? = nil) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
    }
}

public enum Command: Sendable, Encodable {
    case array([String])
    case string(String)

    var asArray: [String]? {
        switch self {
        case .array(let values):
            return values
        case .string(let value):
            return [value]
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}

public enum Environment: Sendable, Encodable {
    case dictionary([String: String])
    case array([String])

    var asDictionary: [String: String]? {
        switch self {
        case .dictionary(let dict):
            return dict
        case .array(let array):
            var dict: [String: String] = [:]
            for item in array {
                let parts = item.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                }
            }
            return dict
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .dictionary(let dictionary):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in dictionary {
                guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                try container.encode(value, forKey: codingKey)
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Generates compose-compatible service descriptions from Trebuchet configuration.
public struct ComposeFileGenerator {
    private let config: TrebuchetConfig

    public init(config: TrebuchetConfig) {
        self.config = config
    }

    /// Generate a ComposeFile from TrebuchetConfig.
    public func generate() -> ComposeFile {
        var services: [String: Service] = [:]
        var volumes: [String: Volume] = [:]

        if let stateType = config.state?.type.lowercased() {
            switch stateType {
            case "surrealdb":
                services["surrealdb"] = createSurrealDBService()
                volumes["surrealdb-data"] = Volume(driver: "local")

            case "postgresql":
                services["postgresql"] = createPostgreSQLService()
                volumes["postgres-data"] = Volume(driver: "local")

            case "dynamodb":
                services["localstack"] = createLocalStackService()

            default:
                break
            }
        }

        if let dependencies = config.dependencies {
            for dep in dependencies {
                services[dep.name] = createCustomService(from: dep)

                if let depVolumes = dep.volumes {
                    for volumeSpec in depVolumes {
                        let parts = volumeSpec.split(separator: ":")
                        if let first = parts.first {
                            volumes[String(first)] = Volume(driver: "local")
                        }
                    }
                }
            }
        }

        return ComposeFile(
            version: "3.8",
            services: services,
            volumes: volumes.isEmpty ? nil : volumes
        )
    }

    private func createSurrealDBService() -> Service {
        Service(
            image: "surrealdb/surrealdb:latest",
            container_name: "\(config.name)-surrealdb",
            command: .array(["start", "--log", "info", "--user", "root", "--pass", "root", "memory"]),
            ports: ["8000:8000"],
            volumes: ["surrealdb-data:/data"],
            healthcheck: HealthCheck(
                test: .array(["CMD", "curl", "-f", "http://localhost:8000/health"]),
                interval: "10s",
                timeout: "5s",
                retries: 5
            ),
            restart: "unless-stopped"
        )
    }

    private func createPostgreSQLService() -> Service {
        let dbName = config.state?.tableName ?? "\(config.name)_dev"

        return Service(
            image: "postgres:16-alpine",
            container_name: "\(config.name)-postgresql",
            environment: .dictionary([
                "POSTGRES_USER": "trebuchet",
                "POSTGRES_PASSWORD": "trebuchet",
                "POSTGRES_DB": dbName
            ]),
            ports: ["5432:5432"],
            volumes: ["postgres-data:/var/lib/postgresql/data"],
            healthcheck: HealthCheck(
                test: .array(["CMD", "pg_isready", "-U", "trebuchet"]),
                interval: "10s",
                timeout: "5s",
                retries: 5
            ),
            restart: "unless-stopped"
        )
    }

    private func createLocalStackService() -> Service {
        Service(
            image: "localstack/localstack:3.0",
            container_name: "\(config.name)-localstack",
            environment: .dictionary([
                "SERVICES": "dynamodb,dynamodbstreams,cloudmap,iam,lambda,apigateway",
                "DEFAULT_REGION": "us-east-1"
            ]),
            ports: ["4566:4566"],
            healthcheck: HealthCheck(
                test: .array(["CMD", "curl", "-f", "http://localhost:4566/_localstack/health"]),
                interval: "10s",
                timeout: "5s",
                retries: 10
            ),
            restart: "unless-stopped"
        )
    }

    private func createCustomService(from dep: DependencyConfig) -> Service {
        var environment: Environment?
        if let env = dep.environment {
            environment = .dictionary(env)
        }

        var command: Command?
        if let cmd = dep.command {
            command = .array(cmd)
        }

        var healthcheck: HealthCheck?
        if let hc = dep.healthcheck {
            if let url = hc.url {
                healthcheck = HealthCheck(
                    test: .array(["CMD", "curl", "-f", url]),
                    interval: "\(hc.interval ?? 10)s",
                    timeout: "5s",
                    retries: hc.retries ?? 10
                )
            } else if let port = hc.port {
                healthcheck = HealthCheck(
                    test: .array(["CMD", "nc", "-z", "localhost", "\(port)"]),
                    interval: "\(hc.interval ?? 10)s",
                    timeout: "5s",
                    retries: hc.retries ?? 10
                )
            }
        }

        return Service(
            image: dep.image,
            container_name: "\(config.name)-\(dep.name)",
            command: command,
            environment: environment,
            ports: dep.ports,
            volumes: dep.volumes,
            healthcheck: healthcheck,
            restart: "unless-stopped"
        )
    }
}
