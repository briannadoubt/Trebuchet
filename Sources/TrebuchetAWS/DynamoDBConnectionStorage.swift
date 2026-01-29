import Foundation
import Trebuchet
import TrebuchetCloud
import TrebuchetObservability
import SotoDynamoDB
import SotoCore

// MARK: - DynamoDB Connection Storage

/// Production DynamoDB-backed connection storage for WebSocket connections.
///
/// This implementation stores WebSocket connection metadata in DynamoDB with:
/// - Primary key: `connectionId` (Hash Key)
/// - GSI: `actorId-index` for querying connections by actor
/// - TTL: Automatic cleanup of stale connections
///
/// ## Table Schema
///
/// ```
/// Table: connections
/// Primary Key:
///   - connectionId (String, Hash Key)
///
/// GSI: actorId-index
///   - actorId (String, Hash Key)
///   - streamId (String, Sort Key)
///
/// Attributes:
///   - connectedAt (Number, timestamp)
///   - lastSequence (Number)
///   - ttl (Number, auto-cleanup)
/// ```
///
/// ## Example Usage
///
/// ```swift
/// let storage = DynamoDBConnectionStorage(
///     tableName: "my-app-connections",
///     region: .useast1
/// )
///
/// try await storage.register(connectionID: "abc123", actorID: nil)
/// try await storage.subscribe(
///     connectionID: "abc123",
///     streamID: UUID(),
///     actorID: "todos",
///     lastSequence: 0
/// )
/// ```
public actor DynamoDBConnectionStorage: ConnectionStorage {
    private let client: DynamoDB
    private let tableName: String
    private let ttl: TimeInterval
    private let metrics: (any MetricsCollector)?

    /// Initialize DynamoDB connection storage
    ///
    /// - Parameters:
    ///   - tableName: DynamoDB table name
    ///   - region: AWS region (default: .useast1)
    ///   - endpoint: Custom endpoint URL for testing (default: nil uses AWS endpoint)
    ///   - ttl: Time-to-live for connections in seconds (default: 86400 = 24 hours)
    ///   - metrics: Optional metrics collector for observability
    ///   - awsClient: Optional custom AWSClient for advanced configuration
    ///
    /// ## AWS Credentials
    ///
    /// The AWSClient uses standard AWS credential resolution:
    /// 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
    /// 2. Shared credentials file (~/.aws/credentials)
    /// 3. IAM role (when running on EC2/Lambda)
    ///
    /// ## TTL Configuration
    ///
    /// The TTL value determines how long connection records remain in DynamoDB
    /// before automatic cleanup. Adjust based on your connection patterns:
    /// - Short-lived connections (dev/test): 3600 (1 hour)
    /// - Production connections: 86400 (24 hours, default)
    /// - Long-lived connections: 604800 (7 days)
    public init(
        tableName: String,
        region: Region = .useast1,
        endpoint: String? = nil,
        ttl: TimeInterval = 86400,
        metrics: (any MetricsCollector)? = nil,
        awsClient: AWSClient? = nil
    ) {
        self.tableName = tableName
        self.ttl = ttl
        self.metrics = metrics

        // Use provided client or create new one with defaults
        let client = awsClient ?? AWSClient(credentialProvider: .default)

        // Create DynamoDB client with optional custom endpoint
        if let endpoint = endpoint {
            self.client = DynamoDB(client: client, region: region, endpoint: endpoint)
        } else {
            self.client = DynamoDB(client: client, region: region)
        }
    }

    public func register(connectionID: String, actorID: String?) async throws {
        let connection = Connection(
            connectionID: connectionID,
            connectedAt: Date(),
            streamID: nil,
            actorID: actorID,
            lastSequence: 0
        )

        try await putConnection(connection)
    }

    public func subscribe(
        connectionID: String,
        streamID: UUID,
        actorID: String,
        lastSequence: UInt64
    ) async throws {
        // Get existing connection or create new one
        let existing = try await getConnection(connectionID: connectionID)

        let connection = Connection(
            connectionID: connectionID,
            connectedAt: existing?.connectedAt ?? Date(),
            streamID: streamID,
            actorID: actorID,
            lastSequence: lastSequence
        )

        try await putConnection(connection)
    }

    public func unregister(connectionID: String) async throws {
        let input = DynamoDB.DeleteItemInput(
            key: ["connectionId": .s(connectionID)],
            tableName: tableName
        )

        _ = try await client.deleteItem(input)
    }

    public func getConnections(for actorID: String) async throws -> [Connection] {
        let startTime = Date()

        do {
            // Query using the actorId-index GSI
            // Use projection expression to reduce data read and lower costs
            let input = DynamoDB.QueryInput(
                expressionAttributeValues: [":actorId": .s(actorID)],
                indexName: "actorId-index",
                keyConditionExpression: "actorId = :actorId",
                projectionExpression: "connectionId, actorId, streamId, lastSequence, connectedAt",
                tableName: tableName
            )

            let output = try await client.query(input)

            let connections = try (output.items ?? []).map { item in
                try parseConnection(from: item)
            }

            // Record success metrics
            if let metrics = metrics {
                let duration = Date().timeIntervalSince(startTime)
                await metrics.recordHistogramMilliseconds(
                    "trebuchet.dynamodb.operation.latency",
                    milliseconds: duration * 1000,
                    tags: [
                        "operation": "Query",
                        "table": tableName,
                        "index": "actorId-index"
                    ]
                )
                await metrics.incrementCounter(
                    "trebuchet.dynamodb.operation.count",
                    tags: [
                        "operation": "Query",
                        "status": "success"
                    ]
                )
            }

            return connections
        } catch {
            // Record error metrics
            if let metrics = metrics {
                await metrics.incrementCounter(
                    "trebuchet.dynamodb.operation.count",
                    tags: [
                        "operation": "Query",
                        "status": "error"
                    ]
                )
            }
            throw error
        }
    }

    public func updateSequence(
        connectionID: String,
        lastSequence: UInt64
    ) async throws {
        let input = DynamoDB.UpdateItemInput(
            expressionAttributeValues: [":seq": .n("\(lastSequence)")],
            key: ["connectionId": .s(connectionID)],
            tableName: tableName,
            updateExpression: "SET lastSequence = :seq"
        )

        _ = try await client.updateItem(input)
    }

    // MARK: - Private Helpers

    private func getConnection(connectionID: String) async throws -> Connection? {
        let input = DynamoDB.GetItemInput(
            key: ["connectionId": .s(connectionID)],
            tableName: tableName
        )

        let output = try await client.getItem(input)

        guard let item = output.item else {
            return nil
        }

        return try parseConnection(from: item)
    }

    private func putConnection(_ connection: Connection) async throws {
        var item: [String: DynamoDB.AttributeValue] = [
            "connectionId": .s(connection.connectionID),
            "connectedAt": .n("\(Int(connection.connectedAt.timeIntervalSince1970))"),
            "lastSequence": .n("\(connection.lastSequence)"),
            // TTL: configurable expiration from now
            "ttl": .n("\(Int(Date().timeIntervalSince1970 + ttl))")
        ]

        if let streamID = connection.streamID {
            item["streamId"] = .s(streamID.uuidString)
        }

        if let actorID = connection.actorID {
            item["actorId"] = .s(actorID)
        }

        let input = DynamoDB.PutItemInput(
            item: item,
            tableName: tableName
        )

        _ = try await client.putItem(input)
    }

    private func parseConnection(from item: [String: DynamoDB.AttributeValue]) throws -> Connection {
        guard let connectionIDAttr = item["connectionId"],
              case .s(let connectionID) = connectionIDAttr else {
            throw ConnectionError.invalidData
        }

        let connectedAt: Date
        if let attr = item["connectedAt"],
           case .n(let timestamp) = attr,
           let ts = Double(timestamp) {
            connectedAt = Date(timeIntervalSince1970: ts)
        } else {
            connectedAt = Date()
        }

        let streamID: UUID?
        if let attr = item["streamId"],
           case .s(let uuidStr) = attr {
            streamID = UUID(uuidString: uuidStr)
        } else {
            streamID = nil
        }

        let actorID: String?
        if let attr = item["actorId"],
           case .s(let id) = attr {
            actorID = id
        } else {
            actorID = nil
        }

        let lastSequence: UInt64
        if let attr = item["lastSequence"],
           case .n(let seqStr) = attr,
           let seq = UInt64(seqStr) {
            lastSequence = seq
        } else {
            lastSequence = 0
        }

        return Connection(
            connectionID: connectionID,
            connectedAt: connectedAt,
            streamID: streamID,
            actorID: actorID,
            lastSequence: lastSequence
        )
    }
}
