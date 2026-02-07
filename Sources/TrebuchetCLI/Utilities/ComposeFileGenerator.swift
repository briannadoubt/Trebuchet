#if os(macOS)
import Foundation
import CompoteCore

/// Generates Compote compose files from Trebuchet configuration
public struct ComposeFileGenerator {
    private let config: TrebuchetConfig

    public init(config: TrebuchetConfig) {
        self.config = config
    }

    /// Generate a ComposeFile from TrebuchetConfig
    public func generate() -> ComposeFile {
        var services: [String: Service] = [:]
        var volumes: [String: Volume] = [:]

        // Add services based on state store type
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

        // Add custom dependencies from config
        if let dependencies = config.dependencies {
            for dep in dependencies {
                services[dep.name] = createCustomService(from: dep)

                // Add volumes if specified
                if let depVolumes = dep.volumes {
                    for volumeSpec in depVolumes {
                        // Parse "volume-name:/path" format
                        let parts = volumeSpec.split(separator: ":")
                        if parts.count >= 1 {
                            let volumeName = String(parts[0])
                            volumes[volumeName] = Volume(driver: "local")
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

    // MARK: - Service Creators

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
        // Convert dependency config to service
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
#endif
