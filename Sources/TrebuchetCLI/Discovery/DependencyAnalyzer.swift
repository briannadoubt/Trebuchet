import Foundation
import SwiftSyntax
import SwiftParser

/// Analyzes Swift files to discover type dependencies
public struct DependencyAnalyzer {
    let projectPath: String
    let fileManager: FileManager

    public init(projectPath: String, fileManager: FileManager = .default) {
        self.projectPath = projectPath
        self.fileManager = fileManager
    }

    /// Find all Swift files needed by the given actors
    /// - Parameter actors: Discovered actor metadata
    /// - Returns: Set of file paths that should be copied
    public func findDependencies(for actors: [ActorMetadata]) throws -> Set<String> {
        var requiredFiles = Set<String>()
        var requiredTypes = Set<String>()

        // First pass: collect all types used in actor signatures
        for actor in actors {
            // Add the actor's file
            requiredFiles.insert(actor.filePath)

            // Collect types from method signatures
            for method in actor.methods {
                // Parameter types
                for param in method.parameters {
                    requiredTypes.insert(param.type)
                    requiredTypes.formUnion(extractNestedTypes(from: param.type))
                }

                // Return type
                if let returnType = method.returnType {
                    requiredTypes.insert(returnType)
                    requiredTypes.formUnion(extractNestedTypes(from: returnType))
                }
            }
        }

        // Filter out standard library and Trebuchet types
        requiredTypes = requiredTypes.filter { !isStandardType($0) }

        // Second pass: find files containing these types
        let sourceFiles = try findAllSwiftFiles()
        var processedTypes = Set<String>()

        while !requiredTypes.isEmpty {
            let typeToProcess = requiredTypes.removeFirst()

            // Skip if already processed
            if processedTypes.contains(typeToProcess) {
                continue
            }
            processedTypes.insert(typeToProcess)

            // Find the file defining this type
            guard let filePath = try findFile(defining: typeToProcess, in: sourceFiles) else {
                continue
            }

            // Add the file if not already included
            if !requiredFiles.contains(filePath) {
                requiredFiles.insert(filePath)
            }

            // CRITICAL: Only analyze dependencies of THIS specific type
            // This prevents cascade from other types in the same file
            let typeDeps = try findDependencies(ofType: typeToProcess, in: filePath)
            requiredTypes.formUnion(typeDeps.filter { !isStandardType($0) && !processedTypes.contains($0) })
        }

        return requiredFiles
    }

    // MARK: - Private Helpers

    /// Extract nested types from a type string (e.g., "Array<Player>" -> ["Array", "Player"])
    private func extractNestedTypes(from typeString: String) -> Set<String> {
        var types = Set<String>()

        // Remove whitespace
        let cleaned = typeString.replacingOccurrences(of: " ", with: "")

        // Extract generic parameters: Type<A, B<C>>
        let genericPattern = #"<([^<>]+(?:<[^<>]+>)*)>"#
        if let regex = try? NSRegularExpression(pattern: genericPattern) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            regex.enumerateMatches(in: cleaned, range: range) { match, _, _ in
                if let match = match,
                   let matchRange = Range(match.range(at: 1), in: cleaned) {
                    let generics = String(cleaned[matchRange])
                    // Split by comma and recursively extract
                    for part in generics.split(separator: ",") {
                        types.formUnion(extractNestedTypes(from: String(part)))
                    }
                }
            }
        }

        // Extract base type (remove generics and optionals)
        let baseType = cleaned
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .components(separatedBy: ".").last ?? cleaned

        if !baseType.isEmpty && !isStandardType(baseType) {
            types.insert(baseType)
        }

        return types
    }

    /// Check if a type is from stdlib or Trebuchet
    private func isStandardType(_ type: String) -> Bool {
        let standardTypes: Set<String> = [
            // Swift stdlib
            "String", "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Bool", "Void",
            "Array", "Dictionary", "Set", "Optional",
            "Result", "Never", "Any", "AnyObject",
            // Foundation
            "Data", "Date", "URL", "UUID", "Decimal",
            "NSObject", "NSString", "NSArray", "NSDictionary",
            // Trebuchet
            "TrebuchetActorSystem", "TrebuchetActorID", "TrebuchetError",
            // Distributed actor system
            "DistributedActor", "DistributedActorSystem",
            // Swift concurrency
            "Task", "AsyncStream", "AsyncThrowingStream"
        ]

        return standardTypes.contains(type)
    }

    /// Find all Swift files in the project
    private func findAllSwiftFiles() throws -> [String] {
        var swiftFiles: [String] = []

        // Search in Sources/ directory if it exists
        let sourcesDir = "\(projectPath)/Sources"
        let searchDir = fileManager.fileExists(atPath: sourcesDir) ? sourcesDir : projectPath

        guard let enumerator = fileManager.enumerator(atPath: searchDir) else {
            return []
        }

        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".swift") {
                // Skip test files
                if !file.contains("Test") && !file.contains(".build") {
                    let fullPath = (searchDir as NSString).appendingPathComponent(file)
                    swiftFiles.append(fullPath)
                }
            }
        }

        return swiftFiles
    }

    /// Find all type definitions in a Swift file
    private func findDefinedTypes(in filePath: String) throws -> Set<String> {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let sourceFile = Parser.parse(source: source)

        let visitor = TypeDefinitionVisitor()
        visitor.walk(sourceFile)

        return visitor.definedTypes
    }

    /// Find the file that defines a specific type
    private func findFile(defining typeName: String, in files: [String]) throws -> String? {
        for filePath in files {
            let definedTypes = try findDefinedTypes(in: filePath)
            if definedTypes.contains(typeName) {
                return filePath
            }
        }
        return nil
    }

    /// Find dependencies of a SPECIFIC type within a file
    /// This prevents cascade from other unrelated types in the same file
    private func findDependencies(ofType typeName: String, in filePath: String) throws -> Set<String> {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let sourceFile = Parser.parse(source: source)

        // Find the specific type declaration
        let typeExtractor = SpecificTypeExtractor(targetName: typeName)
        typeExtractor.walk(sourceFile)

        guard let typeDeclaration = typeExtractor.foundDeclaration else {
            return []
        }

        // Only analyze dependencies within THIS type's declaration
        let visitor = TypeUsageVisitor()
        visitor.walk(Syntax(typeDeclaration))

        return visitor.usedTypes
    }

    /// Find dependencies in a Swift file (types used but not defined)
    /// DEPRECATED: Use findDependencies(ofType:in:) instead to prevent cascade
    private func findDependencies(in filePath: String) throws -> Set<String> {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let sourceFile = Parser.parse(source: source)

        let visitor = TypeUsageVisitor()
        visitor.walk(sourceFile)

        return visitor.usedTypes
    }
}

// MARK: - Syntax Visitors

/// Visits Swift AST to find type definitions
final class TypeDefinitionVisitor: SyntaxVisitor {
    var definedTypes = Set<String>()

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }
}

/// Visits Swift AST to find type usages
final class TypeUsageVisitor: SyntaxVisitor {
    var usedTypes = Set<String>()

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        if !typeName.isEmpty {
            usedTypes.insert(typeName)
        }
        return .visitChildren
    }
}

/// Extracts a specific type declaration from the AST
final class SpecificTypeExtractor: SyntaxVisitor {
    let targetName: String
    var foundDeclaration: (any DeclSyntaxProtocol)?

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            foundDeclaration = node
            return .skipChildren
        }
        return .visitChildren
    }
}
