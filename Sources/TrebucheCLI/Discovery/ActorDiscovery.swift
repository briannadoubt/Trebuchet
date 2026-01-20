import Foundation
import SwiftSyntax
import SwiftParser

/// Discovers distributed actors in Swift source files
public struct ActorDiscovery {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Discover all distributed actors in a directory
    /// - Parameter directory: The directory to search
    /// - Returns: List of discovered actor metadata
    public func discover(in directory: String) throws -> [ActorMetadata] {
        var actors: [ActorMetadata] = []

        let sourcesDir = (directory as NSString).appendingPathComponent("Sources")
        let searchDir = fileManager.fileExists(atPath: sourcesDir) ? sourcesDir : directory

        let swiftFiles = try findSwiftFiles(in: searchDir)

        for file in swiftFiles {
            let fileActors = try discoverActors(in: file)
            actors.append(contentsOf: fileActors)
        }

        return actors
    }

    /// Discover actors in a specific Swift file
    /// - Parameter filePath: Path to the Swift file
    /// - Returns: List of discovered actors
    public func discoverActors(in filePath: String) throws -> [ActorMetadata] {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let sourceFile = Parser.parse(source: source)

        let visitor = ActorVisitor(filePath: filePath, source: source)
        visitor.walk(sourceFile)

        return visitor.actors
    }

    /// Find all Swift files in a directory recursively
    private func findSwiftFiles(in directory: String) throws -> [String] {
        var swiftFiles: [String] = []

        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            return []
        }

        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".swift") {
                let fullPath = (directory as NSString).appendingPathComponent(file)
                swiftFiles.append(fullPath)
            }
        }

        return swiftFiles
    }
}

// MARK: - Syntax Visitor

/// Visits Swift AST to find distributed actors
final class ActorVisitor: SyntaxVisitor {
    let filePath: String
    let source: String
    var actors: [ActorMetadata] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        // Check for 'distributed' modifier
        let isDistributed = node.modifiers.contains { modifier in
            modifier.name.text == "distributed"
        }

        guard isDistributed else {
            return .visitChildren
        }

        let actorName = node.name.text
        let lineNumber = lineNumber(for: node.position)

        // Check for @Trebuchet attribute or TrebuchetActorSystem conformance
        let hasTrebuchetMarker = hasTrebuchetAttribute(node) || hasTrebuchetTypealias(node)

        // Only include actors marked with @Trebuchet or that use TrebuchetActorSystem
        guard hasTrebuchetMarker else {
            return .visitChildren
        }

        // Extract methods
        var methods: [MethodMetadata] = []
        for member in node.memberBlock.members {
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                if let methodMeta = extractMethodMetadata(funcDecl) {
                    methods.append(methodMeta)
                }
            }
        }

        // Check for StatefulActor conformance
        let isStateful = checkStatefulConformance(node)

        // Extract annotations from leading comments
        let annotations = extractAnnotations(node)

        let actor = ActorMetadata(
            name: actorName,
            filePath: filePath,
            lineNumber: lineNumber,
            methods: methods,
            isStateful: isStateful,
            annotations: annotations
        )

        actors.append(actor)

        return .skipChildren
    }

    private func hasTrebuchetAttribute(_ node: ActorDeclSyntax) -> Bool {
        node.attributes.contains { attr in
            if case .attribute(let attribute) = attr {
                let name = attribute.attributeName.description.trimmingCharacters(in: .whitespaces)
                return name == "Trebuchet"
            }
            return false
        }
    }

    private func hasTrebuchetTypealias(_ node: ActorDeclSyntax) -> Bool {
        for member in node.memberBlock.members {
            if let typeAlias = member.decl.as(TypeAliasDeclSyntax.self) {
                if typeAlias.name.text == "ActorSystem" {
                    let type = typeAlias.initializer.value.description.trimmingCharacters(in: .whitespaces)
                    if type == "TrebuchetActorSystem" {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func extractMethodMetadata(_ funcDecl: FunctionDeclSyntax) -> MethodMetadata? {
        // Check for 'distributed' modifier
        let isDistributed = funcDecl.modifiers.contains { modifier in
            modifier.name.text == "distributed"
        }

        guard isDistributed else {
            return nil
        }

        let methodName = funcDecl.name.text

        // Build signature
        var signatureParts: [String] = []
        var parameters: [ParameterMetadata] = []

        for param in funcDecl.signature.parameterClause.parameters {
            let label = param.firstName.text
            let name = param.secondName?.text ?? label
            let type = param.type.description.trimmingCharacters(in: .whitespaces)

            let labelPart = label == "_" ? "" : label
            signatureParts.append("\(labelPart):")

            parameters.append(ParameterMetadata(
                label: label == "_" ? nil : label,
                name: name,
                type: type
            ))
        }

        let signature = "\(methodName)(\(signatureParts.joined()))"

        // Return type
        var returnType: String? = nil
        if let returnClause = funcDecl.signature.returnClause {
            returnType = returnClause.type.description.trimmingCharacters(in: .whitespaces)
        }

        // Check throws
        let throwsEffect = funcDecl.signature.effectSpecifiers?.throwsClause != nil

        return MethodMetadata(
            name: methodName,
            signature: signature,
            parameters: parameters,
            returnType: returnType,
            canThrow: throwsEffect
        )
    }

    private func checkStatefulConformance(_ node: ActorDeclSyntax) -> Bool {
        guard let inheritanceClause = node.inheritanceClause else {
            return false
        }

        for inherited in inheritanceClause.inheritedTypes {
            let typeName = inherited.type.description.trimmingCharacters(in: .whitespaces)
            if typeName == "StatefulActor" {
                return true
            }
        }

        return false
    }

    private func extractAnnotations(_ node: ActorDeclSyntax) -> [String: String] {
        var annotations: [String: String] = [:]

        // Look for special comments like // @trebuche:memory=1024
        let trivia = node.leadingTrivia.description
        let lines = trivia.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("// @trebuche:") || trimmed.hasPrefix("/// @trebuche:") {
                let content = trimmed.replacingOccurrences(of: "// @trebuche:", with: "")
                    .replacingOccurrences(of: "/// @trebuche:", with: "")
                let parts = content.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    annotations[key] = value
                }
            }
        }

        return annotations
    }

    private func lineNumber(for position: AbsolutePosition) -> Int {
        let sourcePrefix = source.prefix(position.utf8Offset)
        return sourcePrefix.filter { $0 == "\n" }.count + 1
    }
}
