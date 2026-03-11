import NIO
import NIOHTTP1
import NIOFoundationCompat
import Foundation
import CommonCrypto

final class OTelHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let ingester: SpanIngester
    private let store: SpanStore
    private let authToken: String?
    /// SHA-256 hex of the token, used as the session cookie value
    private let sessionHash: String?

    private var requestHead: HTTPRequestHead?
    private var body = ByteBuffer()

    init(ingester: SpanIngester, store: SpanStore, authToken: String?) {
        self.ingester = ingester
        self.store = store
        self.authToken = authToken
        self.sessionHash = authToken.map { Self.sha256Hex($0) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            body.clear()

        case .body(var buf):
            body.writeBuffer(&buf)

        case .end:
            guard let head = requestHead else { return }
            let bodyData = Data(buffer: body)
            let ingester = self.ingester
            let store = self.store
            let authToken = self.authToken
            let sessionHash = self.sessionHash

            nonisolated(unsafe) let ctx = context
            let allocator = context.channel.allocator
            Task { @Sendable in
                let response = await Self.handleRequest(
                    head: head,
                    body: bodyData,
                    ingester: ingester,
                    store: store,
                    authToken: authToken,
                    sessionHash: sessionHash
                )
                ctx.eventLoop.execute {
                    Self.sendResponse(context: ctx, response: response, allocator: allocator)
                }
            }
        }
    }

    // MARK: - Auth

    private static func checkBearerAuth(head: HTTPRequestHead, token: String) -> Bool {
        guard let authHeader = head.headers["Authorization"].first else { return false }
        return authHeader == "Bearer \(token)"
    }

    private static func checkSessionCookie(head: HTTPRequestHead, sessionHash: String) -> Bool {
        for cookieHeader in head.headers["Cookie"] {
            for part in cookieHeader.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("otel_session=") {
                    let value = String(trimmed.dropFirst("otel_session=".count))
                    return value == sessionHash
                }
            }
        }
        return false
    }

    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request routing

    private static func handleRequest(
        head: HTTPRequestHead,
        body: Data,
        ingester: SpanIngester,
        store: SpanStore,
        authToken: String?,
        sessionHash: String?
    ) async -> HTTPResponse {
        let components = head.uri.split(separator: "?", maxSplits: 1)
        let path = String(components[0])
        let queryString = components.count > 1 ? String(components[1]) : ""
        let query = parseQuery(queryString)

        // Health check is always public
        if head.method == .GET && path == "/health" {
            return HTTPResponse(status: .ok, json: ["status": "ok"])
        }

        // If auth is configured, enforce it
        if let authToken, let sessionHash {
            // OTLP ingestion uses Bearer token
            if head.method == .POST && path == "/v1/traces" {
                guard checkBearerAuth(head: head, token: authToken) else {
                    return HTTPResponse(status: .unauthorized, json: ["error": "Invalid or missing Authorization header"])
                }
                return await handleIngestTraces(body: body, ingester: ingester)
            }

            if head.method == .POST && path == "/v1/logs" {
                guard checkBearerAuth(head: head, token: authToken) else {
                    return HTTPResponse(status: .unauthorized, json: ["error": "Invalid or missing Authorization header"])
                }
                return await handleIngestLogs(body: body, ingester: ingester)
            }

            // Login page and login POST are public
            if path == "/login" {
                if head.method == .POST {
                    return handleLogin(body: body, authToken: authToken, sessionHash: sessionHash)
                }
                return HTTPResponse(status: .ok, html: DashboardAssets.loginHTML)
            }

            // Logout
            if path == "/logout" && head.method == .POST {
                return HTTPResponse(
                    status: .seeOther,
                    body: Data(),
                    contentType: "text/plain",
                    extraHeaders: [
                        ("Location", "/login"),
                        ("Set-Cookie", "otel_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
                    ]
                )
            }

            // Everything else requires a valid session cookie
            guard checkSessionCookie(head: head, sessionHash: sessionHash) else {
                // Redirect browsers to login, return 401 for API calls
                if path.hasPrefix("/api/") {
                    return HTTPResponse(status: .unauthorized, json: ["error": "Not authenticated"])
                }
                return HTTPResponse(
                    status: .seeOther,
                    body: Data(),
                    contentType: "text/plain",
                    extraHeaders: [("Location", "/login")]
                )
            }
        }

        // Authenticated (or auth disabled) — route normally
        switch (head.method, path) {
        case (.POST, "/v1/traces"):
            return await handleIngestTraces(body: body, ingester: ingester)
        case (.POST, "/v1/logs"):
            return await handleIngestLogs(body: body, ingester: ingester)
        case (.GET, "/api/logs"):
            return await handleListLogs(query: query, store: store)
        case (.GET, _) where path.hasPrefix("/api/traces/") && path.hasSuffix("/logs"):
            let trimmed = String(path.dropFirst("/api/traces/".count).dropLast("/logs".count))
            return await handleGetLogsForTrace(traceId: trimmed, store: store)
        case (.GET, "/api/traces"):
            return await handleListTraces(query: query, store: store)
        case (.GET, _) where path.hasPrefix("/api/traces/"):
            let traceId = String(path.dropFirst("/api/traces/".count))
            return await handleGetTrace(traceId: traceId, store: store)
        case (.GET, "/api/services"):
            return await handleListServices(store: store)
        case (.GET, "/api/stats"):
            return await handleGetStats(query: query, store: store)
        case (.GET, "/api/search"):
            return await handleSearch(query: query, store: store)
        case (.GET, "/"):
            return HTTPResponse(status: .ok, html: DashboardAssets.indexHTML)
        case (.GET, "/login"):
            // Already logged in, redirect to dashboard
            return HTTPResponse(
                status: .seeOther,
                body: Data(),
                contentType: "text/plain",
                extraHeaders: [("Location", "/")]
            )
        case (.POST, "/logout"):
            return HTTPResponse(
                status: .seeOther,
                body: Data(),
                contentType: "text/plain",
                extraHeaders: [
                    ("Location", "/login"),
                    ("Set-Cookie", "otel_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
                ]
            )
        default:
            return HTTPResponse(status: .notFound, json: ["error": "Not found"])
        }
    }

    // MARK: - Login

    private static func handleLogin(body: Data, authToken: String, sessionHash: String) -> HTTPResponse {
        // Parse form body: token=<value>
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        let formParams = parseQuery(bodyStr)
        guard let submitted = formParams["token"], submitted == authToken else {
            return HTTPResponse(status: .ok, html: DashboardAssets.loginHTML(error: "Invalid token"))
        }

        // Set session cookie (30 days) and redirect to dashboard
        let maxAge = 30 * 24 * 3600
        return HTTPResponse(
            status: .seeOther,
            body: Data(),
            contentType: "text/plain",
            extraHeaders: [
                ("Location", "/"),
                ("Set-Cookie", "otel_session=\(sessionHash); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)")
            ]
        )
    }

    // MARK: - Handlers

    private static func handleIngestTraces(body: Data, ingester: SpanIngester) async -> HTTPResponse {
        do {
            let spans = try OTLPDecoder.decodeTraces(from: body)
            if !spans.isEmpty {
                await ingester.ingest(spans)
            }
            return HTTPResponse(status: .ok, json: [:])
        } catch {
            return HTTPResponse(status: .badRequest, json: ["error": "\(error)"])
        }
    }

    private static func handleListTraces(query: [String: String], store: SpanStore) async -> HTTPResponse {
        let service = query["service"]
        let status: Int? = query["status"].flatMap { Int($0) }
        let limit = Int(query["limit"] ?? "50") ?? 50
        let cursor = Int64(query["cursor"] ?? "")

        do {
            let traces = try await store.listTraces(
                service: service,
                status: status,
                limit: limit,
                cursor: cursor
            )
            let json = try JSONEncoder().encode(traces)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleGetTrace(traceId: String, store: SpanStore) async -> HTTPResponse {
        do {
            let spans = try await store.getTrace(traceId: traceId)
            let json = try JSONEncoder().encode(spans)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleListServices(store: SpanStore) async -> HTTPResponse {
        do {
            let services = try await store.listServices()
            let json = try JSONEncoder().encode(services)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleGetStats(query: [String: String], store: SpanStore) async -> HTTPResponse {
        let sinceMinutes = Int(query["since"] ?? "60") ?? 60
        let sinceNano = Int64(Date().timeIntervalSince1970 * 1_000_000_000) - Int64(sinceMinutes) * 60 * 1_000_000_000

        do {
            let stats = try await store.getStats(since: sinceNano)
            let json = try JSONEncoder().encode(stats)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleSearch(query: [String: String], store: SpanStore) async -> HTTPResponse {
        let q = query["q"] ?? ""
        let limit = Int(query["limit"] ?? "50") ?? 50

        do {
            let results = try await store.searchSpans(query: q, limit: limit)
            let json = try JSONEncoder().encode(results)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleIngestLogs(body: Data, ingester: SpanIngester) async -> HTTPResponse {
        do {
            let logs = try OTLPDecoder.decodeLogs(from: body)
            if !logs.isEmpty {
                await ingester.ingestLogs(logs)
            }
            return HTTPResponse(status: .ok, json: [:])
        } catch {
            return HTTPResponse(status: .badRequest, json: ["error": "\(error)"])
        }
    }

    private static func handleListLogs(query: [String: String], store: SpanStore) async -> HTTPResponse {
        let service = query["service"]
        let minSeverity: Int? = query["severity"].flatMap { Int($0) }
        let search = query["search"]
        let limit = Int(query["limit"] ?? "50") ?? 50
        let cursor = Int64(query["cursor"] ?? "")

        do {
            let page = try await store.listLogs(
                service: service,
                minSeverity: minSeverity,
                search: search,
                limit: limit,
                cursor: cursor
            )
            let json = try JSONEncoder().encode(page)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    private static func handleGetLogsForTrace(traceId: String, store: SpanStore) async -> HTTPResponse {
        do {
            let logs = try await store.getLogsForTrace(traceId: traceId)
            let json = try JSONEncoder().encode(logs)
            return HTTPResponse(status: .ok, body: json, contentType: "application/json")
        } catch {
            return HTTPResponse(status: .internalServerError, json: ["error": "\(error)"])
        }
    }

    // MARK: - Helpers

    private static func parseQuery(_ queryString: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                result[key] = value
            }
        }
        return result
    }

    private static func sendResponse(context: ChannelHandlerContext, response: HTTPResponse, allocator: ByteBufferAllocator) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: "\(response.body.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        for (name, value) in response.extraHeaders {
            headers.add(name: name, value: value)
        }

        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

        var buffer = allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }
}

// MARK: - HTTP Response Helper

struct HTTPResponse: Sendable {
    let status: HTTPResponseStatus
    let body: Data
    let contentType: String
    let extraHeaders: [(String, String)]

    init(status: HTTPResponseStatus, body: Data, contentType: String, extraHeaders: [(String, String)] = []) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.extraHeaders = extraHeaders
    }

    init(status: HTTPResponseStatus, json: [String: Any]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        self.contentType = "application/json"
        self.extraHeaders = []
    }

    init(status: HTTPResponseStatus, html: String) {
        self.status = status
        self.body = Data(html.utf8)
        self.contentType = "text/html; charset=utf-8"
        self.extraHeaders = []
    }
}
