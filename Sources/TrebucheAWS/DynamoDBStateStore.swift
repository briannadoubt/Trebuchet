import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Trebuche
import TrebucheCloud

// MARK: - DynamoDB State Store

/// Actor state storage using AWS DynamoDB
public actor DynamoDBStateStore: ActorStateStore {
    private let tableName: String
    private let region: String
    private let credentials: AWSCredentials
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// DynamoDB endpoint (for local development)
    private let endpoint: String?

    public init(
        tableName: String,
        region: String = "us-east-1",
        credentials: AWSCredentials = .default,
        endpoint: String? = nil
    ) {
        self.tableName = tableName
        self.region = region
        self.credentials = credentials
        self.endpoint = endpoint

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        let item = try await getItem(actorID: actorID)

        guard let stateData = item?["state"] else {
            return nil
        }

        return try decoder.decode(State.self, from: stateData)
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let stateData = try encoder.encode(state)
        try await putItem(actorID: actorID, state: stateData)
    }

    public func delete(for actorID: String) async throws {
        try await deleteItem(actorID: actorID)
    }

    public func exists(for actorID: String) async throws -> Bool {
        let item = try await getItem(actorID: actorID)
        return item != nil
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        // Load current state
        let current = try await load(for: actorID, as: type)

        // Apply transformation
        let newState = try await transform(current)

        // Save and return
        try await save(newState, for: actorID)
        return newState
    }

    // MARK: - DynamoDB Operations

    private func getItem(actorID: String) async throws -> [String: Data]? {
        // Build request
        let request = DynamoDBRequest(
            operation: "GetItem",
            tableName: tableName,
            key: ["actorId": .string(actorID)]
        )

        let response = try await execute(request)

        guard let item = response.item else {
            return nil
        }

        // Convert to Data dictionary
        var result: [String: Data] = [:]
        for (key, value) in item {
            if case .binary(let data) = value {
                result[key] = data
            } else if case .string(let str) = value {
                result[key] = str.data(using: .utf8)
            }
        }

        return result
    }

    private func putItem(actorID: String, state: Data) async throws {
        let request = DynamoDBRequest(
            operation: "PutItem",
            tableName: tableName,
            item: [
                "actorId": .string(actorID),
                "state": .binary(state),
                "updatedAt": .string(ISO8601DateFormatter().string(from: Date()))
            ]
        )

        _ = try await execute(request)
    }

    private func deleteItem(actorID: String) async throws {
        let request = DynamoDBRequest(
            operation: "DeleteItem",
            tableName: tableName,
            key: ["actorId": .string(actorID)]
        )

        _ = try await execute(request)
    }

    private func execute(_ request: DynamoDBRequest) async throws -> DynamoDBResponse {
        // In a real implementation, this would use the AWS SDK (Soto)
        // For now, we'll use direct HTTP calls

        let url = endpoint ?? "https://dynamodb.\(region).amazonaws.com"
        let body = try encoder.encode(request)

        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("DynamoDB_20120810.\(request.operation)", forHTTPHeaderField: "X-Amz-Target")

        // Sign request (simplified - real implementation uses AWS Signature V4)
        if let accessKey = credentials.accessKeyId,
           let secretKey = credentials.secretAccessKey {
            // Add auth headers
            urlRequest.setValue(accessKey, forHTTPHeaderField: "X-Amz-Access-Key")
            // Real implementation would compute proper signature
            _ = secretKey
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudError.networkError(underlying: URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudError.stateStoreFailed(reason: "DynamoDB error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        return try decoder.decode(DynamoDBResponse.self, from: data)
    }
}

// MARK: - DynamoDB Types

struct DynamoDBRequest: Codable {
    let operation: String
    let tableName: String
    var key: [String: AttributeValue]?
    var item: [String: AttributeValue]?

    enum CodingKeys: String, CodingKey {
        case tableName = "TableName"
        case key = "Key"
        case item = "Item"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tableName, forKey: .tableName)
        if let key = key {
            try container.encode(key, forKey: .key)
        }
        if let item = item {
            try container.encode(item, forKey: .item)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.operation = ""  // Not decoded
        self.tableName = try container.decode(String.self, forKey: .tableName)
        self.key = try container.decodeIfPresent([String: AttributeValue].self, forKey: .key)
        self.item = try container.decodeIfPresent([String: AttributeValue].self, forKey: .item)
    }

    init(operation: String, tableName: String, key: [String: AttributeValue]? = nil, item: [String: AttributeValue]? = nil) {
        self.operation = operation
        self.tableName = tableName
        self.key = key
        self.item = item
    }
}

struct DynamoDBResponse: Codable {
    var item: [String: AttributeValue]?

    enum CodingKeys: String, CodingKey {
        case item = "Item"
    }
}

enum AttributeValue: Codable {
    case string(String)
    case number(String)
    case binary(Data)
    case bool(Bool)
    case null

    enum CodingKeys: String, CodingKey {
        case S, N, B, BOOL, NULL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try container.decodeIfPresent(String.self, forKey: .S) {
            self = .string(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .N) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(Data.self, forKey: .B) {
            self = .binary(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .BOOL) {
            self = .bool(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .string(let value):
            try container.encode(value, forKey: .S)
        case .number(let value):
            try container.encode(value, forKey: .N)
        case .binary(let value):
            try container.encode(value, forKey: .B)
        case .bool(let value):
            try container.encode(value, forKey: .BOOL)
        case .null:
            try container.encode(true, forKey: .NULL)
        }
    }
}
