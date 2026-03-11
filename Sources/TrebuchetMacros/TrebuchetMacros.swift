import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The @Trebuchet macro simplifies distributed actor declarations by:
/// 1. Adding `typealias ActorSystem = TrebuchetRuntime` if not present
/// 2. Adding conformance to `TrebuchetActor` protocol
/// 3. Scanning for @StreamedState properties and generating observe methods
/// 4. Providing integration with TrebuchetServer/TrebuchetClient
///
/// Note: Streaming protocols must be manually created for each actor.
public struct TrebuchetMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Check if this is a distributed actor
        guard let actorDecl = declaration.as(ActorDeclSyntax.self),
              actorDecl.modifiers.contains(where: { $0.name.text == "distributed" }) else {
            throw MacroError.notDistributedActor
        }

        // Check if ActorSystem typealias already exists
        let hasActorSystemTypealias = actorDecl.memberBlock.members.contains { member in
            if let typealiasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
                return typealiasDecl.name.text == "ActorSystem"
            }
            return false
        }

        var members: [DeclSyntax] = []

        // Add ActorSystem typealias if not present
        if !hasActorSystemTypealias {
            members.append("public typealias ActorSystem = TrebuchetRuntime")
        }

        let streamedProperties = streamedStateProperties(in: actorDecl)

        for (propertyName, propertyType) in streamedProperties {

            // Generate observe method name: observePropertyName
            let observeMethodName = "observe\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())"
            let cleanupMethodName = "_cleanup\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())Continuation"

            // Generate actor-isolated async observe method
            // Actor isolation ensures safe access to continuations dictionary
            let observeMethod: DeclSyntax = """
                public func \(raw: observeMethodName)() async -> AsyncStream<\(propertyType)> {
                    let id = UUID()

                    return AsyncStream { continuation in
                        _\(raw: propertyName)_continuations[id] = continuation
                        #if !os(WASI)
                        TrebuchetStreamInstrumentation.streamSubscriptionStarted(
                            property: "\(raw: propertyName)",
                            actorID: "\\(self.id)",
                            streamID: "\\(id)",
                            subscriberCount: _\(raw: propertyName)_continuations.count
                        )
                        #endif
                        continuation.yield(_\(raw: propertyName)_storage)

                        continuation.onTermination = { @Sendable [weak self, id] _ in
                            Task {
                                try? await self?.\(raw: cleanupMethodName)(id)
                            }
                        }
                    }
                }
                """

            // Generate distributed cleanup method (private, so only callable from within actor)
            let cleanupMethod: DeclSyntax = """
                private distributed func \(raw: cleanupMethodName)(_ id: UUID) {
                    _\(raw: propertyName)_continuations.removeValue(forKey: id)
                }
                """

            members.append(observeMethod)
            members.append(cleanupMethod)
        }

        // Generate streaming method enum if there are streaming properties
        if !streamedProperties.isEmpty {
            var enumCases: [String] = []
            var streamCases: [String] = []

            for (propertyName, _) in streamedProperties {
                let capitalizedName = propertyName.prefix(1).uppercased() + propertyName.dropFirst()
                let observeMethodName = "observe\(capitalizedName)"
                enumCases.append("        case \(observeMethodName)")
                streamCases.append(
                    """
                            case "\(observeMethodName)":
                                guard let stream = await self.whenLocal({ actor in
                                    await actor.\(observeMethodName)()
                                }) else {
                                    return nil
                                }
                                return Self._encodeStream(stream)
                    """
                )
            }

            let enumDecl: DeclSyntax = """
                /// Type-safe enum for streaming methods
                public enum StreamingMethod: String, Codable, Sendable, CaseIterable {
                \(raw: enumCases.joined(separator: "\n"))
                }
                """

            let streamSwitchBody = streamCases.joined(separator: "\n")

            let streamBridgeDecl: DeclSyntax = """
                public nonisolated func _getStream(for propertyName: String) async -> AsyncStream<Data>? {
                    switch propertyName {
                    \(raw: streamSwitchBody)
                    default:
                        return nil
                    }
                }
                """

            let encoderDecl: DeclSyntax = """
                private nonisolated static func _encodeStream<T: Codable & Sendable>(_ stream: AsyncStream<T>) -> AsyncStream<Data> {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601

                    return AsyncStream { continuation in
                        Task {
                            for await value in stream {
                                if let data = try? encoder.encode(value) {
                                    continuation.yield(data)
                                }
                            }
                            continuation.finish()
                        }
                    }
                }
                """

            members.append(enumDecl)
            members.append(streamBridgeDecl)
            members.append(encoderDecl)
        }

        return members
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Check if this is a distributed actor
        guard let actorDecl = declaration.as(ActorDeclSyntax.self),
              actorDecl.modifiers.contains(where: { $0.name.text == "distributed" }) else {
            throw MacroError.notDistributedActor
        }

        // Add TrebuchetActor conformance via extension
        let trebuchetActorExtension: DeclSyntax = """
            extension \(type.trimmed): TrebuchetActor {}
            """

        guard let trebuchetActorExtensionSyntax = trebuchetActorExtension.as(ExtensionDeclSyntax.self) else {
            return []
        }

        var extensions: [ExtensionDeclSyntax] = [trebuchetActorExtensionSyntax]

        if !streamedStateProperties(in: actorDecl).isEmpty {
            let streamingActorExtension: DeclSyntax = """
                extension \(type.trimmed): StreamingActor {}
                """

            if let syntax = streamingActorExtension.as(ExtensionDeclSyntax.self) {
                extensions.append(syntax)
            }
        }

        return extensions
    }

    private static func streamedStateProperties(in actorDecl: ActorDeclSyntax) -> [(name: String, type: TypeSyntax)] {
        var properties: [(name: String, type: TypeSyntax)] = []

        for member in actorDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let hasStreamedState = varDecl.attributes.contains { attribute in
                guard case let .attribute(attr) = attribute,
                      let identifierType = attr.attributeName.as(IdentifierTypeSyntax.self) else {
                    return false
                }
                return identifierType.name.text == "StreamedState"
            }

            guard hasStreamedState else { continue }

            guard let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation else {
                continue
            }

            properties.append((identifier.identifier.text, typeAnnotation.type))
        }

        return properties
    }
}

/// The @StreamedState macro transforms a property into a streaming state property.
/// It generates:
/// 1. Backing storage (_X_storage)
/// 2. Continuation storage (_X_continuations)
/// 3. Computed property with getter/setter that notifies on changes
/// 4. Notification helper method (_notifyXChange)
public struct StreamedStateMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              let _ = binding.typeAnnotation else {
            throw MacroError.invalidStreamedStateUsage
        }

        let propertyName = identifier.identifier.text

        // Generate getter and setter
        let getter: AccessorDeclSyntax = """
            get { _\(raw: propertyName)_storage }
            """

        let setter: AccessorDeclSyntax = """
            set {
                _\(raw: propertyName)_storage = newValue
                _notify\(raw: propertyName.prefix(1).uppercased())\(raw: propertyName.dropFirst())Change()
            }
            """

        return [getter, setter]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              let typeAnnotation = binding.typeAnnotation else {
            throw MacroError.invalidStreamedStateUsage
        }

        let propertyName = identifier.identifier.text
        let propertyType = typeAnnotation.type
        let initialValue = binding.initializer?.value

        var peers: [DeclSyntax] = []

        // Generate backing storage
        if let initialValue = initialValue {
            peers.append("""
                private var _\(raw: propertyName)_storage: \(propertyType) = \(initialValue)
                """)
        } else {
            peers.append("""
                private var _\(raw: propertyName)_storage: \(propertyType)
                """)
        }

        // Generate continuation storage (optional values to handle reservation)
        peers.append("""
            private var _\(raw: propertyName)_continuations: [UUID: AsyncStream<\(propertyType)>.Continuation?] = [:]
            """)

        // Generate notification method
        peers.append("""
            private func _notify\(raw: propertyName.prefix(1).uppercased())\(raw: propertyName.dropFirst())Change() {
                #if !os(WASI)
                TrebuchetStreamInstrumentation.stateChanged(
                    property: "\(raw: propertyName)",
                    subscriberCount: _\(raw: propertyName)_continuations.count
                )
                #endif
                for continuation in _\(raw: propertyName)_continuations.values {
                    continuation?.yield(_\(raw: propertyName)_storage)
                }
            }
            """)

        return peers
    }
}

public enum MacroError: Error, CustomStringConvertible {
    case notDistributedActor
    case invalidStreamedStateUsage

    public var description: String {
        switch self {
        case .notDistributedActor:
            return "@Trebuchet can only be applied to distributed actors"
        case .invalidStreamedStateUsage:
            return "@StreamedState can only be applied to stored properties with explicit type annotations"
        }
    }
}

@main
struct TrebuchetMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TrebuchetMacro.self,
        StreamedStateMacro.self,
    ]
}
