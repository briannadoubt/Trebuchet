// AuthorizationTests.swift
// Tests for authorization policies

import Testing
import Foundation
@testable import TrebuchetSecurity

@Suite("Authorization Tests")
struct AuthorizationTests {

    // MARK: - RBAC Policy Tests

    @Test("RoleBasedPolicy admin full access")
    func testRBACAdminFullAccess() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "admin", actorType: "*", method: "*")
        ])

        let admin = Principal(id: "admin-1", roles: ["admin"])
        let user = Principal(id: "user-1", roles: ["user"])

        let action = Action(actorType: "GameRoom", method: "join")
        let resource = Resource(type: "room", id: "room-1")

        // Admin should be authorized
        let adminAuthorized = try await policy.authorize(admin, action: action, resource: resource)
        #expect(adminAuthorized)

        // User should not be authorized
        let userAuthorized = try await policy.authorize(user, action: action, resource: resource)
        #expect(!userAuthorized)
    }

    @Test("RoleBasedPolicy method pattern matching")
    func testRBACMethodPatternMatching() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "viewer", actorType: "GameRoom", method: "get*")
        ])

        let viewer = Principal(id: "viewer-1", roles: ["viewer"])

        // Allowed methods (start with "get")
        let getAction = Action(actorType: "GameRoom", method: "getPlayers")
        let getStatusAction = Action(actorType: "GameRoom", method: "getStatus")

        // Disallowed method (doesn't start with "get")
        let joinAction = Action(actorType: "GameRoom", method: "join")

        let resource = Resource(type: "room")

        #expect(try await policy.authorize(viewer, action: getAction, resource: resource))
        #expect(try await policy.authorize(viewer, action: getStatusAction, resource: resource))
        let joinAuthorized = try await policy.authorize(viewer, action: joinAction, resource: resource)
        #expect(!joinAuthorized)
    }

    @Test("RoleBasedPolicy actor type matching")
    func testRBACActorTypeMatching() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "service", actorType: "Internal*", method: "*")
        ])

        let service = Principal(id: "service-1", roles: ["service"])

        let internalAction = Action(actorType: "InternalMetrics", method: "record")
        let publicAction = Action(actorType: "GameRoom", method: "join")

        let resource = Resource(type: "actor")

        #expect(try await policy.authorize(service, action: internalAction, resource: resource))
        let publicAuthorized = try await policy.authorize(service, action: publicAction, resource: resource)
        #expect(!publicAuthorized)
    }

    @Test("RoleBasedPolicy multiple roles")
    func testRBACMultipleRoles() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "admin", actorType: "*", method: "*"),
            .init(role: "user", actorType: "GameRoom", method: "join"),
            .init(role: "user", actorType: "GameRoom", method: "get*")
        ])

        let user = Principal(id: "user-1", roles: ["user"])

        // User can join
        let joinAction = Action(actorType: "GameRoom", method: "join")
        #expect(try await policy.authorize(user, action: joinAction, resource: Resource(type: "room")))

        // User can get
        let getAction = Action(actorType: "GameRoom", method: "getPlayers")
        #expect(try await policy.authorize(user, action: getAction, resource: Resource(type: "room")))

        // User cannot kick
        let kickAction = Action(actorType: "GameRoom", method: "kick")
        let kickAuthorized = try await policy.authorize(user, action: kickAction, resource: Resource(type: "room"))
        #expect(!kickAuthorized)
    }

    @Test("RoleBasedPolicy resource type matching")
    func testRBACResourceTypeMatching() async throws {
        let policy = RoleBasedPolicy(rules: [
            .init(role: "moderator", actorType: "GameRoom", method: "*", resourceType: "public_room"),
            .init(role: "admin", actorType: "GameRoom", method: "*", resourceType: "*")
        ])

        let moderator = Principal(id: "mod-1", roles: ["moderator"])
        let admin = Principal(id: "admin-1", roles: ["admin"])

        let action = Action(actorType: "GameRoom", method: "kick")

        let publicRoom = Resource(type: "public_room", id: "room-1")
        let privateRoom = Resource(type: "private_room", id: "room-2")

        // Moderator can access public rooms
        #expect(try await policy.authorize(moderator, action: action, resource: publicRoom))

        // Moderator cannot access private rooms
        let modPrivateAuthorized = try await policy.authorize(moderator, action: action, resource: privateRoom)
        #expect(!modPrivateAuthorized)

        // Admin can access any room
        #expect(try await policy.authorize(admin, action: action, resource: publicRoom))
        #expect(try await policy.authorize(admin, action: action, resource: privateRoom))
    }

    @Test("RoleBasedPolicy wildcard matching")
    func testRBACWildcardMatching() async throws {
        let policy = RoleBasedPolicy(rules: [
            // Exact match
            .init(role: "exact", actorType: "GameRoom", method: "join"),

            // Prefix match
            .init(role: "prefix", actorType: "Game*", method: "*"),

            // Suffix match
            .init(role: "suffix", actorType: "*", method: "*Players"),

            // Full wildcard
            .init(role: "wildcard", actorType: "*", method: "*")
        ])

        let exactPrincipal = Principal(id: "exact", roles: ["exact"])
        let prefixPrincipal = Principal(id: "prefix", roles: ["prefix"])
        let suffixPrincipal = Principal(id: "suffix", roles: ["suffix"])
        let wildcardPrincipal = Principal(id: "wildcard", roles: ["wildcard"])

        let resource = Resource(type: "test")

        // Exact match
        #expect(try await policy.authorize(
            exactPrincipal,
            action: Action(actorType: "GameRoom", method: "join"),
            resource: resource
        ))
        let exactLeaveAuthorized = try await policy.authorize(
            exactPrincipal,
            action: Action(actorType: "GameRoom", method: "leave"),
            resource: resource
        )
        #expect(!exactLeaveAuthorized)

        // Prefix match
        #expect(try await policy.authorize(
            prefixPrincipal,
            action: Action(actorType: "GameRoom", method: "anything"),
            resource: resource
        ))
        #expect(try await policy.authorize(
            prefixPrincipal,
            action: Action(actorType: "GameLobby", method: "anything"),
            resource: resource
        ))
        let prefixLobbyAuthorized = try await policy.authorize(
            prefixPrincipal,
            action: Action(actorType: "Lobby", method: "anything"),
            resource: resource
        )
        #expect(!prefixLobbyAuthorized)

        // Suffix match
        #expect(try await policy.authorize(
            suffixPrincipal,
            action: Action(actorType: "anything", method: "getPlayers"),
            resource: resource
        ))
        #expect(try await policy.authorize(
            suffixPrincipal,
            action: Action(actorType: "anything", method: "listPlayers"),
            resource: resource
        ))
        let suffixJoinAuthorized = try await policy.authorize(
            suffixPrincipal,
            action: Action(actorType: "anything", method: "join"),
            resource: resource
        )
        #expect(!suffixJoinAuthorized)

        // Full wildcard
        #expect(try await policy.authorize(
            wildcardPrincipal,
            action: Action(actorType: "anything", method: "anything"),
            resource: resource
        ))
    }

    @Test("RoleBasedPolicy predefined rules")
    func testRBACPredefinedRules() async throws {
        let policy = RoleBasedPolicy(rules: [
            .adminFullAccess,
            .userReadOnly,
            .serviceInvoke
        ])

        let admin = Principal(id: "admin", roles: ["admin"])
        let user = Principal(id: "user", roles: ["user"])
        let service = Principal(id: "service", roles: ["service"])

        let resource = Resource(type: "test")

        // Admin full access
        #expect(try await policy.authorize(
            admin,
            action: Action(actorType: "Any", method: "anyMethod"),
            resource: resource
        ))

        // User read only
        #expect(try await policy.authorize(
            user,
            action: Action(actorType: "Any", method: "getUsers"),
            resource: resource
        ))
        let userDeleteAuthorized = try await policy.authorize(
            user,
            action: Action(actorType: "Any", method: "deleteUsers"),
            resource: resource
        )
        #expect(!userDeleteAuthorized)

        // Service full invoke
        #expect(try await policy.authorize(
            service,
            action: Action(actorType: "Any", method: "anyMethod"),
            resource: resource
        ))
    }

    @Test("RoleBasedPolicy predefined policies")
    func testRBACPredefinedPolicies() async throws {
        let adminOnlyPolicy = RoleBasedPolicy.adminOnly

        let admin = Principal(id: "admin", roles: ["admin"])
        let user = Principal(id: "user", roles: ["user"])

        let action = Action(actorType: "Any", method: "anything")
        let resource = Resource(type: "test")

        #expect(try await adminOnlyPolicy.authorize(admin, action: action, resource: resource))
        let userAuthorized = try await adminOnlyPolicy.authorize(user, action: action, resource: resource)
        #expect(!userAuthorized)
    }

    @Test("RoleBasedPolicy deny by default")
    func testRBACDenyByDefault() async throws {
        let denyPolicy = RoleBasedPolicy(rules: [], denyByDefault: true)
        let allowPolicy = RoleBasedPolicy(rules: [], denyByDefault: false)

        let principal = Principal(id: "test", roles: ["test"])
        let action = Action(actorType: "Any", method: "anything")
        let resource = Resource(type: "test")

        let denyAuthorized = try await denyPolicy.authorize(principal, action: action, resource: resource)
        #expect(!denyAuthorized)
        #expect(try await allowPolicy.authorize(principal, action: action, resource: resource))
    }

    // MARK: - Action and Resource Tests

    @Test("Action equality")
    func testActionEquality() {
        let action1 = Action(actorType: "GameRoom", method: "join")
        let action2 = Action(actorType: "GameRoom", method: "join")
        let action3 = Action(actorType: "GameRoom", method: "leave")

        #expect(action1 == action2)
        #expect(action1 != action3)
    }

    @Test("Resource equality")
    func testResourceEquality() {
        let resource1 = Resource(type: "room", id: "1")
        let resource2 = Resource(type: "room", id: "1")
        let resource3 = Resource(type: "room", id: "2")

        #expect(resource1 == resource2)
        #expect(resource1 != resource3)
    }
}
