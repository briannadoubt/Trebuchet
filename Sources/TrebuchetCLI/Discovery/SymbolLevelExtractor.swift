import Foundation
import SwiftSyntax
import SwiftParser

/// Symbol-level extractor - extracts only needed types from files
struct SymbolLevelExtractor {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Extract specific types from files
    func extract(
        types: Set<String>,
        fromFiles files: Set<String>,
        to targetPath: String
    ) throws {
        // Group types by source file
        var typesByFile: [String: Set<String>] = [:]

        for file in files {
            let definedTypes = try findDefinedTypes(in: file)
            let neededTypes = types.intersection(definedTypes)

            if !neededTypes.isEmpty {
                typesByFile[file] = neededTypes
            }
        }

        // Extract and write each file
        for (sourceFile, typesToExtract) in typesByFile {
            let fileName = URL(fileURLWithPath: sourceFile).lastPathComponent
            let targetFile = "\(targetPath)/\(fileName)"

            let extractedContent = try extractTypes(
                typesToExtract,
                from: sourceFile
            )

            try extractedContent.write(
                toFile: targetFile,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    // MARK: - Type Discovery

    private func findDefinedTypes(in filePath: String) throws -> Set<String> {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let parsed = Parser.parse(source: source)

        let visitor = TypeDefinitionCollector()
        visitor.walk(parsed)

        return visitor.definedTypes
    }

    // MARK: - Type Extraction

    private func extractTypes(_ types: Set<String>, from filePath: String) throws -> String {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let parsed = Parser.parse(source: source)

        var components: [String] = []

        // 1. Extract imports
        let imports = extractImports(from: parsed)
        if !imports.isEmpty {
            components.append(imports)
        }

        // 2. Extract file-level declarations that might be needed
        let fileLevelDecls = try extractFileLevelDeclarations(
            from: parsed,
            neededBy: types,
            source: source
        )
        if !fileLevelDecls.isEmpty {
            components.append(contentsOf: fileLevelDecls)
        }

        // 3. Extract each requested type
        for typeName in types.sorted() {
            // Extract the type declaration
            if let typeDecl = try extractTypeDeclaration(
                named: typeName,
                from: parsed,
                source: source
            ) {
                components.append(typeDecl)
            }

            // Extract all extensions for this type
            let extensions = try extractExtensions(
                for: typeName,
                from: parsed,
                source: source
            )
            components.append(contentsOf: extensions)
        }

        // 4. Check for local dependencies within the file
        let localDeps = try findLocalDependencies(
            of: types,
            in: parsed,
            source: source
        )

        // Recursively extract local dependencies
        for dep in localDeps {
            if !types.contains(dep) {
                if let typeDecl = try extractTypeDeclaration(
                    named: dep,
                    from: parsed,
                    source: source
                ) {
                    components.append("// Local dependency: \(dep)")
                    components.append(typeDecl)
                }
            }
        }

        return components.joined(separator: "\n\n")
    }

    // MARK: - Import Extraction

    private func extractImports(from tree: SourceFileSyntax) -> String {
        let visitor = ImportCollector()
        visitor.walk(tree)

        return visitor.imports
            .map { $0.description.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
    }

    // MARK: - File-Level Declaration Extraction

    private func extractFileLevelDeclarations(
        from tree: SourceFileSyntax,
        neededBy types: Set<String>,
        source: String
    ) throws -> [String] {
        var declarations: [String] = []

        // Find typealiases, global functions, etc.
        for item in tree.statements {
            switch item.item {
            case let codeBlockItem as CodeBlockItemSyntax:
                if let decl = codeBlockItem.item.as(TypeAliasDeclSyntax.self) {
                    // Check if any of our types might use this typealias
                    let alias = decl.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    declarations.append(alias)
                }

            default:
                break
            }
        }

        return declarations
    }

    // MARK: - Type Declaration Extraction

    private func extractTypeDeclaration(
        named typeName: String,
        from tree: SourceFileSyntax,
        source: String
    ) throws -> String? {
        let visitor = TypeDeclarationExtractor(targetName: typeName)
        visitor.walk(tree)

        guard let declaration = visitor.foundDeclaration else {
            return nil
        }

        // Extract the exact source text for this declaration
        return declaration.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extension Extraction

    private func extractExtensions(
        for typeName: String,
        from tree: SourceFileSyntax,
        source: String
    ) throws -> [String] {
        let visitor = ExtensionCollector(targetType: typeName)
        visitor.walk(tree)

        return visitor.extensions.map {
            $0.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Local Dependency Analysis

    private func findLocalDependencies(
        of types: Set<String>,
        in tree: SourceFileSyntax,
        source: String
    ) throws -> Set<String> {
        var dependencies = Set<String>()

        // For each type, analyze what other types it uses
        for typeName in types {
            let visitor = TypeDeclarationExtractor(targetName: typeName)
            visitor.walk(tree)

            guard let declaration = visitor.foundDeclaration else {
                continue
            }

            // Analyze this declaration for type references
            let usageVisitor = LocalTypeUsageCollector()
            usageVisitor.walk(Syntax(declaration))

            dependencies.formUnion(usageVisitor.usedTypes)
        }

        // Remove the types we already know about
        dependencies.subtract(types)

        return dependencies
    }
}

// MARK: - Syntax Visitors

final class ImportCollector: SyntaxVisitor {
    var imports: [ImportDeclSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node)
        return .visitChildren
    }
}

final class TypeDefinitionCollector: SyntaxVisitor {
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

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.insert(node.name.text)
        return .visitChildren
    }
}

final class TypeDeclarationExtractor: SyntaxVisitor {
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

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
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
}

final class ExtensionCollector: SyntaxVisitor {
    let targetType: String
    var extensions: [ExtensionDeclSyntax] = []

    init(targetType: String) {
        self.targetType = targetType
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedType = node.extendedType.description
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if extendedType == targetType {
            extensions.append(node)
        }

        return .visitChildren
    }
}

final class LocalTypeUsageCollector: SyntaxVisitor {
    var usedTypes = Set<String>()

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        usedTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Handle nested types like GameRoom.Settings
        if let base = node.baseType.as(IdentifierTypeSyntax.self) {
            usedTypes.insert(base.name.text)
        }
        usedTypes.insert(node.name.text)
        return .visitChildren
    }
}

// MARK: - Additional Edge Cases Not Yet Handled

/*
 This implementation is already ~500 lines and still doesn't handle:

 1. Nested type extraction:
    struct Outer {
        struct Inner { }  // What if we only need Inner?
    }

 2. Cross-file extensions:
    // File1.swift
    struct Player { }

    // File2.swift
    extension Player { }  // Must be found and included!

 3. Conditional compilation:
    #if DEBUG
    struct DebugPlayer { }
    #endif

 4. Attribute handling:
    @available(iOS 17, *)
    struct NewType { }

 5. Generic constraints:
    extension Player where Stats: Codable { }

 6. Protocol conformances split across extensions:
    struct Player { }
    extension Player: Codable { }
    extension Player: Equatable { }
    extension Player: Hashable { }

 7. Macro expansions:
    @Observable
    struct State { }  // Macro generates code we can't see!

 8. Property wrappers:
    struct Config {
        @Published var value: Int  // Needs Combine import
    }

 9. Result builders:
    @resultBuilder
    struct DSLBuilder { }

 10. Global functions and variables:
     func helperForType() { }
     var sharedConstant = 42

 Each of these would add another 50-100 lines of code.
 Total realistic implementation: ~1000+ lines with proper edge case handling.
*/
