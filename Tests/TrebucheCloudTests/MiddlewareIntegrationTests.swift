// MiddlewareIntegrationTests.swift
// Tests for middleware chain integration

import Testing
import Foundation
@testable import Trebuchet
@testable import TrebuchetCloud
@testable import TrebuchetObservability
@testable import TrebuchetSecurity

@Suite("Middleware Integration Tests")
struct MiddlewareIntegrationTests {

    // MARK: - Test Middleware

    struct OrderTrackingMiddleware: CloudMiddleware {
        let name: String
        let tracker: OrderTracker

        func process(
            _ envelope: InvocationEnvelope,
            actor: any DistributedActor,
            context: MiddlewareContext,
            next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
        ) async throws -> ResponseEnvelope {
            await tracker.record("\(name).before")
            let response = try await next(envelope, context)
            await tracker.record("\(name).after")
            return response
        }
    }

    actor OrderTracker {
        private var order: [String] = []

        func record(_ event: String) {
            order.append(event)
        }

        func getOrder() -> [String] {
            order
        }

        func reset() {
            order.removeAll()
        }
    }

    // MARK: - Middleware Chain Tests

    @Test("Middleware chain executes in order")
    func testMiddlewareChainOrder() async throws {
        let tracker = OrderTracker()

        let middleware1 = OrderTrackingMiddleware(name: "first", tracker: tracker)
        let middleware2 = OrderTrackingMiddleware(name: "second", tracker: tracker)
        let middleware3 = OrderTrackingMiddleware(name: "third", tracker: tracker)

        let chain = MiddlewareChain(middlewares: [middleware1, middleware2, middleware3])

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "testMethod",
            genericSubstitutions: [],
            arguments: []
        )

        // Create a mock actor
        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)

        let context = MiddlewareContext()

        _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            await tracker.record("handler")
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        let order = await tracker.getOrder()

        #expect(order == [
            "first.before",
            "second.before",
            "third.before",
            "handler",
            "third.after",
            "second.after",
            "first.after"
        ])
    }

    @Test("Empty middleware chain executes handler")
    func testEmptyMiddlewareChain() async throws {
        let chain = MiddlewareChain(middlewares: [])

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "testMethod",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let tracker = OrderTracker()

        _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            await tracker.record("handler")
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        let order = await tracker.getOrder()
        #expect(order == ["handler"])
    }

    // MARK: - Tracing Middleware Tests

    @Test("TracingMiddleware creates and exports spans")
    func testTracingMiddleware() async throws {
        let exporter = InMemorySpanExporter()
        let middleware = TracingMiddleware(exporter: exporter)

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "game-room-1"),
            targetIdentifier: "join",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        let spans = await exporter.getExportedSpans()
        #expect(spans.count == 1)

        let span = spans[0]
        #expect(span.name == "game-room-1.join")
        #expect(span.kind == .server)
        #expect(span.status == .ok)
        #expect(span.attributes["actor.id"] == "game-room-1")
        #expect(span.attributes["actor.target"] == "join")
    }

    // MARK: - Validation Middleware Tests

    @Test("ValidationMiddleware allows valid requests")
    func testValidationMiddlewareAllowsValid() async throws {
        let middleware = ValidationMiddleware.default

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "actor-123"),
            targetIdentifier: "validMethod",
            genericSubstitutions: [],
            arguments: [Data("test".utf8)]
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = try MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        let response = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        #expect(response.callID == envelope.callID)
    }

    @Test("ValidationMiddleware rejects oversized payload")
    func testValidationMiddlewareRejectsOversized() async throws {
        let middleware = ValidationMiddleware(
            configuration: .init(maxPayloadSize: 10)
        )

        let largeData = Data(count: 100)
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "actor-123"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: [largeData]
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = try MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        do {
            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    @Test("ValidationMiddleware rejects invalid method name")
    func testValidationMiddlewareRejectsInvalidMethod() async throws {
        let middleware = ValidationMiddleware.default

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "actor-123"),
            targetIdentifier: "invalid-method!",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = try MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        do {
            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
            #expect(Bool(false), "Should have thrown ValidationError")
        } catch is ValidationError {
            // Expected
        }
    }

    // MARK: - Authentication Middleware Tests

    @Test("AuthenticationMiddleware authenticates valid credentials")
    func testAuthenticationMiddlewareValid() async throws {
        let authenticator = APIKeyAuthenticator()
        await authenticator.register(.init(
            key: "test-key",
            principalId: "user-123",
            roles: ["user"]
        ))

        let middleware = AuthenticationMiddleware(
            provider: authenticator,
            credentialsExtractor: { _ in .apiKey(key: "test-key") }
        )

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            // Verify principal was set
            #expect(context.principal != nil)
            #expect(context.principal?.principal.id == "user-123")
            #expect(context.metadata["principal.id"] == "user-123")
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }
    }

    @Test("AuthenticationMiddleware rejects invalid credentials")
    func testAuthenticationMiddlewareInvalid() async throws {
        let authenticator = APIKeyAuthenticator()

        let middleware = AuthenticationMiddleware(
            provider: authenticator,
            credentialsExtractor: { _ in .apiKey(key: "invalid-key") }
        )

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        do {
            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
            #expect(Bool(false), "Should have thrown AuthenticationError")
        } catch is AuthenticationError {
            // Expected
        }
    }

    // MARK: - Authorization Middleware Tests

    @Test("AuthorizationMiddleware allows authorized requests")
    func testAuthorizationMiddlewareAllowed() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "admin", actorType: "*", method: "*")
        ])

        let middleware = AuthorizationMiddleware(policy: policy)

        let principal = Principal(
            id: "admin-1",
            type: .user,
            roles: ["admin"]
        )

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        var context = MiddlewareContext()
        context.principal = AnyPrincipal(principal)

        let chain = MiddlewareChain(middlewares: [middleware])

        let response = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        #expect(response.callID == envelope.callID)
    }

    @Test("AuthorizationMiddleware denies unauthorized requests")
    func testAuthorizationMiddlewareDenied() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "admin", actorType: "*", method: "*")
        ])

        let middleware = AuthorizationMiddleware(policy: policy)

        let principal = Principal(
            id: "user-1",
            type: .user,
            roles: ["user"]  // Not admin
        )

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        var context = MiddlewareContext()
        context.principal = AnyPrincipal(principal)

        let chain = MiddlewareChain(middlewares: [middleware])

        do {
            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
            #expect(Bool(false), "Should have thrown AuthorizationError")
        } catch is AuthorizationError {
            // Expected
        }
    }

    // MARK: - Rate Limiting Middleware Tests

    @Test("RateLimitingMiddleware allows within limit")
    func testRateLimitingMiddlewareWithinLimit() async throws {
        let limiter = TokenBucketLimiter(requestsPerSecond: 10, burstSize: 10)
        let middleware = RateLimitingMiddleware.global(limiter: limiter)

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        // Should allow first request
        let response = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        #expect(response.callID == envelope.callID)
    }

    @Test("RateLimitingMiddleware denies over limit")
    func testRateLimitingMiddlewareOverLimit() async throws {
        let limiter = TokenBucketLimiter(requestsPerSecond: 2, burstSize: 2)
        let middleware = RateLimitingMiddleware.global(limiter: limiter)

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let chain = MiddlewareChain(middlewares: [middleware])

        // Consume all tokens
        for _ in 1...2 {
            let envelope = InvocationEnvelope(
                callID: UUID(),
                actorID: TrebuchetActorID(id: "test"),
                targetIdentifier: "method",
                genericSubstitutions: [],
                arguments: []
            )

            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
        }

        // Third request should be denied
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "method",
            genericSubstitutions: [],
            arguments: []
        )

        do {
            _ = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
                return ResponseEnvelope.success(callID: envelope.callID, result: Data())
            }
            #expect(Bool(false), "Should have thrown RateLimitError")
        } catch is RateLimitError {
            // Expected
        }
    }

    // MARK: - Full Stack Integration Test

    @Test("Full middleware stack integration")
    func testFullStackIntegration() async throws {
        // Set up all middleware
        let exporter = InMemorySpanExporter()
        let tracingMiddleware = TracingMiddleware(exporter: exporter)

        let validationMiddleware = ValidationMiddleware.default

        let authenticator = APIKeyAuthenticator()
        await authenticator.register(.init(
            key: "valid-key",
            principalId: "admin-1",
            roles: ["admin"]
        ))
        let authenticationMiddleware = AuthenticationMiddleware(
            provider: authenticator,
            credentialsExtractor: { _ in .apiKey(key: "valid-key") }
        )

        let policy = RoleBasedPolicy(rules: [
            .init(role: "admin", actorType: "*", method: "*")
        ])
        let authorizationMiddleware = AuthorizationMiddleware(policy: policy)

        let limiter = TokenBucketLimiter(requestsPerSecond: 10, burstSize: 10)
        let rateLimitingMiddleware = RateLimitingMiddleware.global(limiter: limiter)

        // Create middleware chain in order: validation → rate limiting → authentication → authorization → tracing
        let chain = MiddlewareChain(middlewares: [
            validationMiddleware,
            rateLimitingMiddleware,
            authenticationMiddleware,
            authorizationMiddleware,
            tracingMiddleware
        ])

        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "game-room-1"),
            targetIdentifier: "join",
            genericSubstitutions: [],
            arguments: [Data("player1".utf8)]
        )

        let actorSystem = TrebuchetActorSystem()
        let mockActor = MockActor(actorSystem: actorSystem)
        let context = MiddlewareContext()

        let response = try await chain.execute(envelope, actor: mockActor, context: context) { envelope, context in
            // Verify all middleware processed correctly
            #expect(context.metadata["validation.passed"] == "true")
            #expect(context.metadata["principal.id"] == "admin-1")
            #expect(context.metadata["ratelimit.key"] != nil)

            return ResponseEnvelope.success(callID: envelope.callID, result: Data())
        }

        #expect(response.callID == envelope.callID)

        // Verify span was created
        let spans = await exporter.getExportedSpans()
        #expect(spans.count == 1)
    }
}

// MARK: - Mock Actor

@Trebuchet
private distributed actor MockActor {
    distributed func testMethod() -> String {
        "test"
    }
}
