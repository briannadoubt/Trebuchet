import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Trebuche
import TrebucheCloud
import TrebucheObservability

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
///     region: "us-east-1"
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
    private let tableName: String
    private let region: String
    private let credentials: AWSCredentials
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let endpoint: String?
    private let ttl: TimeInterval
    private let metrics: (any MetricsCollector)?

    /// Initialize DynamoDB connection storage
    ///
    /// - Parameters:
    ///   - tableName: DynamoDB table name
    ///   - region: AWS region (default: "us-east-1")
    ///   - credentials: AWS credentials (default: .default uses standard credential chain)
    ///   - endpoint: Custom endpoint URL for testing (default: nil uses AWS endpoint)
    ///   - ttl: Time-to-live for connections in seconds (default: 86400 = 24 hours)
    ///   - metrics: Optional metrics collector for observability
    ///
    /// ## AWS Credentials
    ///
    /// The `.default` credentials follow standard AWS credential resolution:
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
        region: String = "us-east-1",
        credentials: AWSCredentials = .default,
        endpoint: String? = nil,
        ttl: TimeInterval = 86400,
        metrics: (any MetricsCollector)? = nil
    ) {
        self.tableName = tableName
        self.region = region
        self.credentials = credentials
        self.endpoint = endpoint
        self.ttl = ttl
        self.metrics = metrics

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
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
        let request = DynamoDBRequest(
            operation: "DeleteItem",
            tableName: tableName,
            key: ["connectionId": .string(connectionID)]
        )

        _ = try await execute(request)
    }

    public func getConnections(for actorID: String) async throws -> [Connection] {
        let startTime = Date()

        do {
            // Query using the actorId-index GSI
            // Use projection expression to reduce data read and lower costs
            let request = DynamoDBQueryRequest(
                tableName: tableName,
                indexName: "actorId-index",
                keyConditionExpression: "actorId = :actorId",
                expressionAttributeValues: [
                    ":actorId": .string(actorID)
                ],
                projectionExpression: "connectionId, actorId, streamId, lastSequence, connectedAt"
            )

            let response = try await executeQuery(request)

            let connections = try response.items.map { item in
                try parseConnection(from: item)
            }

            // Record success metrics
            if let metrics = metrics {
                let duration = Date().timeIntervalSince(startTime)
                await metrics.recordHistogramMilliseconds(
                    "trebuche.dynamodb.operation.latency",
                    milliseconds: duration * 1000,
                    tags: [
                        "operation": "Query",
                        "table": tableName,
                        "index": "actorId-index"
                    ]
                )
                await metrics.incrementCounter(
                    "trebuche.dynamodb.operation.count",
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
                    "trebuche.dynamodb.operation.count",
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
        let request = DynamoDBUpdateRequest(
            tableName: tableName,
            key: ["connectionId": .string(connectionID)],
            updateExpression: "SET lastSequence = :seq",
            expressionAttributeValues: [
                ":seq": .number("\(lastSequence)")
            ]
        )

        _ = try await executeUpdate(request)
    }

    // MARK: - Private Helpers

    private func getConnection(connectionID: String) async throws -> Connection? {
        let request = DynamoDBRequest(
            operation: "GetItem",
            tableName: tableName,
            key: ["connectionId": .string(connectionID)]
        )

        let response = try await execute(request)

        guard let item = response.item else {
            return nil
        }

        return try parseConnection(from: item)
    }

    private func putConnection(_ connection: Connection) async throws {
        var item: [String: DynamoDBAttributeValue] = [
            "connectionId": .string(connection.connectionID),
            "connectedAt": .number("\(Int(connection.connectedAt.timeIntervalSince1970))"),
            "lastSequence": .number("\(connection.lastSequence)"),
            // TTL: configurable expiration from now
            "ttl": .number("\(Int(Date().timeIntervalSince1970 + ttl))")
        ]

        if let streamID = connection.streamID {
            item["streamId"] = .string(streamID.uuidString)
        }

        if let actorID = connection.actorID {
            item["actorId"] = .string(actorID)
        }

        let request = DynamoDBRequest(
            operation: "PutItem",
            tableName: tableName,
            item: item
        )

        _ = try await execute(request)
    }

    private func parseConnection(from item: [String: DynamoDBAttributeValue]) throws -> Connection {
        guard case .string(let connectionID) = item["connectionId"] else {
            throw ConnectionError.invalidData
        }

        let connectedAt: Date
        if case .number(let timestamp) = item["connectedAt"],
           let ts = Double(timestamp) {
            connectedAt = Date(timeIntervalSince1970: ts)
        } else {
            connectedAt = Date()
        }

        let streamID: UUID?
        if case .string(let uuidStr) = item["streamId"] {
            streamID = UUID(uuidString: uuidStr)
        } else {
            streamID = nil
        }

        let actorID: String?
        if case .string(let id) = item["actorId"] {
            actorID = id
        } else {
            actorID = nil
        }

        let lastSequence: UInt64
        if case .number(let seqStr) = item["lastSequence"],
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

    private func execute(_ request: DynamoDBRequest) async throws -> DynamoDBResponse {
        let url = endpoint ?? "https://dynamodb.\(region).amazonaws.com"
        let body = try encoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("DynamoDB_20120810.\(request.operation)", forHTTPHeaderField: "X-Amz-Target")

        // Simplified auth - production should use AWS Signature V4
        if let accessKey = credentials.accessKeyId {
            urlRequest.setValue(accessKey, forHTTPHeaderField: "X-Amz-Access-Key")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError(underlying: URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectionError.sendFailed("DynamoDB error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        return try decoder.decode(DynamoDBResponse.self, from: data)
    }

    private func executeQuery(_ request: DynamoDBQueryRequest) async throws -> DynamoDBQueryResponse {
        let url = endpoint ?? "https://dynamodb.\(region).amazonaws.com"
        let body = try encoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("DynamoDB_20120810.Query", forHTTPHeaderField: "X-Amz-Target")

        if let accessKey = credentials.accessKeyId {
            urlRequest.setValue(accessKey, forHTTPHeaderField: "X-Amz-Access-Key")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError(underlying: URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectionError.sendFailed("DynamoDB Query error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        return try decoder.decode(DynamoDBQueryResponse.self, from: data)
    }

    private func executeUpdate(_ request: DynamoDBUpdateRequest) async throws -> DynamoDBResponse {
        let url = endpoint ?? "https://dynamodb.\(region).amazonaws.com"
        let body = try encoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("DynamoDB_20120810.UpdateItem", forHTTPHeaderField: "X-Amz-Target")

        if let accessKey = credentials.accessKeyId {
            urlRequest.setValue(accessKey, forHTTPHeaderField: "X-Amz-Access-Key")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError(underlying: URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectionError.sendFailed("DynamoDB Update error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        return try decoder.decode(DynamoDBResponse.self, from: data)
    }
}

// MARK: - DynamoDB Query Types

struct DynamoDBQueryRequest: Codable {
    let tableName: String
    let indexName: String?
    let keyConditionExpression: String
    let expressionAttributeValues: [String: DynamoDBAttributeValue]
    let projectionExpression: String?

    enum CodingKeys: String, CodingKey {
        case tableName = "TableName"
        case indexName = "IndexName"
        case keyConditionExpression = "KeyConditionExpression"
        case expressionAttributeValues = "ExpressionAttributeValues"
        case projectionExpression = "ProjectionExpression"
    }
}

struct DynamoDBQueryResponse: Codable {
    let items: [[String: DynamoDBAttributeValue]]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct DynamoDBUpdateRequest: Codable {
    let tableName: String
    let key: [String: DynamoDBAttributeValue]
    let updateExpression: String
    let expressionAttributeValues: [String: DynamoDBAttributeValue]

    enum CodingKeys: String, CodingKey {
        case tableName = "TableName"
        case key = "Key"
        case updateExpression = "UpdateExpression"
        case expressionAttributeValues = "ExpressionAttributeValues"
    }
}
