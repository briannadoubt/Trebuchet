import Foundation
import Trebuchet
import TrebuchetCloud
import SotoDynamoDB
import SotoCore

// MARK: - DynamoDB State Store

/// Actor state storage using AWS DynamoDB with Soto SDK
public actor DynamoDBStateStore: ActorStateStore {
    private let client: DynamoDB
    private let awsClient: AWSClient
    private let tableName: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Initialize DynamoDB state store
    ///
    /// - Parameters:
    ///   - tableName: DynamoDB table name
    ///   - region: AWS region (default: .useast1)
    ///   - endpoint: Custom endpoint for local testing (e.g., LocalStack)
    ///   - awsClient: Optional custom AWSClient for advanced configuration
    public init(
        tableName: String,
        region: Region = .useast1,
        endpoint: String? = nil,
        awsClient: AWSClient? = nil
    ) {
        self.tableName = tableName

        // Use provided client or create new one with defaults
        // In Soto v7, httpClient defaults to HTTPClient.shared
        self.awsClient = awsClient ?? AWSClient(
            credentialProvider: .default
        )

        // Create DynamoDB client with optional custom endpoint
        if let endpoint = endpoint {
            self.client = DynamoDB(client: self.awsClient, region: region, endpoint: endpoint)
        } else {
            self.client = DynamoDB(client: self.awsClient, region: region)
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        let input = DynamoDB.GetItemInput(
            key: ["actorId": .s(actorID)],
            tableName: tableName
        )

        let output = try await client.getItem(input)

        guard let item = output.item,
              let stateAttr = item["state"],
              case .b(let awsData) = stateAttr else {
            return nil
        }

        // Extract Data from AWSBase64Data using Codable round-trip
        // This is a workaround since AWSBase64Data's internal data is not public
        // TODO: File issue with Soto to add public data accessor
        let stateData: Data
        do {
            let jsonData = try JSONEncoder().encode(awsData)
            let base64String = try JSONDecoder().decode(String.self, from: jsonData)
            guard let decoded = Data(base64Encoded: base64String) else {
                throw CloudError.configurationInvalid("AWSBase64Data contains invalid base64 for actor \(actorID)")
            }
            stateData = decoded
        } catch {
            // If Soto changes Codable format, provide helpful error
            throw CloudError.configurationInvalid("Failed to extract data from AWSBase64Data (Soto SDK format may have changed): \(error)")
        }
        return try decoder.decode(State.self, from: stateData)
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let stateData = try encoder.encode(state)

        // Get current sequence number and increment, or start at 1
        let currentSeq = try await getSequenceNumber(for: actorID) ?? 0
        let newSeq = currentSeq + 1

        try await putItem(actorID: actorID, state: stateData, sequenceNumber: newSeq)
    }

    /// Save state with an explicit sequence number for ordering
    ///
    /// This method is used for streaming scenarios where order matters.
    /// The sequence number is stored and used by DynamoDB Streams consumers
    /// to properly order state updates.
    ///
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: The actor's identifier
    ///   - sequenceNumber: Explicit sequence number, or nil to auto-increment
    /// - Returns: The sequence number that was used
    @discardableResult
    public func saveWithSequence<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        sequenceNumber: UInt64? = nil
    ) async throws -> UInt64 {
        let stateData = try encoder.encode(state)

        // If no sequence provided, get current and increment
        let sequence: UInt64
        if let provided = sequenceNumber {
            sequence = provided
        } else {
            let current = try await getSequenceNumber(for: actorID) ?? 0
            sequence = current + 1
        }

        try await putItem(actorID: actorID, state: stateData, sequenceNumber: sequence)

        return sequence
    }

    /// Get the current sequence number for an actor
    ///
    /// - Parameter actorID: The actor's identifier
    /// - Returns: The current sequence number, or nil if no state exists
    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        let input = DynamoDB.GetItemInput(
            key: ["actorId": .s(actorID)],
            projectionExpression: "sequenceNumber",
            tableName: tableName
        )

        let output = try await client.getItem(input)

        guard let item = output.item,
              let seqAttr = item["sequenceNumber"],
              case .n(let seqStr) = seqAttr,
              let sequence = UInt64(seqStr) else {
            return nil
        }

        return sequence
    }

    public func delete(for actorID: String) async throws {
        let input = DynamoDB.DeleteItemInput(
            key: ["actorId": .s(actorID)],
            tableName: tableName
        )

        _ = try await client.deleteItem(input)
    }

    public func exists(for actorID: String) async throws -> Bool {
        let input = DynamoDB.GetItemInput(
            key: ["actorId": .s(actorID)],
            projectionExpression: "actorId",
            tableName: tableName
        )

        let output = try await client.getItem(input)
        return output.item != nil
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

    // MARK: - Optimistic Locking

    /// Save state with version check to prevent concurrent write conflicts
    ///
    /// Uses DynamoDB's conditional expressions to ensure the version matches
    /// before updating. If the version doesn't match, throws versionConflict.
    ///
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: Actor identifier
    ///   - expectedVersion: The version number that must match for the save to succeed
    /// - Returns: The new version number after save
    /// - Throws: ActorStateError.versionConflict if the version doesn't match
    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        let stateData = try encoder.encode(state)
        let newVersion = expectedVersion + 1

        let item: [String: DynamoDB.AttributeValue] = [
            "actorId": .s(actorID),
            "state": .b(AWSBase64Data.data(stateData)),
            "sequenceNumber": .n("\(newVersion)"),
            "updatedAt": .s(ISO8601DateFormatter().string(from: Date()))
        ]

        // For new items (expectedVersion == 0), check attribute_not_exists
        // For existing items, check sequenceNumber matches
        let conditionExpression: String
        let expressionAttributeValues: [String: DynamoDB.AttributeValue]?

        if expectedVersion == 0 {
            conditionExpression = "attribute_not_exists(actorId)"
            expressionAttributeValues = nil
        } else {
            conditionExpression = "sequenceNumber = :expected"
            expressionAttributeValues = [":expected": .n("\(expectedVersion)")]
        }

        let input = DynamoDB.PutItemInput(
            conditionExpression: conditionExpression,
            expressionAttributeValues: expressionAttributeValues,
            item: item,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input)
            return newVersion
        } catch let error as DynamoDBErrorType where error == .conditionalCheckFailedException {
            // Conditional check failed - get actual version
            let actualVersion = try await getSequenceNumber(for: actorID) ?? 0
            throw ActorStateError.versionConflict(
                expected: expectedVersion,
                actual: actualVersion
            )
        }
    }

    // MARK: - Private Helpers

    private func putItem(actorID: String, state: Data, sequenceNumber: UInt64?) async throws {
        var item: [String: DynamoDB.AttributeValue] = [
            "actorId": .s(actorID),
            "state": .b(AWSBase64Data.data(state)),
            "updatedAt": .s(ISO8601DateFormatter().string(from: Date()))
        ]

        // Add sequence number if provided
        if let sequence = sequenceNumber {
            item["sequenceNumber"] = .n("\(sequence)")
        }

        let input = DynamoDB.PutItemInput(
            item: item,
            tableName: tableName
        )

        _ = try await client.putItem(input)
    }

    // MARK: - Lifecycle

    /// Shutdown the underlying AWS client
    ///
    /// This should be called when the state store is no longer needed to properly
    /// clean up resources. After calling shutdown, the store cannot be used.
    public func shutdown() async throws {
        try await awsClient.shutdown()
    }
}
