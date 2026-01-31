import Foundation

/// Simple file-level copier (current implementation, simplified for comparison)
struct FileLevelCopier {
    func copy(files: Set<String>, to targetPath: String) throws {
        for sourceFile in files {
            let fileName = URL(fileURLWithPath: sourceFile).lastPathComponent
            let targetFile = "\(targetPath)/\(fileName)"

            // Just copy the file
            let content = try String(contentsOfFile: sourceFile, encoding: .utf8)
            try content.write(toFile: targetFile, atomically: true, encoding: .utf8)
        }
    }
}

// That's it! Dead simple.
