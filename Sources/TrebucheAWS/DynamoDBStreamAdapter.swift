import Foundation
import Trebuche
import TrebucheCloud

// MARK: - DynamoDB Stream Event Models

/// Represents a DynamoDB Stream record
public struct DynamoDBStreamRecord: Codable, Sendable {
    public let eventID: String
    public let eventName: String  // INSERT, MODIFY, REMOVE
    public let eventSource: String
    public let dynamodb: DynamoDBStreamData

    public init(
        eventID: String,
        eventName: String,
        eventSource: String,
        dynamodb: DynamoDBStreamData
    ) {
        self.eventID = eventID
        self.eventName = eventName
        self.eventSource = eventSource
        self.dynamodb = dynamodb
    }
}

/// DynamoDB stream data
public struct DynamoDBStreamData: Codable, Sendable {
    public let keys: [String: AttributeValue]?
    public let newImage: [String: AttributeValue]?
    public let oldImage: [String: AttributeValue]?
    public let sequenceNumber: String?
    public let streamViewType: String?

    public init(
        keys: [String: AttributeValue]? = nil,
        newImage: [String: AttributeValue]? = nil,
        oldImage: [String: AttributeValue]? = nil,
        sequenceNumber: String? = nil,
        streamViewType: String? = nil
    ) {
        self.keys = keys
        self.newImage = newImage
        self.oldImage = oldImage
        self.sequenceNumber = sequenceNumber
        self.streamViewType = streamViewType
    }
}

/// DynamoDB stream event containing multiple records
public struct DynamoDBStreamEvent: Codable, Sendable {
    public let records: [DynamoDBStreamRecord]

    public init(records: [DynamoDBStreamRecord]) {
        self.records = records
    }
}

/// DynamoDB attribute value
public enum AttributeValue: Codable, Sendable {
    case s(String)              // String
    case n(String)              // Number (as string)
    case b(Data)                // Binary
    case ss([String])           // String Set
    case ns([String])           // Number Set
    case bs([Data])             // Binary Set
    case m([String: AttributeValue])  // Map
    case l([AttributeValue])    // List
    case null(Bool)             // Null
    case bool(Bool)             // Boolean

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try? container.decode(String.self, forKey: .s) {
            self = .s(value)
        } else if let value = try? container.decode(String.self, forKey: .n) {
            self = .n(value)
        } else if let value = try? container.decode(Data.self, forKey: .b) {
            self = .b(value)
        } else if let value = try? container.decode([String].self, forKey: .ss) {
            self = .ss(value)
        } else if let value = try? container.decode([String].self, forKey: .ns) {
            self = .ns(value)
        } else if let value = try? container.decode([Data].self, forKey: .bs) {
            self = .bs(value)
        } else if let value = try? container.decode([String: AttributeValue].self, forKey: .m) {
            self = .m(value)
        } else if let value = try? container.decode([AttributeValue].self, forKey: .l) {
            self = .l(value)
        } else if let value = try? container.decode(Bool.self, forKey: .null) {
            self = .null(value)
        } else if let value = try? container.decode(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown AttributeValue type"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .s(let value):
            try container.encode(value, forKey: .s)
        case .n(let value):
            try container.encode(value, forKey: .n)
        case .b(let value):
            try container.encode(value, forKey: .b)
        case .ss(let value):
            try container.encode(value, forKey: .ss)
        case .ns(let value):
            try container.encode(value, forKey: .ns)
        case .bs(let value):
            try container.encode(value, forKey: .bs)
        case .m(let value):
            try container.encode(value, forKey: .m)
        case .l(let value):
            try container.encode(value, forKey: .l)
        case .null(let value):
            try container.encode(value, forKey: .null)
        case .bool(let value):
            try container.encode(value, forKey: .bool)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case s = "S"
        case n = "N"
        case b = "B"
        case ss = "SS"
        case ns = "NS"
        case bs = "BS"
        case m = "M"
        case l = "L"
        case null = "NULL"
        case bool = "BOOL"
    }
}

// MARK: - DynamoDB Stream Adapter

/// Processes DynamoDB Stream events and broadcasts state changes to WebSocket clients.
///
/// This adapter monitors DynamoDB Streams for actor state changes and broadcasts
/// updates to all connected WebSocket clients subscribed to that actor.
///
/// ## Architecture
///
/// ```
/// Actor → saveState() → DynamoDB
///                         ↓
///                   DynamoDB Stream
///                         ↓
///                   Lambda Trigger
///                         ↓
///               DynamoDBStreamAdapter
///                         ↓
///              ConnectionManager.broadcast()
///                         ↓
///              WebSocket Clients
/// ```
///
/// ## Example Usage
///
/// ```swift
/// let connectionManager = ConnectionManager(/* ... */)
/// let adapter = DynamoDBStreamAdapter(connectionManager: connectionManager)
///
/// // In Lambda handler
/// func handle(_ event: DynamoDBStreamEvent, context: LambdaContext) async throws {
///     try await adapter.process(event)
/// }
/// ```
public actor DynamoDBStreamAdapter {
    private let connectionManager: ConnectionManager
    private let encoder: JSONEncoder

    public init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Event Processing

    /// Process a DynamoDB Stream event
    public func process(_ event: DynamoDBStreamEvent) async throws {
        for record in event.records {
            do {
                try await processRecord(record)
            } catch {
                // Log error but continue processing other records
                print("Error processing record \(record.eventID): \(error)")
            }
        }
    }

    // MARK: - Private

    private func processRecord(_ record: DynamoDBStreamRecord) async throws {
        // Only process MODIFY and INSERT events (REMOVE means actor deleted)
        guard record.eventName == "MODIFY" || record.eventName == "INSERT" else {
            return
        }

        // Extract actor ID and new state from the record
        guard let newImage = record.dynamodb.newImage else {
            print("No new image in record \(record.eventID)")
            return
        }

        guard let actorID = extractActorID(from: newImage) else {
            print("No actorID in record \(record.eventID)")
            return
        }

        guard let stateData = extractStateData(from: newImage) else {
            print("No state data in record \(record.eventID)")
            return
        }

        // Get sequence number from DynamoDB stream or state
        let sequenceNumber = extractSequenceNumber(from: record, or: newImage)

        // Get all connections subscribed to this actor
        let connections = try await connectionManager.getConnections(for: actorID)

        // Send updates to each connection using their registered stream ID
        for connection in connections {
            // Only send to connections with active stream subscriptions
            guard let streamID = connection.streamID else {
                continue
            }

            // Create StreamDataEnvelope using the connection's stream ID
            let envelope = StreamDataEnvelope(
                streamID: streamID,
                sequenceNumber: sequenceNumber,
                data: stateData,
                timestamp: Date()
            )

            // Encode and send to this specific connection
            let envelopeData = try encoder.encode(TrebuchetEnvelope.streamData(envelope))

            do {
                try await connectionManager.send(data: envelopeData, to: connection.connectionID)
            } catch {
                // Log error but continue sending to other connections
                print("Failed to send to connection \(connection.connectionID): \(error)")
            }
        }

        print("Broadcasted state change for actor \(actorID) to \(connections.count) connections (seq: \(sequenceNumber))")
    }

    // MARK: - Extraction Helpers

    private func extractActorID(from image: [String: AttributeValue]) -> String? {
        // Standard key: "actorId" or "actorID"
        if case .s(let id) = image["actorId"] {
            return id
        }
        if case .s(let id) = image["actorID"] {
            return id
        }
        return nil
    }

    private func extractStateData(from image: [String: AttributeValue]) -> Data? {
        // State is stored as binary data
        if case .b(let data) = image["state"] {
            return data
        }
        return nil
    }

    private func extractSequenceNumber(
        from record: DynamoDBStreamRecord,
        or image: [String: AttributeValue]
    ) -> UInt64 {
        // Try to get from state first (explicit sequence tracking)
        if case .n(let numStr) = image["sequenceNumber"],
           let num = UInt64(numStr) {
            return num
        }

        // Fall back to DynamoDB stream sequence (hash it to get a number)
        if let seqStr = record.dynamodb.sequenceNumber {
            // Use hash as sequence number
            return UInt64(seqStr.hashValue)
        }

        // Last resort: use current timestamp
        return UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
