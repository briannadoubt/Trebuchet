import Foundation

/// Ensures the CLI binary has virtualization entitlements before command execution.
/// On macOS, if entitlements are missing, it ad-hoc signs the current executable and relaunches.
public enum CLIAutoSigner {
    public static func relaunchIfNeeded(arguments: [String] = CommandLine.arguments) -> Int32? {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["TREBUCHET_AUTO_SIGNING_DISABLED"] != "1" else {
            return nil
        }
        guard ProcessInfo.processInfo.environment["TREBUCHET_AUTO_SIGNING_RELAUNCHED"] == nil else {
            return nil
        }
        guard let executablePath = Bundle.main.executablePath else {
            return nil
        }
        guard !hasRequiredEntitlements(executablePath: executablePath) else {
            return nil
        }

        do {
            try signBinary(executablePath: executablePath)
        } catch {
            writeToStderr("warning: failed to auto-sign trebuchet binary: \(error)\n")
            return nil
        }

        guard hasRequiredEntitlements(executablePath: executablePath) else {
            writeToStderr("warning: trebuchet binary is still missing virtualization entitlements after auto-sign attempt.\n")
            return nil
        }

        writeToStderr("Auto-signed trebuchet binary with virtualization entitlements. Relaunching command...\n")
        return relaunch(executablePath: executablePath, arguments: arguments)
        #else
        _ = arguments
        return nil
        #endif
    }

    #if os(macOS)
    private static let requiredEntitlements = [
        "com.apple.security.virtualization",
        "com.apple.security.hypervisor",
    ]

    private static let embeddedEntitlementsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>com.apple.security.virtualization</key>
          <true/>
          <key>com.apple.security.hypervisor</key>
          <true/>
        </dict>
        </plist>
        """

    private static func hasRequiredEntitlements(executablePath: String) -> Bool {
        guard let result = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", executablePath],
            captureCombinedOutput: true
        ), result.exitCode == 0 else {
            return false
        }

        return requiredEntitlements.allSatisfy { result.output.contains($0) }
    }

    private static func signBinary(executablePath: String) throws {
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: executablePath) else {
            struct SigningError: LocalizedError {
                let description: String
                var errorDescription: String? { description }
            }
            throw SigningError(description: "binary is not writable: \(executablePath)")
        }

        let entitlementsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trebuchet-entitlements-\(UUID().uuidString).plist")
        try embeddedEntitlementsPlist.write(to: entitlementsURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: entitlementsURL) }

        let identity = ProcessInfo.processInfo.environment["TREBUCHET_CODESIGN_IDENTITY"] ?? "-"
        guard let signResult = runProcess(
            executable: "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign", identity,
                "--entitlements", entitlementsURL.path,
                "--timestamp=none",
                executablePath,
            ],
            captureCombinedOutput: true
        ) else {
            struct SigningError: LocalizedError {
                var errorDescription: String? { "failed to launch codesign" }
            }
            throw SigningError()
        }

        guard signResult.exitCode == 0 else {
            struct SigningError: LocalizedError {
                let description: String
                var errorDescription: String? { description }
            }
            throw SigningError(description: signResult.output.isEmpty ? "codesign failed with exit code \(signResult.exitCode)" : signResult.output)
        }
    }

    private static func relaunch(executablePath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["TREBUCHET_AUTO_SIGNING_RELAUNCHED"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            writeToStderr("warning: auto-sign relaunch failed: \(error)\n")
            return 1
        }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        captureCombinedOutput: Bool
    ) -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        if captureCombinedOutput {
            process.standardOutput = pipe
            process.standardError = pipe
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output: String
        if captureCombinedOutput {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(decoding: data, as: UTF8.self)
        } else {
            output = ""
        }

        return (process.terminationStatus, output)
    }

    private static func writeToStderr(_ message: String) {
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
    #endif
}
