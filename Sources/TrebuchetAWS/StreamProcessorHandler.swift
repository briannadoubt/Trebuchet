import Foundation
import Trebuchet
import TrebuchetCloud
import SotoCore

// MARK: - Stream Processor Handler

/// Lambda handler for processing DynamoDB Stream events.
///
/// This handler is triggered by DynamoDB Streams when actor state changes.
/// It broadcasts these changes to all connected WebSocket clients.
///
/// ## Deployment
///
/// Deploy this as a separate Lambda function with:
/// - **Event source**: DynamoDB Stream (from actor state table)
/// - **Batch size**: 10-100 records
/// - **Environment variables**:
///   - `CONNECTION_TABLE`: DynamoDB table storing WebSocket connections
///   - `API_GATEWAY_ENDPOINT`: WebSocket API Gateway endpoint
///
/// ## Example Terraform
///
/// ```hcl
/// resource "aws_lambda_function" "stream_processor" {
///   function_name = "trebuchet-stream-processor"
///   handler       = "bootstrap"
///   runtime       = "provided.al2"
///
///   environment {
///     variables = {
///       CONNECTION_TABLE      = aws_dynamodb_table.connections.name
///       API_GATEWAY_ENDPOINT  = aws_apigatewayv2_api.websocket.api_endpoint
///     }
///   }
/// }
///
/// resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
///   event_source_arn  = aws_dynamodb_table.actor_state.stream_arn
///   function_name     = aws_lambda_function.stream_processor.arn
///   starting_position = "LATEST"
///   batch_size        = 10
/// }
/// ```
///
/// ## Example Usage
///
/// ```swift
/// @main
/// struct StreamProcessorLambda {
///     static func main() async throws {
///         // Initialize handler
///         let handler = try await StreamProcessorHandler.initialize()
///
///         // Run Lambda runtime
///         try await LambdaRuntime.run(handler)
///     }
/// }
/// ```
public actor StreamProcessorHandler {
    private let adapter: DynamoDBStreamAdapter
    private let connectionManager: ConnectionManager

    public init(
        connectionManager: ConnectionManager
    ) {
        self.connectionManager = connectionManager
        self.adapter = DynamoDBStreamAdapter(connectionManager: connectionManager)
    }

    // MARK: - Initialization

    /// Initialize the handler with environment variables
    ///
    /// Reads from environment:
    /// - `CONNECTION_TABLE`: DynamoDB table for connections
    /// - `API_GATEWAY_ENDPOINT`: WebSocket API endpoint
    /// - `AWS_REGION`: AWS region (defaults to us-east-1)
    public static func initialize() async throws -> StreamProcessorHandler {
        // Read environment variables
        guard let connectionTable = ProcessInfo.processInfo.environment["CONNECTION_TABLE"] else {
            throw StreamProcessorError.missingEnvironmentVariable("CONNECTION_TABLE")
        }

        guard let apiGatewayEndpoint = ProcessInfo.processInfo.environment["API_GATEWAY_ENDPOINT"] else {
            throw StreamProcessorError.missingEnvironmentVariable("API_GATEWAY_ENDPOINT")
        }

        let region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1"

        // Use production implementations
        let storage = DynamoDBConnectionStorage(
            tableName: connectionTable,
            region: Region(awsRegionName: region) ?? .useast1
        )

        let sender = APIGatewayConnectionSender(
            endpoint: apiGatewayEndpoint,
            region: region
        )

        let connectionManager = ConnectionManager(
            storage: storage,
            sender: sender
        )

        return StreamProcessorHandler(connectionManager: connectionManager)
    }

    /// Initialize with custom connection manager (for testing)
    public static func initialize(
        connectionManager: ConnectionManager
    ) -> StreamProcessorHandler {
        StreamProcessorHandler(connectionManager: connectionManager)
    }

    // MARK: - Event Handling

    /// Handle a DynamoDB Stream event
    ///
    /// This method:
    /// 1. Processes each record in the event
    /// 2. Extracts actor ID and state data
    /// 3. Broadcasts to all WebSocket connections for that actor
    ///
    /// - Parameter event: The DynamoDB Stream event
    public func handle(_ event: DynamoDBStreamEvent) async throws {
        try await adapter.process(event)
    }

    /// Handle a single record (useful for testing)
    public func handleRecord(_ record: DynamoDBStreamRecord) async throws {
        try await adapter.process(DynamoDBStreamEvent(records: [record]))
    }
}

// MARK: - Error Types

public enum StreamProcessorError: Error {
    case missingEnvironmentVariable(String)
}

// MARK: - Production Lambda Entry Point

#if canImport(AWSLambdaRuntime)

import AWSLambdaRuntime

@main
struct StreamProcessorLambda: SimpleLambdaHandler {
    typealias Event = DynamoDBStreamEvent
    typealias Output = Void

    let handler: StreamProcessorHandler

    init(context: LambdaInitializationContext) async throws {
        // Initialize using production AWS clients
        self.handler = try await StreamProcessorHandler.initialize()

        context.logger.info("Stream processor initialized")
        if let connectionTable = ProcessInfo.processInfo.environment["CONNECTION_TABLE"] {
            context.logger.info("Connection table: \(connectionTable)")
        }
        if let apiGatewayEndpoint = ProcessInfo.processInfo.environment["API_GATEWAY_ENDPOINT"] {
            context.logger.info("API Gateway endpoint: \(apiGatewayEndpoint)")
        }
    }

    func handle(
        _ event: DynamoDBStreamEvent,
        context: LambdaContext
    ) async throws {
        context.logger.info("Processing \(event.records.count) DynamoDB stream records")

        try await handler.handle(event)

        context.logger.info("Successfully processed all records")
    }
}

#endif

// MARK: - Helper Extensions

extension StreamProcessorHandler {
    /// Get statistics about processed events (for monitoring)
    public struct Statistics {
        public let recordsProcessed: Int
        public let broadcastsSent: Int
        public let errors: Int
    }

    // In production, you'd track these metrics
    // public func getStatistics() async -> Statistics {
    //     // Implementation would track metrics
    // }
}

// MARK: - Example Bootstrap File

/// Example bootstrap code for Lambda deployment
///
/// Save this as `Sources/StreamProcessor/main.swift`:
///
/// ```swift
/// import TrebuchetAWS
///
/// @main
/// struct StreamProcessorBootstrap {
///     static func main() async throws {
///         let handler = try await StreamProcessorHandler.initialize()
///
///         // Process events from stdin (Lambda runtime)
///         while let line = readLine() {
///             guard let data = line.data(using: .utf8) else { continue }
///
///             let decoder = JSONDecoder()
///             let event = try decoder.decode(DynamoDBStreamEvent.self, from: data)
///
///             try await handler.handle(event)
///         }
///     }
/// }
/// ```
