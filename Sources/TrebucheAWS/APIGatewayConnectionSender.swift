import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Trebuchet
import TrebuchetCloud
import Crypto

// MARK: - API Gateway Connection Sender

/// Production API Gateway Management API-based connection sender.
///
/// This implementation sends data to WebSocket connections using the
/// API Gateway Management API's POST-to-connection endpoint.
///
/// ## API Gateway Management API
///
/// Endpoint format: `https://{api-id}.execute-api.{region}.amazonaws.com/{stage}/@connections/{connectionId}`
///
/// The Management API provides:
/// - `POST /@connections/{connectionId}` - Send data to a connection
/// - `GET /@connections/{connectionId}` - Get connection info
/// - `DELETE /@connections/{connectionId}` - Disconnect a client
///
/// ## Example Usage
///
/// ```swift
/// let sender = APIGatewayConnectionSender(
///     endpoint: "https://abc123.execute-api.us-east-1.amazonaws.com/production",
///     region: "us-east-1"
/// )
///
/// try await sender.send(data: messageData, to: "connection-id-123")
/// ```
///
/// ## Error Handling
///
/// - 410 Gone: Connection no longer exists (client disconnected)
/// - 403 Forbidden: Invalid credentials or permissions
/// - 500 Internal Server Error: API Gateway internal error
///
public actor APIGatewayConnectionSender: ConnectionSender {
    private let endpoint: String
    private let region: String
    private let credentials: AWSCredentials

    /// Initialize with API Gateway WebSocket endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The API Gateway WebSocket API endpoint (e.g., "https://abc123.execute-api.us-east-1.amazonaws.com/production")
    ///   - region: AWS region (default: "us-east-1")
    ///   - credentials: AWS credentials (default: uses environment/IAM role)
    public init(
        endpoint: String,
        region: String = "us-east-1",
        credentials: AWSCredentials = .default
    ) {
        // Remove trailing slash if present
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.region = region
        self.credentials = credentials
    }

    public func send(data: Data, to connectionID: String) async throws {
        // Build URL: {endpoint}/@connections/{connectionId}
        let urlString = "\(endpoint)/@connections/\(connectionID)"

        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidData
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Sign request with AWS Signature V4
        signRequest(&request, payload: data)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionError.sendFailed("Invalid response from API Gateway")
        }

        switch httpResponse.statusCode {
        case 200:
            // Success
            return

        case 410:
            // Connection gone (client disconnected)
            throw ConnectionError.connectionClosed

        case 403:
            throw ConnectionError.sendFailed("API Gateway forbidden (check credentials/permissions)")

        case 500, 502, 503, 504:
            throw ConnectionError.sendFailed("API Gateway internal error (\(httpResponse.statusCode))")

        default:
            throw ConnectionError.sendFailed("API Gateway error: \(httpResponse.statusCode)")
        }
    }

    public func isAlive(connectionID: String) async -> Bool {
        // Use GET /@connections/{connectionId} to check if connection exists
        let urlString = "\(endpoint)/@connections/\(connectionID)"

        guard let url = URL(string: urlString) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Sign request with AWS Signature V4
        signRequest(&request, payload: nil)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            // 200 = connection exists
            // 410 = connection gone
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Additional Management API Methods

    /// Disconnect a client connection
    ///
    /// Uses DELETE /@connections/{connectionId} to force-disconnect a client.
    ///
    /// - Parameter connectionID: The connection to disconnect
    public func disconnect(connectionID: String) async throws {
        let urlString = "\(endpoint)/@connections/\(connectionID)"

        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidData
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        // Sign request with AWS Signature V4
        signRequest(&request, payload: nil)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionError.sendFailed("Invalid response from API Gateway")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 410 else {
            throw ConnectionError.sendFailed("API Gateway disconnect error: \(httpResponse.statusCode)")
        }
    }

    // MARK: - Request Signing

    /// Sign a request with AWS Signature V4
    private func signRequest(_ request: inout URLRequest, payload: Data?) {
        guard let accessKey = credentials.accessKeyId,
              let secretKey = credentials.secretAccessKey else {
            // No credentials available - request will likely fail with 403
            return
        }

        let signer = AWSSigV4Signer(
            accessKey: accessKey,
            secretKey: secretKey,
            region: region
        )

        signer.sign(&request, payload: payload)
    }

    /// Get connection information
    ///
    /// Uses GET /@connections/{connectionId} to retrieve connection metadata.
    ///
    /// - Parameter connectionID: The connection to query
    /// - Returns: Connection metadata including connected time
    public func getConnectionInfo(connectionID: String) async throws -> ConnectionInfo {
        let urlString = "\(endpoint)/@connections/\(connectionID)"

        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidData
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Sign request with AWS Signature V4
        signRequest(&request, payload: nil)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionError.sendFailed("Invalid response from API Gateway")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 410 {
                throw ConnectionError.connectionClosed
            }
            throw ConnectionError.sendFailed("API Gateway error: \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(ConnectionInfo.self, from: data)
    }
}

// MARK: - Connection Info

/// Connection information from API Gateway Management API
public struct ConnectionInfo: Codable, Sendable {
    /// Time the connection was established (ISO 8601)
    public let connectedAt: String

    /// Source IP address
    public let sourceIp: String?

    /// User agent string
    public let userAgent: String?

    enum CodingKeys: String, CodingKey {
        case connectedAt
        case sourceIp = "identity.sourceIp"
        case userAgent = "identity.userAgent"
    }
}

// MARK: - AWS Signature V4

/// AWS Signature Version 4 signing implementation
///
/// This implements the AWS SigV4 signing process required for API Gateway Management API requests.
///
/// References:
/// - https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
/// - https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-how-to-call-websocket-api-connections.html
private struct AWSSigV4Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service: String = "execute-api"

    /// Sign a URLRequest with AWS Signature V4
    func sign(_ request: inout URLRequest, payload: Data?) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let dateStamp = String(timestamp.prefix(8))  // YYYYMMDD

        guard let url = request.url,
              let host = url.host else {
            return
        }

        // Add required headers
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")

        // Create canonical request
        let method = request.httpMethod ?? "GET"
        let canonicalUri = url.path.isEmpty ? "/" : url.path
        let canonicalQueryString = createCanonicalQueryString(from: url)
        let canonicalHeaders = createCanonicalHeaders(from: request)
        let signedHeaders = "host;x-amz-date"

        let payloadHash: String
        if let payload = payload {
            payloadHash = sha256(data: payload)
        } else {
            payloadHash = sha256(data: Data())
        }

        let canonicalRequest = """
        \(method)
        \(canonicalUri)
        \(canonicalQueryString)
        \(canonicalHeaders)

        \(signedHeaders)
        \(payloadHash)
        """

        // Create string to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let hashedCanonicalRequest = sha256(string: canonicalRequest)
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(timestamp)
        \(credentialScope)
        \(hashedCanonicalRequest)
        """

        // Calculate signature
        let signature = calculateSignature(
            stringToSign: stringToSign,
            dateStamp: dateStamp,
            secretKey: secretKey
        )

        // Create authorization header
        let authorizationHeader = """
        AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), \
        SignedHeaders=\(signedHeaders), \
        Signature=\(signature)
        """

        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Helper Methods

    private func createCanonicalQueryString(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return ""
        }

        return queryItems
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\(urlEncode($0.value ?? ""))" }
            .joined(separator: "&")
    }

    private func createCanonicalHeaders(from request: URLRequest) -> String {
        var headers: [(String, String)] = []

        if let host = request.value(forHTTPHeaderField: "Host") {
            headers.append(("host", host))
        }
        if let date = request.value(forHTTPHeaderField: "X-Amz-Date") {
            headers.append(("x-amz-date", date))
        }

        return headers
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
    }

    private func calculateSignature(
        stringToSign: String,
        dateStamp: String,
        secretKey: String
    ) -> String {
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmac(key: kDate, data: region.data(using: .utf8)!)
        let kService = hmac(key: kRegion, data: service.data(using: .utf8)!)
        let kSigning = hmac(key: kService, data: "aws4_request".data(using: .utf8)!)
        let signature = hmac(key: kSigning, data: stringToSign.data(using: .utf8)!)

        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(string: String) -> String {
        sha256(data: string.data(using: .utf8)!)
    }

    private func hmac(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(authenticationCode)
    }

    private func urlEncode(_ string: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return string.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? string
    }
}
