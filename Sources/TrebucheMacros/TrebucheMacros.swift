import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// The @Trebuchet macro simplifies distributed actor declarations by:
/// 1. Adding `typealias ActorSystem = TrebuchetActorSystem` if not present
/// 2. Providing integration with TrebuchetServer/TrebuchetClient
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

        return members
    }
}

enum MacroError: Error, CustomStringConvertible {
    case notDistributedActor

    var description: String {
        switch self {
        case .notDistributedActor:
            return "@Trebuchet can only be applied to distributed actors"
        }
    }
}

@main
struct TrebucheMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TrebuchetMacro.self,
    ]
}
