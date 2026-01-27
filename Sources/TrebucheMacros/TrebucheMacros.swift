import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The @Trebuchet macro simplifies distributed actor declarations by:
/// 1. Adding `typealias ActorSystem = TrebuchetActorSystem` if not present
/// 2. Scanning for @StreamedState properties and generating observe methods
/// 3. Providing integration with TrebuchetServer/TrebuchetClient
public struct TrebuchetMacro: MemberMacro {
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
            members.append("public typealias ActorSystem = TrebuchetActorSystem")
        }

        // Collect @StreamedState properties
        var streamedProperties: [(name: String, type: TypeSyntax)] = []

        for member in actorDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            // Check if property has @StreamedState attribute
            let hasStreamedState = varDecl.attributes.contains { attribute in
                guard case let .attribute(attr) = attribute,
                      let identifierType = attr.attributeName.as(IdentifierTypeSyntax.self) else {
                    return false
                }
                return identifierType.name.text == "StreamedState"
            }

            guard hasStreamedState else { continue }

            // Extract property name and type
            guard let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation else {
                continue
            }

            let propertyName = identifier.identifier.text
            let propertyType = typeAnnotation.type

            streamedProperties.append((propertyName, propertyType))

            // Generate observe method name: observePropertyName
            let observeMethodName = "observe\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())"
            let cleanupMethodName = "_cleanup\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())Continuation"

            // Generate actor-isolated async observe method with cleanup
            let observeMethod: DeclSyntax = """
                public func \(raw: observeMethodName)() async -> AsyncStream<\(propertyType)> {
                    let id = UUID()
                    _\(raw: propertyName)_continuations[id] = nil // Reserve slot

                    return AsyncStream { continuation in
                        _\(raw: propertyName)_continuations[id] = continuation
                        continuation.yield(_\(raw: propertyName)_storage)

                        continuation.onTermination = { @Sendable [id, self] _ in
                            Task {
                                try? await self.\(raw: cleanupMethodName)(id)
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
            for (propertyName, _) in streamedProperties {
                let observeMethodName = "observe\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())"
                enumCases.append("        case \(observeMethodName)")
            }

            let enumDecl: DeclSyntax = """
                /// Type-safe enum for streaming methods
                public enum StreamingMethod: String, Codable, Sendable, CaseIterable {
                \(raw: enumCases.joined(separator: "\n"))
                }
                """

            members.append(enumDecl)
        }

        return members
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
                for continuation in _\(raw: propertyName)_continuations.values {
                    continuation?.yield(_\(raw: propertyName)_storage)
                }
            }
            """)

        return peers
    }
}

enum MacroError: Error, CustomStringConvertible {
    case notDistributedActor
    case invalidStreamedStateUsage

    var description: String {
        switch self {
        case .notDistributedActor:
            return "@Trebuchet can only be applied to distributed actors"
        case .invalidStreamedStateUsage:
            return "@StreamedState can only be applied to stored properties with explicit type annotations"
        }
    }
}

@main
struct TrebucheMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TrebuchetMacro.self,
        StreamedStateMacro.self,
    ]
}
