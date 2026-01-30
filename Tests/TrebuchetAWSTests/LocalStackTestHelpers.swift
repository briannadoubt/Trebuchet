import Foundation
import SotoCore
import SotoDynamoDB
import SotoServiceDiscovery
import SotoLambda
@testable import TrebuchetAWS

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helper utilities for LocalStack-based integration tests
enum LocalStackTestHelpers {
    /// LocalStack endpoint URL
    static let endpoint = "http://localhost:4566"

    /// Check if LocalStack is available and healthy
    static func isLocalStackAvailable() async -> Bool {
        // First check if LocalStack health endpoint is reachable
        guard let url = URL(string: "\(endpoint)/_localstack/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
        } catch {
            return false
        }

        // Actually verify DynamoDB is working by trying to list tables
        // This ensures LocalStack is not just running, but actually functional
        do {
            let client = createAWSClient()
            defer {
                Task {
                    try? await client.shutdown()
                }
            }

            let dynamodb = DynamoDB(client: client, region: .useast1, endpoint: endpoint)
            _ = try await dynamodb.listTables(.init())

            // If we can list tables, DynamoDB is working
            return true
        } catch {
            // DynamoDB not ready or not working
            return false
        }
    }

    /// Check if ServiceDiscovery (Cloud Map) is available
    /// Note: Requires LocalStack Pro, not available in Community Edition
    static func isServiceDiscoveryAvailable() async -> Bool {
        guard let url = URL(string: "\(endpoint)/_localstack/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let services = json["services"] as? [String: Any] {
                // Check if servicediscovery is actually running (not just present)
                return (services["servicediscovery"] as? String) == "running" ||
                       (services["servicediscovery"] as? String) == "available"
            }

            return false
        } catch {
            return false
        }
    }

    /// Create an AWS client configured for LocalStack
    static func createAWSClient() -> AWSClient {
        return AWSClient(
            credentialProvider: .static(
                accessKeyId: "test",
                secretAccessKey: "test"
            )
        )
    }

    /// Create a DynamoDB state store for testing
    static func createStateStore(tableName: String = "trebuchet-test-state", client: AWSClient) -> DynamoDBStateStore {
        return DynamoDBStateStore(
            tableName: tableName,
            region: .useast1,
            endpoint: endpoint,
            awsClient: client
        )
    }

    /// Create a Cloud Map registry for testing
    static func createRegistry(namespace: String = "trebuchet-test", client: AWSClient) async throws -> CloudMapRegistry {
        let registry = CloudMapRegistry(
            namespace: namespace,
            region: .useast1,
            endpoint: endpoint,
            awsClient: client
        )

        // Note: Skipping waitForNamespace - LocalStack Community doesn't support ServiceDiscovery
        // try await waitForNamespace(namespace: namespace, client: client)

        return registry
    }

    /// Create an AWS provider for testing
    static func createProvider(
        tableName: String = "trebuchet-test-state",
        namespace: String = "trebuchet-test"
    ) async throws -> AWSProvider {
        let client = createAWSClient()

        // Wait for resources to be available
        try await waitForTable(tableName: tableName, client: client)
        try await waitForNamespace(namespace: namespace, client: client)

        return AWSProvider(
            region: "us-east-1",
            awsClient: client
        )
    }

    /// Clean up test data from a DynamoDB table
    static func cleanupTable(_ tableName: String, client: AWSClient) async throws {
        let dynamodb = DynamoDB(client: client, region: .useast1, endpoint: endpoint)

        // Scan and delete all items
        let scanOutput = try await dynamodb.scan(.init(tableName: tableName))

        guard let items = scanOutput.items, !items.isEmpty else {
            return
        }

        for item in items {
            guard let actorIdAttr = item["actorId"],
                  case .s(let actorId) = actorIdAttr else { continue }

            try await dynamodb.deleteItem(.init(
                key: ["actorId": .s(actorId)],
                tableName: tableName
            ))
        }
    }

    /// Wait for a DynamoDB table to be active
    static func waitForTable(tableName: String, client: AWSClient, timeout: TimeInterval = 30) async throws {
        let dynamodb = DynamoDB(client: client, region: .useast1, endpoint: endpoint)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let description = try await dynamodb.describeTable(.init(tableName: tableName))
                if description.table?.tableStatus == .active {
                    return
                }
            } catch {
                // Table might not exist yet, continue waiting
            }

            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        throw TrebuchetAWSError.tableNotReady(tableName)
    }

    /// Wait for a Cloud Map namespace to be available
    static func waitForNamespace(namespace: String, client: AWSClient, timeout: TimeInterval = 30) async throws {
        // Note: LocalStack doesn't fully support Cloud Map, so we skip this check
        // In a real AWS environment, you would uncomment the following:
        /*
        let servicediscovery = ServiceDiscovery(client: client, region: .useast1, endpoint: endpoint)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let namespaces = try await servicediscovery.listNamespaces(.init())
                if let _ = namespaces.namespaces?.first(where: { $0.name == namespace }) {
                    return
                }
            } catch {
                // Namespace might not exist yet, continue waiting
            }

            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        throw TrebuchetAWSError.namespaceNotFound(namespace)
        */
    }

    /// Generate a unique actor ID for test isolation
    static func uniqueActorID(prefix: String = "test-actor") -> String {
        return "\(prefix)-\(UUID().uuidString)"
    }
}

/// Additional error types for LocalStack testing
enum TrebuchetAWSError: Error, CustomStringConvertible {
    case tableNotReady(String)
    case namespaceNotFound(String)

    var description: String {
        switch self {
        case .tableNotReady(let table):
            return "DynamoDB table '\(table)' not ready"
        case .namespaceNotFound(let namespace):
            return "Cloud Map namespace '\(namespace)' not found"
        }
    }
}
