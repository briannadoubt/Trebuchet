import Foundation

struct SystemProductResolver {
    struct ResolutionResult: Sendable {
        let product: String
        let executableTargets: [String]
    }

    func resolve(projectPath: String, explicitProduct: String?) throws -> ResolutionResult {
        let manifest = try loadPackageDescription(projectPath: projectPath)
        let products = manifest.executableProducts

        guard !products.isEmpty else {
            throw CLIError.configurationError(
                "No executable products found. Add an executable target with `@main struct ...: System` in your Package.swift."
            )
        }

        if let explicitProduct {
            guard let product = products.first(where: { $0.name == explicitProduct }) else {
                let names = products.map(\.name).sorted().joined(separator: ", ")
                throw CLIError.configurationError("Unknown executable product '\(explicitProduct)'. Available: \(names)")
            }
            return ResolutionResult(product: product.name, executableTargets: product.targets)
        }

        if products.count == 1, let only = products.first {
            return ResolutionResult(product: only.name, executableTargets: only.targets)
        }

        let matchingProducts = products.filter { product in
            product.targets.contains { targetName in
                manifest.targetContainsSystemMain(targetName: targetName)
            }
        }

        if matchingProducts.count == 1, let match = matchingProducts.first {
            return ResolutionResult(product: match.name, executableTargets: match.targets)
        }

        let choices = products.map(\.name).sorted().joined(separator: ", ")
        throw CLIError.configurationError(
            "Multiple executable products were found and no unique `@main ...: System` entrypoint could be resolved. " +
            "Pass --product <name>. Available products: \(choices)"
        )
    }

    // MARK: - Package describe parsing

    private func loadPackageDescription(projectPath: String) throws -> PackageDescription {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "describe", "--type", "json"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.configurationError(
                "Failed to run `swift package describe --type json`. \(errorText)"
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: outputData, options: [])
        guard let dictionary = json as? [String: Any] else {
            throw CLIError.configurationError("Could not parse package description JSON.")
        }

        return try PackageDescription(json: dictionary, rootPath: projectPath)
    }
}

private struct PackageDescription {
    struct Product {
        let name: String
        let targets: [String]
    }

    struct Target {
        let name: String
        let path: String
        let sources: [String]
    }

    let executableProducts: [Product]
    let targetsByName: [String: Target]

    init(json: [String: Any], rootPath: String) throws {
        let productsRaw = json["products"] as? [[String: Any]] ?? []
        let executableProducts = productsRaw.compactMap { raw -> Product? in
            guard let name = raw["name"] as? String,
                  let targetNames = raw["targets"] as? [String],
                  let type = raw["type"] as? [String: Any],
                  type["executable"] != nil else {
                return nil
            }
            return Product(name: name, targets: targetNames)
        }

        let targetsRaw = json["targets"] as? [[String: Any]] ?? []
        var targetsByName: [String: Target] = [:]
        for raw in targetsRaw {
            guard let name = raw["name"] as? String else { continue }
            let relativePath = raw["path"] as? String ?? "Sources/\(name)"
            let fullPath = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath).path
            let sources = raw["sources"] as? [String] ?? []
            targetsByName[name] = Target(name: name, path: fullPath, sources: sources)
        }

        self.executableProducts = executableProducts
        self.targetsByName = targetsByName
    }

    func targetContainsSystemMain(targetName: String) -> Bool {
        guard let target = targetsByName[targetName] else { return false }

        for source in target.sources where source.hasSuffix(".swift") {
            let path = URL(fileURLWithPath: target.path).appendingPathComponent(source).path
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if containsSystemMain(contents: contents) {
                return true
            }
        }

        return false
    }

    private func containsSystemMain(contents: String) -> Bool {
        guard contents.contains("@main") else { return false }

        let pattern = #"\b(struct|class|actor)\s+\w+\s*:\s*[^\{\n]*\bSystem\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }

        let ns = contents as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.firstMatch(in: contents, options: [], range: range) != nil
    }
}
