import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Trebuchet
import TrebuchetCloud
import SotoLambda
import SotoCore
import NIOCore

// MARK: - Lambda Invoke Transport

/// Transport that invokes AWS Lambda functions directly
public final class LambdaInvokeTransport: TrebuchetTransport, @unchecked Sendable {
    private let functionArn: String
    private let region: String
    private let lambdaClient: Lambda
    private let awsClient: AWSClient

    private var incomingContinuation: AsyncStream<TransportMessage>.Continuation?
    private let incomingStream: AsyncStream<TransportMessage>

    public var incoming: AsyncStream<TransportMessage> {
        incomingStream
    }

    public init(
        functionArn: String,
        region: String,
        credentials: AWSCredentials = .default,
        awsClient: AWSClient? = nil
    ) {
        self.functionArn = functionArn
        self.region = region

        // Create or use provided AWSClient
        let client: AWSClient
        if let provided = awsClient {
            client = provided
        } else if let accessKey = credentials.accessKeyId,
                  let secretKey = credentials.secretAccessKey {
            // Use static credentials if provided
            client = AWSClient(
                credentialProvider: .static(
                    accessKeyId: accessKey,
                    secretAccessKey: secretKey,
                    sessionToken: credentials.sessionToken
                )
            )
        } else {
            // Otherwise use default credential chain
            client = AWSClient(credentialProvider: .default)
        }
        self.awsClient = client
        self.lambdaClient = Lambda(
            client: client,
            region: Region(awsRegionName: region) ?? .useast1
        )

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incomingStream = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    public func connect(to endpoint: Endpoint) async throws {
        // Lambda invocations are stateless, no persistent connection needed
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        // Invoke Lambda and get response
        let response = try await invokeLambda(payload: data)

        // Create a transport message with the response
        let message = TransportMessage(
            data: response,
            source: endpoint,
            respond: { _ in
                // Lambda responses are handled synchronously
            }
        )

        incomingContinuation?.yield(message)
    }

    public func listen(on endpoint: Endpoint) async throws {
        // Lambda transport doesn't listen - it's outbound only
        // The Lambda runtime handles incoming requests
    }

    public func shutdown() async {
        incomingContinuation?.finish()
        try? await awsClient.shutdown()
    }

    // MARK: - Lambda Invocation

    private func invokeLambda(payload: Data) async throws -> Data {
        // Convert Data to ByteBuffer for Soto SDK
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeBytes(payload)

        // Create Lambda invocation request using Soto SDK
        let request = Lambda.InvocationRequest(
            functionName: functionArn,
            invocationType: .requestResponse,
            payload: .init(buffer: buffer)
        )

        // Invoke Lambda function
        let response = try await lambdaClient.invoke(request)

        // Helper to convert optional AWSHTTPBody to Data
        func awsHTTPBodyToData(_ body: AWSHTTPBody?) async throws -> Data {
            guard let body = body else { return Data() }
            // Collect the body as ByteBuffer and convert to Data
            let buffer = try await body.collect(upTo: .max)
            return Data(buffer: buffer, byteTransferStrategy: .copy)
        }

        // Check for function errors
        if let functionError = response.functionError {
            let errorData = try await awsHTTPBodyToData(response.payload)
            let errorPayload = String(decoding: errorData, as: UTF8.self)
            throw CloudError.invocationFailed(
                actorID: functionArn,
                reason: "\(functionError): \(errorPayload)"
            )
        }

        // Check status code
        guard response.statusCode == 200 else {
            throw CloudError.invocationFailed(
                actorID: functionArn,
                reason: "HTTP \(response.statusCode ?? 0)"
            )
        }

        // Extract response payload and convert to Data
        return try await awsHTTPBodyToData(response.payload)
    }
}

// MARK: - Lambda Event Adapter

/// Adapts between Lambda events and Trebuchet invocation format
public enum LambdaEventAdapter {
    /// Convert an API Gateway event to an invocation envelope
    public static func fromAPIGateway(_ event: APIGatewayV2Request) throws -> InvocationEnvelope {
        guard let body = event.body,
              let data = body.data(using: .utf8) else {
            throw CloudError.invocationFailed(actorID: "unknown", reason: "Missing request body")
        }

        return try JSONDecoder().decode(InvocationEnvelope.self, from: data)
    }

    /// Convert a response envelope to an API Gateway response
    public static func toAPIGatewayResponse(_ response: ResponseEnvelope) throws -> APIGatewayV2Response {
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        let body = String(data: data, encoding: .utf8) ?? "{}"

        return APIGatewayV2Response(
            statusCode: response.isSuccess ? .ok : .internalServerError,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    /// Convert a raw Lambda event to an invocation envelope
    public static func fromLambdaEvent(_ event: Data) throws -> InvocationEnvelope {
        try JSONDecoder().decode(InvocationEnvelope.self, from: event)
    }

    /// Convert a response envelope to raw Lambda output
    public static func toLambdaResponse(_ response: ResponseEnvelope) throws -> Data {
        try JSONEncoder().encode(response)
    }
}

// MARK: - API Gateway Types

/// API Gateway V2 HTTP API request format
public struct APIGatewayV2Request: Codable, Sendable {
    public let version: String?
    public let routeKey: String?
    public let rawPath: String?
    public let rawQueryString: String?
    public let headers: [String: String]?
    public let queryStringParameters: [String: String]?
    public let pathParameters: [String: String]?
    public let body: String?
    public let isBase64Encoded: Bool?

    public init(
        version: String? = nil,
        routeKey: String? = nil,
        rawPath: String? = nil,
        rawQueryString: String? = nil,
        headers: [String: String]? = nil,
        queryStringParameters: [String: String]? = nil,
        pathParameters: [String: String]? = nil,
        body: String? = nil,
        isBase64Encoded: Bool? = nil
    ) {
        self.version = version
        self.routeKey = routeKey
        self.rawPath = rawPath
        self.rawQueryString = rawQueryString
        self.headers = headers
        self.queryStringParameters = queryStringParameters
        self.pathParameters = pathParameters
        self.body = body
        self.isBase64Encoded = isBase64Encoded
    }
}

/// API Gateway V2 HTTP API response format
public struct APIGatewayV2Response: Codable, Sendable {
    public let statusCode: HTTPResponseStatus
    public let headers: [String: String]?
    public let body: String?
    public let isBase64Encoded: Bool?

    public init(
        statusCode: HTTPResponseStatus,
        headers: [String: String]? = nil,
        body: String? = nil,
        isBase64Encoded: Bool? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.isBase64Encoded = isBase64Encoded
    }
}

/// HTTP response status codes
public struct HTTPResponseStatus: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let ok = HTTPResponseStatus(rawValue: 200)
    public static let created = HTTPResponseStatus(rawValue: 201)
    public static let accepted = HTTPResponseStatus(rawValue: 202)
    public static let noContent = HTTPResponseStatus(rawValue: 204)
    public static let badRequest = HTTPResponseStatus(rawValue: 400)
    public static let unauthorized = HTTPResponseStatus(rawValue: 401)
    public static let forbidden = HTTPResponseStatus(rawValue: 403)
    public static let notFound = HTTPResponseStatus(rawValue: 404)
    public static let internalServerError = HTTPResponseStatus(rawValue: 500)
    public static let serviceUnavailable = HTTPResponseStatus(rawValue: 503)
}
