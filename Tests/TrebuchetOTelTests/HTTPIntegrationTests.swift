import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TrebuchetOTel

@Suite("HTTP Integration Tests", .serialized)
struct HTTPIntegrationTests {

    // MARK: - Helpers

    private func startServer(authToken: String? = nil) async throws -> (server: OTelHTTPServer, port: Int, store: SpanStore, ingester: SpanIngester) {
        let path = NSTemporaryDirectory() + "otel-http-test-\(UUID().uuidString).sqlite"
        let store = try SpanStore(path: path)
        let ingester = SpanIngester(store: store)
        let port = Int.random(in: 30000...40000)
        let server = try await OTelHTTPServer(host: "127.0.0.1", port: port, ingester: ingester, store: store, authToken: authToken)
        Task { try await server.run() }
        // Brief pause to let the server bind
        try await Task.sleep(for: .milliseconds(100))
        return (server, port, store, ingester)
    }

    private func makeTracesJSON(
        traceId: String = "aaaabbbbccccdddd1111222233334444",
        spanId: String = "1111222233334444",
        operationName: String = "test-operation",
        serviceName: String = "test-svc",
        statusCode: Int = 1
    ) -> Data {
        let json = """
        {
          "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "\(serviceName)"}}]},
            "scopeSpans": [{
              "scope": {"name": "test"},
              "spans": [{
                "traceId": "\(traceId)",
                "spanId": "\(spanId)",
                "name": "\(operationName)",
                "kind": 2,
                "startTimeUnixNano": "1700000000000000000",
                "endTimeUnixNano": "1700000001000000000",
                "status": {"code": \(statusCode)}
              }]
            }]
          }]
        }
        """
        return Data(json.utf8)
    }

    private func makeLogsJSON(
        traceId: String = "aaaabbbbccccdddd1111222233334444",
        spanId: String = "1111222233334444",
        body: String = "Server started",
        serviceName: String = "test-svc",
        severityNumber: Int = 9,
        severityText: String = "INFO"
    ) -> Data {
        let json = """
        {
          "resourceLogs": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "\(serviceName)"}}]},
            "scopeLogs": [{
              "logRecords": [{
                "timeUnixNano": "1700000000000000000",
                "severityNumber": \(severityNumber),
                "severityText": "\(severityText)",
                "body": {"stringValue": "\(body)"},
                "traceId": "\(traceId)",
                "spanId": "\(spanId)"
              }]
            }]
          }]
        }
        """
        return Data(json.utf8)
    }

    private func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func post(_ url: URL, body: Data, headers: [String: String] = [:], contentType: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - Tests

    @Test func testHealthEndpoint() async throws {
        let (server, port, _, _) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await get(url)

        #expect(response.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["status"] as? String == "ok")
    }

    @Test func testIngestAndQueryTraces() async throws {
        let (server, port, _, ingester) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        let traceId = "httptest1111111111111111aaaaaaaa"
        let tracesBody = makeTracesJSON(traceId: traceId, spanId: "httpspan00000001", operationName: "http-test-op", serviceName: "http-test-svc")

        // Ingest
        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/traces")!
        let (_, ingestResponse) = try await post(ingestURL, body: tracesBody)
        #expect(ingestResponse.statusCode == 200)

        // Flush the ingester to ensure data is written
        await ingester.flush()

        // Query
        let queryURL = URL(string: "http://127.0.0.1:\(port)/api/traces")!
        let (queryData, queryResponse) = try await get(queryURL)
        #expect(queryResponse.statusCode == 200)

        let page = try JSONDecoder().decode(TracePage.self, from: queryData)
        #expect(page.traces.count >= 1)
        let found = page.traces.first(where: { $0.traceId == traceId })
        #expect(found != nil)
        #expect(found?.rootOperation == "http-test-op")
    }

    @Test func testIngestAndQueryLogs() async throws {
        let (server, port, _, _) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        let logsBody = makeLogsJSON(body: "HTTP integration log", serviceName: "log-test-svc")

        // Ingest
        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/logs")!
        let (_, ingestResponse) = try await post(ingestURL, body: logsBody)
        #expect(ingestResponse.statusCode == 200)

        // Query
        let queryURL = URL(string: "http://127.0.0.1:\(port)/api/logs")!
        let (queryData, queryResponse) = try await get(queryURL)
        #expect(queryResponse.statusCode == 200)

        let page = try JSONDecoder().decode(LogPage.self, from: queryData)
        #expect(page.logs.count >= 1)
        #expect(page.logs.first?.body == "HTTP integration log")
    }

    @Test func testTraceDetail() async throws {
        let (server, port, _, ingester) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        let traceId = "detailtest11111111111111aaaaaaaa"
        let tracesBody = makeTracesJSON(traceId: traceId, spanId: "detailspan000001", operationName: "detail-op")

        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/traces")!
        let (_, ingestResponse) = try await post(ingestURL, body: tracesBody)
        #expect(ingestResponse.statusCode == 200)

        await ingester.flush()

        // Get trace detail
        let detailURL = URL(string: "http://127.0.0.1:\(port)/api/traces/\(traceId)")!
        let (detailData, detailResponse) = try await get(detailURL)
        #expect(detailResponse.statusCode == 200)

        let spans = try JSONDecoder().decode([SpanRecord].self, from: detailData)
        #expect(spans.count == 1)
        #expect(spans[0].traceId == traceId)
        #expect(spans[0].operationName == "detail-op")
    }

    @Test func testServicesEndpoint() async throws {
        let (server, port, _, ingester) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        // Ingest spans for two different services
        let body1 = makeTracesJSON(traceId: "svcep1111111111111111111aaaaaaa", spanId: "svcepspan0000001", serviceName: "alpha-service")
        let body2 = makeTracesJSON(traceId: "svcep2222222222222222222bbbbbbb", spanId: "svcepspan0000002", serviceName: "beta-service")

        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/traces")!
        let (_, r1) = try await post(ingestURL, body: body1)
        #expect(r1.statusCode == 200)
        let (_, r2) = try await post(ingestURL, body: body2)
        #expect(r2.statusCode == 200)

        await ingester.flush()

        let servicesURL = URL(string: "http://127.0.0.1:\(port)/api/services")!
        let (servicesData, servicesResponse) = try await get(servicesURL)
        #expect(servicesResponse.statusCode == 200)

        let services = try JSONDecoder().decode([String].self, from: servicesData)
        #expect(services.contains("alpha-service"))
        #expect(services.contains("beta-service"))
    }

    @Test func testDashboardServed() async throws {
        let (server, port, _, _) = try await startServer()
        defer { Task { try? await server.shutdown() } }

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, response) = try await get(url)
        #expect(response.statusCode == 200)

        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("TrebuchetOTel"))
    }

    @Test func testAuthBlocksWithoutToken() async throws {
        let (server, port, _, _) = try await startServer(authToken: "test-secret")
        defer { Task { try? await server.shutdown() } }

        // Use ephemeral session to avoid cookie leakage from other tests
        let config = URLSessionConfiguration.ephemeral
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        // API endpoint should return 401 without auth
        let apiURL = URL(string: "http://127.0.0.1:\(port)/api/traces")!
        var apiRequest = URLRequest(url: apiURL)
        apiRequest.httpMethod = "GET"
        let (_, apiResponse) = try await session.data(for: apiRequest)
        let apiHTTP = apiResponse as! HTTPURLResponse
        #expect(apiHTTP.statusCode == 401)

        // OTLP ingestion without Bearer should return 401
        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/traces")!
        var ingestRequest = URLRequest(url: ingestURL)
        ingestRequest.httpMethod = "POST"
        ingestRequest.httpBody = makeTracesJSON()
        ingestRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, ingestResponse) = try await session.data(for: ingestRequest)
        let ingestHTTP = ingestResponse as! HTTPURLResponse
        #expect(ingestHTTP.statusCode == 401)

        // Dashboard root should redirect to login (303)
        let rootURL = URL(string: "http://127.0.0.1:\(port)/")!
        var rootRequest = URLRequest(url: rootURL)
        rootRequest.httpMethod = "GET"
        let (_, rootResponse) = try await session.data(for: rootRequest)
        let rootHTTPResponse = rootResponse as! HTTPURLResponse
        #expect(rootHTTPResponse.statusCode == 303)
    }

    @Test func testAuthAllowsWithToken() async throws {
        let (server, port, _, ingester) = try await startServer(authToken: "test-secret")
        defer { Task { try? await server.shutdown() } }

        // OTLP ingestion with Bearer should succeed
        let ingestURL = URL(string: "http://127.0.0.1:\(port)/v1/traces")!
        let traceId = "authtest1111111111111111aaaaaaaa"
        let body = makeTracesJSON(traceId: traceId, spanId: "authspan00000001")

        let (_, ingestResponse) = try await post(ingestURL, body: body, headers: ["Authorization": "Bearer test-secret"])
        #expect(ingestResponse.statusCode == 200)

        await ingester.flush()

        // Now query with a session cookie (simulate login)
        // First, login to get the cookie
        let loginURL = URL(string: "http://127.0.0.1:\(port)/login")!
        let loginBody = "token=test-secret"
        let config = URLSessionConfiguration.default
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.httpBody = Data(loginBody.utf8)
        loginRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (_, loginResponse) = try await session.data(for: loginRequest)
        let loginHTTPResponse = loginResponse as! HTTPURLResponse
        #expect(loginHTTPResponse.statusCode == 303)

        // Extract session cookie
        let setCookie = loginHTTPResponse.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        #expect(setCookie.contains("otel_session="))

        // Extract just the cookie value for subsequent requests
        let cookieValue = setCookie.split(separator: ";").first.map(String.init) ?? ""

        // Query traces with the session cookie
        let queryURL = URL(string: "http://127.0.0.1:\(port)/api/traces")!
        let (queryData, queryResponse) = try await get(queryURL, headers: ["Cookie": cookieValue])
        #expect(queryResponse.statusCode == 200)

        let page = try JSONDecoder().decode(TracePage.self, from: queryData)
        #expect(page.traces.count >= 1)
    }

    @Test func testLoginFlow() async throws {
        let (server, port, _, _) = try await startServer(authToken: "test-secret")
        defer { Task { try? await server.shutdown() } }

        let config = URLSessionConfiguration.default
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        // GET /login should return login page
        let loginPageURL = URL(string: "http://127.0.0.1:\(port)/login")!
        let (loginPageData, loginPageResponse) = try await session.data(for: URLRequest(url: loginPageURL))
        let loginPageHTTP = loginPageResponse as! HTTPURLResponse
        #expect(loginPageHTTP.statusCode == 200)
        let loginHTML = String(data: loginPageData, encoding: .utf8) ?? ""
        #expect(loginHTML.contains("login") || loginHTML.contains("Login") || loginHTML.contains("token"))

        // POST /login with correct token should redirect with Set-Cookie
        let loginURL = URL(string: "http://127.0.0.1:\(port)/login")!
        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.httpBody = Data("token=test-secret".utf8)
        loginRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (_, loginResponse) = try await session.data(for: loginRequest)
        let loginHTTP = loginResponse as! HTTPURLResponse
        #expect(loginHTTP.statusCode == 303)

        let location = loginHTTP.value(forHTTPHeaderField: "Location")
        #expect(location == "/")

        let setCookie = loginHTTP.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        #expect(setCookie.contains("otel_session="))
        #expect(setCookie.contains("HttpOnly"))

        // POST /login with wrong token should show error
        var badLoginRequest = URLRequest(url: loginURL)
        badLoginRequest.httpMethod = "POST"
        badLoginRequest.httpBody = Data("token=wrong-token".utf8)
        badLoginRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (badData, badResponse) = try await session.data(for: badLoginRequest)
        let badHTTP = badResponse as! HTTPURLResponse
        #expect(badHTTP.statusCode == 200) // Returns login page with error
        let badHTML = String(data: badData, encoding: .utf8) ?? ""
        #expect(badHTML.contains("Invalid") || badHTML.contains("invalid") || badHTML.contains("error"))
    }
}

// MARK: - URLSession delegate to prevent auto-redirect

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Return nil to prevent following redirects
        completionHandler(nil)
    }
}
