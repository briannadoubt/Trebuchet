import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct XcodeProjectReference: Sendable {
    public let projectRoot: String
    public let xcodeprojPath: String
    public let pbxprojPath: String
    public let projectFileName: String

    public var sharedSchemesDirectory: String {
        "\(xcodeprojPath)/xcshareddata/xcschemes"
    }
}

public struct XcodeTargetInfo: Sendable {
    public let identifier: String
    public let name: String
    public let productType: String?
    public let buildableName: String
    public let referencedContainer: String
}

public struct XcodeSessionRecord: Codable, Sendable {
    public let pid: Int32
    public let host: String
    public let port: UInt16
    public let logPath: String
    public let startedAt: Date
    public let command: [String]
}

public enum XcodeSessionState: Sendable {
    case running(XcodeSessionRecord)
    case stopped
    case stale(XcodeSessionRecord?)
}

public enum XcodeIntegrationError: Error, CustomStringConvertible {
    case projectNotFound(String)
    case pbxprojNotFound(String)
    case targetNotFound(String)
    case invalidScheme(String)
    case launchActionNotFound
    case portInUse(UInt16, [Int32])
    case sessionStartFailed(String)

    public var description: String {
        switch self {
        case .projectNotFound(let path):
            return "No .xcodeproj found at \(path)"
        case .pbxprojNotFound(let path):
            return "Could not find project.pbxproj at \(path)"
        case .targetNotFound(let name):
            return "Could not resolve target info for scheme/target '\(name)'"
        case .invalidScheme(let message):
            return "Invalid scheme: \(message)"
        case .launchActionNotFound:
            return "Could not find <LaunchAction> in scheme XML"
        case .portInUse(let port, let pids):
            let details = pids.isEmpty ? "" : " (pids: \(pids.map(String.init).joined(separator: ", ")))"
            return "Port \(port) is already in use\(details)"
        case .sessionStartFailed(let message):
            return "Failed to start Trebuchet dev session: \(message)"
        }
    }
}

public enum XcodeIntegration {
    public static let managedStartActionTitle = "Trebuchet Start [managed]"
    public static let managedStopActionTitle = "Trebuchet Stop [managed]"
    public static let xcodeArtifactsDirectoryRelativePath = ".trebuchet-xcode"
    public static let startScriptRelativePath = "\(xcodeArtifactsDirectoryRelativePath)/session-start.sh"
    public static let stopScriptRelativePath = "\(xcodeArtifactsDirectoryRelativePath)/session-stop.sh"
    public static let sharedSchemeManagementRelativePath = "xcshareddata/xcschemes/xcschememanagement.plist"

    public static func findProject(at path: String) throws -> XcodeProjectReference {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootPath = rootURL.path

        guard let entries = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
            throw XcodeIntegrationError.projectNotFound(rootPath)
        }

        guard let projectName = entries
            .filter({ $0.hasSuffix(".xcodeproj") })
            .sorted()
            .first else {
            throw XcodeIntegrationError.projectNotFound(rootPath)
        }

        let xcodeprojPath = "\(rootPath)/\(projectName)"
        let pbxprojPath = "\(xcodeprojPath)/project.pbxproj"
        guard fileManager.fileExists(atPath: pbxprojPath) else {
            throw XcodeIntegrationError.pbxprojNotFound(pbxprojPath)
        }

        return XcodeProjectReference(
            projectRoot: rootPath,
            xcodeprojPath: xcodeprojPath,
            pbxprojPath: pbxprojPath,
            projectFileName: projectName
        )
    }

    public static func listSharedSchemeNames(in project: XcodeProjectReference) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: project.sharedSchemesDirectory) else {
            return []
        }

        return entries
            .filter { $0.hasSuffix(".xcscheme") }
            .map { $0.replacingOccurrences(of: ".xcscheme", with: "") }
            .sorted()
    }

    public static func ensureSharedSchemeVisible(
        named schemeName: String,
        in project: XcodeProjectReference,
        currentUserName: String = ""
    ) throws -> [String] {
        let resolvedUserName = currentUserName.isEmpty ? defaultCurrentUserName() : currentUserName
        let plistPaths = schemeManagementPlistPaths(in: project, currentUserName: resolvedUserName)
        var updatedPaths: [String] = []

        for plistPath in plistPaths {
            if try upsertSharedSchemeVisibilityEntry(at: plistPath, schemeName: schemeName) {
                updatedPaths.append(plistPath)
            }
        }

        return updatedPaths.sorted()
    }

    public static func removeSharedSchemeVisibility(
        named schemeName: String,
        in project: XcodeProjectReference,
        currentUserName: String = ""
    ) throws -> [String] {
        let resolvedUserName = currentUserName.isEmpty ? defaultCurrentUserName() : currentUserName
        let plistPaths = schemeManagementPlistPaths(in: project, currentUserName: resolvedUserName)
        var updatedPaths: [String] = []

        for plistPath in plistPaths {
            if try removeSharedSchemeVisibilityEntry(at: plistPath, schemeName: schemeName) {
                updatedPaths.append(plistPath)
            }
        }

        return updatedPaths.sorted()
    }

    public static func resolveBaseSchemeName(
        preferredScheme: String?,
        in project: XcodeProjectReference
    ) throws -> String {
        if let preferredScheme, !preferredScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferredScheme
        }

        let sharedSchemes = listSharedSchemeNames(in: project)
        let nonManagedSchemes = sharedSchemes.filter { !$0.hasSuffix("+Trebuchet") }
        let projectBaseName = project.projectFileName.replacingOccurrences(of: ".xcodeproj", with: "")

        if nonManagedSchemes.contains(projectBaseName) {
            return projectBaseName
        }

        if let first = nonManagedSchemes.first {
            return first
        }

        let targets = try parseTargetInfos(fromPBXProjAt: project.pbxprojPath, projectFileName: project.projectFileName)
        if let appTarget = targets.first(where: { $0.productType?.contains("application") == true }) {
            return appTarget.name
        }
        if let firstTarget = targets.first {
            return firstTarget.name
        }

        throw XcodeIntegrationError.targetNotFound(projectBaseName)
    }

    public static func preferredTargetInfo(
        in project: XcodeProjectReference,
        preferredName: String?
    ) throws -> XcodeTargetInfo {
        let targets = try parseTargetInfos(fromPBXProjAt: project.pbxprojPath, projectFileName: project.projectFileName)

        if let preferredName,
           let preferred = targets.first(where: { $0.name == preferredName }) {
            return preferred
        }

        if let appTarget = targets.first(where: { $0.productType?.contains("application") == true }) {
            return appTarget
        }

        if let first = targets.first {
            return first
        }

        throw XcodeIntegrationError.targetNotFound(preferredName ?? "<default>")
    }

    public static func parseTargetInfos(
        fromPBXProjAt pbxprojPath: String,
        projectFileName: String
    ) throws -> [XcodeTargetInfo] {
        let contents = try String(contentsOfFile: pbxprojPath, encoding: .utf8)
        return try parseTargetInfos(fromPBXProjContents: contents, projectFileName: projectFileName)
    }

    public static func parseTargetInfos(
        fromPBXProjContents contents: String,
        projectFileName: String
    ) throws -> [XcodeTargetInfo] {
        let fileRefMap = parseFileReferenceBuildableNames(fromPBXProjContents: contents)

        let targetSection = try section(
            named: "PBXNativeTarget",
            in: contents
        )

        let pattern = #"([A-F0-9]{24}) /\* ([^*]+) \*/ = \{([\s\S]*?)\n\s*\};"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsTargetSection = targetSection as NSString
        let matches = regex.matches(
            in: targetSection,
            options: [],
            range: NSRange(location: 0, length: nsTargetSection.length)
        )

        var result: [XcodeTargetInfo] = []
        let referencedContainer = "container:\(projectFileName)"

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let id = nsTargetSection.substring(with: match.range(at: 1))
            let commentName = nsTargetSection.substring(with: match.range(at: 2))
            let block = nsTargetSection.substring(with: match.range(at: 3))

            let name = assignmentValue(forKey: "name", in: block) ?? commentName
            let productType = assignmentValue(forKey: "productType", in: block)

            let productRefPattern = #"productReference = ([A-F0-9]{24}) /\* ([^*]+) \*/;"#
            let productRefRegex = try NSRegularExpression(pattern: productRefPattern, options: [])
            let nsBlock = block as NSString
            let productRefMatch = productRefRegex.firstMatch(
                in: block,
                options: [],
                range: NSRange(location: 0, length: nsBlock.length)
            )

            let buildableName: String
            if let productRefMatch, productRefMatch.numberOfRanges >= 3 {
                let fileRefID = nsBlock.substring(with: productRefMatch.range(at: 1))
                let fallbackName = nsBlock.substring(with: productRefMatch.range(at: 2))
                buildableName = fileRefMap[fileRefID] ?? fallbackName
            } else {
                buildableName = "\(name).app"
            }

            result.append(
                XcodeTargetInfo(
                    identifier: id,
                    name: name,
                    productType: productType,
                    buildableName: buildableName,
                    referencedContainer: referencedContainer
                )
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.productType?.contains("application") == true && rhs.productType?.contains("application") != true {
                return true
            }
            if rhs.productType?.contains("application") == true && lhs.productType?.contains("application") != true {
                return false
            }
            return lhs.name < rhs.name
        }
    }

    public static func buildFallbackSchemeXML(target: XcodeTargetInfo) -> String {
        let buildable = buildableReferenceXML(target: target, indent: "            ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme
           LastUpgradeVersion = "2620"
           version = "1.7">
           <BuildAction
              parallelizeBuildables = "YES"
              buildImplicitDependencies = "YES"
              buildArchitectures = "Automatic">
              <BuildActionEntries>
                 <BuildActionEntry
                    buildForTesting = "YES"
                    buildForRunning = "YES"
                    buildForProfiling = "YES"
                    buildForArchiving = "YES"
                    buildForAnalyzing = "YES">
        \(buildable)
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              shouldUseLaunchSchemeArgsEnv = "YES">
              <Testables>
              </Testables>
           </TestAction>
           <LaunchAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              launchStyle = "0"
              useCustomWorkingDirectory = "NO"
              ignoresPersistentStateOnLaunch = "NO"
              debugDocumentVersioning = "YES"
              debugServiceExtension = "internal"
              allowLocationSimulation = "YES">
              <BuildableProductRunnable
                 runnableDebuggingMode = "0">
        \(buildable)
              </BuildableProductRunnable>
           </LaunchAction>
           <ProfileAction
              buildConfiguration = "Release"
              shouldUseLaunchSchemeArgsEnv = "YES"
              savedToolIdentifier = ""
              useCustomWorkingDirectory = "NO"
              debugDocumentVersioning = "YES">
              <BuildableProductRunnable
                 runnableDebuggingMode = "0">
        \(buildable)
              </BuildableProductRunnable>
           </ProfileAction>
           <AnalyzeAction
              buildConfiguration = "Debug">
           </AnalyzeAction>
           <ArchiveAction
              buildConfiguration = "Release"
              revealArchiveInOrganizer = "YES">
           </ArchiveAction>
        </Scheme>
        """
    }

    public static func stripManagedActions(from schemeXML: String) -> String {
        var result = schemeXML
        let titles = [managedStartActionTitle, managedStopActionTitle]

        for title in titles {
            let escapedTitle = NSRegularExpression.escapedPattern(for: title)
            let pattern = #"(?s)<ExecutionAction\b[\s\S]*?<ActionContent\b[^>]*title = "\#(escapedTitle)"[\s\S]*?</ExecutionAction>\s*"#
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        result = result.replacingOccurrences(of: #"(?s)<PreActions>\s*</PreActions>\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?s)<PostActions>\s*</PostActions>\s*"#, with: "", options: .regularExpression)
        return result
    }

    public static func addManagedLaunchActions(
        to schemeXML: String,
        startScriptRelativePath: String = startScriptRelativePath,
        stopScriptRelativePath: String = stopScriptRelativePath,
        host: String = "127.0.0.1",
        port: UInt16 = 8080
    ) throws -> String {
        let cleaned = stripManagedActions(from: schemeXML)
        let launchPattern = #"(?s)<LaunchAction\b[\s\S]*?</LaunchAction>"#

        guard let launchRange = cleaned.range(of: launchPattern, options: .regularExpression) else {
            throw XcodeIntegrationError.launchActionNotFound
        }

        var launchAction = String(cleaned[launchRange])
        let startAction = managedActionXML(
            title: managedStartActionTitle,
            scriptRelativePath: startScriptRelativePath
        )
        let stopAction = managedActionXML(
            title: managedStopActionTitle,
            scriptRelativePath: stopScriptRelativePath
        )
        let hostVariable = managedEnvironmentVariableXML(
            key: "TREBUCHET_HOST",
            value: host
        )
        let portVariable = managedEnvironmentVariableXML(
            key: "TREBUCHET_PORT",
            value: String(port)
        )

        launchAction = stripManagedEnvironmentVariables(from: launchAction)
        launchAction = inject(actionXML: hostVariable, into: "EnvironmentVariables", launchAction: launchAction)
        launchAction = inject(actionXML: portVariable, into: "EnvironmentVariables", launchAction: launchAction)
        launchAction = inject(actionXML: startAction, into: "PreActions", launchAction: launchAction)
        launchAction = inject(actionXML: stopAction, into: "PostActions", launchAction: launchAction)

        var rewritten = cleaned
        rewritten.replaceSubrange(launchRange, with: launchAction)
        return rewritten
    }

    public static func resolveCLIExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["TREBUCHET_CLI_PATH"], !explicit.isEmpty {
            return explicit
        }

        guard let arg0 = CommandLine.arguments.first, !arg0.isEmpty else {
            return "trebuchet"
        }

        if arg0.hasPrefix("/") {
            return arg0
        }
        if arg0.contains("/") {
            let absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0)
                .standardizedFileURL
            return absolute.path
        }
        return arg0
    }

    public static func startScriptContents(
        cliExecutablePath: String,
        host: String,
        port: UInt16,
        local: String?,
        runtime: String,
        noDeps: Bool
    ) -> String {
        var args = [
            "xcode",
            "session",
            "start",
            "--project-path",
            "\"${PROJECT_DIR:-$PWD}\"",
            "--host",
            shellEscape(host),
            "--port",
            shellEscape(String(port)),
            "--runtime",
            shellEscape(runtime),
        ]
        if noDeps {
            args.append("--no-deps")
        }
        if let local, !local.isEmpty {
            args.append("--local")
            args.append(shellEscape(local))
        }

        let command = args.joined(separator: " ")
        let escapedCLIPath = shellEscape(cliExecutablePath)

        return """
        #!/bin/bash
        set -euo pipefail

        TREBUCHET_BIN=\(escapedCLIPath)

        if [[ ! -x "$TREBUCHET_BIN" ]]; then
          if command -v trebuchet >/dev/null 2>&1; then
            TREBUCHET_BIN="$(command -v trebuchet)"
          else
            echo "error: trebuchet CLI not found. Set TREBUCHET_CLI_PATH or install trebuchet." >&2
            exit 1
          fi
        fi

        "$TREBUCHET_BIN" \(command)
        """
    }

    public static func stopScriptContents(cliExecutablePath: String) -> String {
        let escapedCLIPath = shellEscape(cliExecutablePath)

        return """
        #!/bin/bash
        set -euo pipefail

        TREBUCHET_BIN=\(escapedCLIPath)

        if [[ ! -x "$TREBUCHET_BIN" ]]; then
          if command -v trebuchet >/dev/null 2>&1; then
            TREBUCHET_BIN="$(command -v trebuchet)"
          else
            # No CLI available; nothing we can do on stop
            exit 0
          fi
        fi

        "$TREBUCHET_BIN" xcode session stop --project-path "${PROJECT_DIR:-$PWD}" || true
        """
    }

    private static func section(named name: String, in contents: String) throws -> String {
        let start = "/* Begin \(name) section */"
        let end = "/* End \(name) section */"

        guard let startRange = contents.range(of: start),
              let endRange = contents.range(of: end) else {
            throw XcodeIntegrationError.invalidScheme("Missing \(name) section in project.pbxproj")
        }
        return String(contents[startRange.upperBound..<endRange.lowerBound])
    }

    private static func parseFileReferenceBuildableNames(fromPBXProjContents contents: String) -> [String: String] {
        guard let sectionText = try? section(named: "PBXFileReference", in: contents) else {
            return [:]
        }

        let pattern = #"([A-F0-9]{24}) /\* ([^*]+) \*/ = \{([\s\S]*?)\n\s*\};"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        guard let regex else { return [:] }

        let nsSection = sectionText as NSString
        let matches = regex.matches(in: sectionText, options: [], range: NSRange(location: 0, length: nsSection.length))
        var result: [String: String] = [:]

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let id = nsSection.substring(with: match.range(at: 1))
            let commentName = nsSection.substring(with: match.range(at: 2))
            let block = nsSection.substring(with: match.range(at: 3))
            let path = assignmentValue(forKey: "path", in: block) ?? commentName
            result[id] = path
        }

        return result
    }

    private static func assignmentValue(forKey key: String, in text: String) -> String? {
        let pattern = #"\#(NSRegularExpression.escapedPattern(for: key)) = ([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }

        var value = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func buildableReferenceXML(target: XcodeTargetInfo, indent: String) -> String {
        """
        \(indent)<BuildableReference
        \(indent)   BuildableIdentifier = "primary"
        \(indent)   BlueprintIdentifier = "\(xmlEscapedAttributeValue(target.identifier))"
        \(indent)   BuildableName = "\(xmlEscapedAttributeValue(target.buildableName))"
        \(indent)   BlueprintName = "\(xmlEscapedAttributeValue(target.name))"
        \(indent)   ReferencedContainer = "\(xmlEscapedAttributeValue(target.referencedContainer))">
        \(indent)</BuildableReference>
        """
    }

    private static func managedActionXML(title: String, scriptRelativePath: String) -> String {
        let command = "bash \"$PROJECT_DIR/\(scriptRelativePath)\""
        let escapedScript = xmlEscapedAttributeValue(command)
        let escapedTitle = xmlEscapedAttributeValue(title)

        return """
                 <ExecutionAction
                    ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
                    <ActionContent
                       title = "\(escapedTitle)"
                       scriptText = "\(escapedScript)">
                    </ActionContent>
                 </ExecutionAction>
        """
    }

    private static func managedEnvironmentVariableXML(key: String, value: String) -> String {
        let escapedKey = xmlEscapedAttributeValue(key)
        let escapedValue = xmlEscapedAttributeValue(value)

        return """
             <EnvironmentVariable
                key = "\(escapedKey)"
                value = "\(escapedValue)"
                isEnabled = "YES">
             </EnvironmentVariable>
        """
    }

    private static func stripManagedEnvironmentVariables(from launchAction: String) -> String {
        let managedKeys = ["TREBUCHET_HOST", "TREBUCHET_PORT"]
        var result = launchAction

        for key in managedKeys {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let fullTagPattern = #"(?s)<EnvironmentVariable\b[\s\S]*?key = "\#(escapedKey)"[\s\S]*?</EnvironmentVariable>\s*"#
            let selfClosingPattern = #"<EnvironmentVariable\b[^>]*key = "\#(escapedKey)"[^>]*/>\s*"#
            result = result.replacingOccurrences(of: fullTagPattern, with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: selfClosingPattern, with: "", options: .regularExpression)
        }

        result = result.replacingOccurrences(of: #"(?s)<EnvironmentVariables>\s*</EnvironmentVariables>\s*"#, with: "", options: .regularExpression)
        return result
    }

    private static func inject(actionXML: String, into sectionName: String, launchAction: String) -> String {
        let sectionPattern = #"(?s)<\#(sectionName)>[\s\S]*?</\#(sectionName)>"#
        if let sectionRange = launchAction.range(of: sectionPattern, options: .regularExpression) {
            var sectionText = String(launchAction[sectionRange])
            if let insertPoint = sectionText.range(of: "</\(sectionName)>") {
                sectionText.insert(contentsOf: "\(actionXML)\n", at: insertPoint.lowerBound)
            }
            var rewritten = launchAction
            rewritten.replaceSubrange(sectionRange, with: sectionText)
            return rewritten
        }

        guard let launchStartEnd = launchAction.range(of: ">") else {
            return launchAction
        }

        let sectionXML = """
              <\(sectionName)>
        \(actionXML)
              </\(sectionName)>
        """

        var rewritten = launchAction
        rewritten.insert(contentsOf: "\n\(sectionXML)\n", at: launchStartEnd.upperBound)
        return rewritten
    }

    private static func xmlEscapedAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func schemeManagementPlistPaths(
        in project: XcodeProjectReference,
        currentUserName: String
    ) -> [String] {
        let fileManager = FileManager.default
        var paths = Set<String>()
        paths.insert("\(project.xcodeprojPath)/\(sharedSchemeManagementRelativePath)")

        let usersDirectoryPath = "\(project.xcodeprojPath)/xcuserdata"
        if let userDirectories = try? fileManager.contentsOfDirectory(atPath: usersDirectoryPath) {
            for directory in userDirectories where directory.hasSuffix(".xcuserdatad") {
                paths.insert("\(usersDirectoryPath)/\(directory)/xcschemes/xcschememanagement.plist")
            }
        }

        let trimmedUser = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            paths.insert("\(usersDirectoryPath)/\(trimmedUser).xcuserdatad/xcschemes/xcschememanagement.plist")
        }

        return paths.sorted()
    }

    private static func sharedSchemeUserStateKey(for schemeName: String) -> String {
        "\(schemeName).xcscheme_^#shared#^_"
    }

    private static func upsertSharedSchemeVisibilityEntry(at plistPath: String, schemeName: String) throws -> Bool {
        var root = try loadSchemeManagementPlist(at: plistPath)
        var schemeUserState = root["SchemeUserState"] as? [String: Any] ?? [:]
        let key = sharedSchemeUserStateKey(for: schemeName)
        var entry = schemeUserState[key] as? [String: Any] ?? [:]
        let existingOrderHint = entry["orderHint"]
        var changed = false

        if entry["isShown"] as? Bool != true {
            entry["isShown"] = true
            changed = true
        }

        if existingOrderHint == nil {
            entry["orderHint"] = nextOrderHint(from: schemeUserState)
            changed = true
        }

        if schemeUserState[key] == nil {
            changed = true
        }
        schemeUserState[key] = entry

        guard changed else { return false }

        root["SchemeUserState"] = schemeUserState
        try writeSchemeManagementPlist(root, to: plistPath)
        return true
    }

    private static func removeSharedSchemeVisibilityEntry(at plistPath: String, schemeName: String) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistPath) else {
            return false
        }

        var root = try loadSchemeManagementPlist(at: plistPath)
        var schemeUserState = root["SchemeUserState"] as? [String: Any] ?? [:]
        let key = sharedSchemeUserStateKey(for: schemeName)

        guard schemeUserState.removeValue(forKey: key) != nil else {
            return false
        }

        root["SchemeUserState"] = schemeUserState
        try writeSchemeManagementPlist(root, to: plistPath)
        return true
    }

    private static func loadSchemeManagementPlist(at plistPath: String) throws -> [String: Any] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistPath) else {
            return [:]
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        let rawValue = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = rawValue as? [String: Any] else {
            throw XcodeIntegrationError.invalidScheme("Unexpected plist format at \(plistPath)")
        }
        return dictionary
    }

    private static func writeSchemeManagementPlist(_ plist: [String: Any], to plistPath: String) throws {
        let fileManager = FileManager.default
        let directoryPath = URL(fileURLWithPath: plistPath).deletingLastPathComponent().path
        try fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    private static func nextOrderHint(from schemeUserState: [String: Any]) -> Int {
        var maxOrderHint = 0
        for value in schemeUserState.values {
            guard let entry = value as? [String: Any] else { continue }
            if let orderHint = entry["orderHint"] as? Int {
                maxOrderHint = max(maxOrderHint, orderHint)
            } else if let number = entry["orderHint"] as? NSNumber {
                maxOrderHint = max(maxOrderHint, number.intValue)
            }
        }
        return maxOrderHint + 1
    }

    private static func defaultCurrentUserName() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let user = environment["USER"], !user.isEmpty {
            return user
        }
        if let user = environment["LOGNAME"], !user.isEmpty {
            return user
        }
        return ""
    }
}

public struct XcodeSessionManager {
    public let projectPath: String
    public let cliExecutablePath: String
    public let terminal: Terminal
    public let verbose: Bool

    public init(
        projectPath: String,
        cliExecutablePath: String,
        terminal: Terminal,
        verbose: Bool
    ) {
        self.projectPath = projectPath
        self.cliExecutablePath = cliExecutablePath
        self.terminal = terminal
        self.verbose = verbose
    }

    public var xcodeDirectory: String { "\(projectPath)/\(XcodeIntegration.xcodeArtifactsDirectoryRelativePath)" }
    public var sessionDirectory: String { "\(xcodeDirectory)/session" }
    public var sessionFilePath: String { "\(sessionDirectory)/server.json" }
    public var pidFilePath: String { "\(sessionDirectory)/server.pid" }
    public var logFilePath: String { "\(sessionDirectory)/server.log" }

    public func status() -> XcodeSessionState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFilePath),
              let data = fileManager.contents(atPath: sessionFilePath) else {
            return .stopped
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(XcodeSessionRecord.self, from: data) else {
            return .stopped
        }

        let alive = Self.isProcessRunning(record.pid)
        let listeningPIDs = Self.listeningPIDs(on: record.port)
        let listening = listeningPIDs.contains(record.pid) || listeningPIDs.isEmpty == false

        if alive && listening {
            return .running(record)
        }
        return .stale(record)
    }

    public func start(
        host: String,
        port: UInt16,
        local: String?,
        runtime: String,
        noDeps: Bool
    ) throws {
        switch status() {
        case .running(let record):
            if record.host == host && record.port == port {
                terminal.print("Trebuchet session already running on \(record.host):\(record.port) (pid \(record.pid))", style: .dim)
                return
            }
            terminal.print("Stopping stale session with mismatched endpoint...", style: .dim)
            stop()
        case .stale:
            clearSessionFiles()
        case .stopped:
            break
        }

        let activePIDs = Self.listeningPIDs(on: port)
        if !activePIDs.isEmpty {
            throw XcodeIntegrationError.portInUse(port, activePIDs)
        }

        try FileManager.default.createDirectory(
            atPath: sessionDirectory,
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: logFilePath) {
            try Data().write(to: URL(fileURLWithPath: logFilePath))
        } else {
            FileManager.default.createFile(atPath: logFilePath, contents: Data())
        }
        guard let logHandle = FileHandle(forWritingAtPath: logFilePath) else {
            throw XcodeIntegrationError.sessionStartFailed("Could not open log file at \(logFilePath)")
        }
        defer { try? logHandle.close() }
        try logHandle.seekToEnd()

        var commandArgs = [
            "dev",
            projectPath,
            "--host",
            host,
            "--port",
            "\(port)",
            "--runtime",
            runtime,
            "--verbose",
        ]
        if noDeps {
            commandArgs.append("--no-deps")
        }
        if let local, !local.isEmpty {
            commandArgs.append(contentsOf: ["--local", local])
        }

        let process = Process()
        if cliExecutablePath.contains("/") {
            process.executableURL = URL(fileURLWithPath: cliExecutablePath)
            process.arguments = commandArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [cliExecutablePath] + commandArgs
        }
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = logHandle
        process.standardError = logHandle

        var environment = ProcessInfo.processInfo.environment
        environment["TREBUCHET_XCODE_SESSION"] = "1"
        process.environment = environment

        try process.run()

        let pid = process.processIdentifier
        // First-time `swift build` for generated dev runners can take multiple minutes.
        // Keep this generous so Xcode pre-run actions remain reliable.
        let readinessDeadline = Date().addingTimeInterval(600)
        var ready = false

        while Date() < readinessDeadline {
            if Self.listeningPIDs(on: port).contains(pid) {
                ready = true
                break
            }
            if Self.logIndicatesReady(at: logFilePath) {
                ready = true
                break
            }
            if process.isRunning == false {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if !ready {
            if process.isRunning {
                process.terminate()
            }
            throw XcodeIntegrationError.sessionStartFailed(
                "Process did not become ready on port \(port). Check logs: \(logFilePath)"
            )
        }

        let listenerPIDs = Self.listeningPIDs(on: port)
        let trackedPID = listenerPIDs.first ?? pid

        let record = XcodeSessionRecord(
            pid: trackedPID,
            host: host,
            port: port,
            logPath: logFilePath,
            startedAt: Date(),
            command: commandArgs
        )
        try write(record: record)

        terminal.print("Started Trebuchet session on \(host):\(port) (pid \(pid))", style: .success)
        terminal.print("Logs: \(logFilePath)", style: .dim)
    }

    public func stop() {
        let maybeRecord: XcodeSessionRecord?
        switch status() {
        case .running(let record):
            maybeRecord = record
        case .stale(let record):
            maybeRecord = record
        case .stopped:
            maybeRecord = nil
        }

        if let record = maybeRecord {
            if verbose {
                terminal.print("Stopping Trebuchet session pid \(record.pid)...", style: .dim)
            }

            // Stop any process currently listening on the tracked port.
            let listenerPIDs = Self.listeningPIDs(on: record.port)
            for listenerPID in listenerPIDs where listenerPID > 0 {
                _ = kill(listenerPID, SIGTERM)
            }

            if Self.isProcessRunning(record.pid) {
                _ = kill(record.pid, SIGTERM)
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline && Self.isProcessRunning(record.pid) {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                if Self.isProcessRunning(record.pid) {
                    _ = kill(record.pid, SIGKILL)
                }
            }

            // Ensure listeners are gone; escalate only if needed.
            let lingeringListeners = Self.listeningPIDs(on: record.port)
            for listenerPID in lingeringListeners where Self.isProcessRunning(listenerPID) {
                _ = kill(listenerPID, SIGKILL)
            }
        }

        clearSessionFiles()
        if verbose {
            terminal.print("Trebuchet session stopped.", style: .dim)
        }
    }

    private func write(record: XcodeSessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(record)
        try jsonData.write(to: URL(fileURLWithPath: sessionFilePath))
        try "\(record.pid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    private func clearSessionFiles() {
        let fileManager = FileManager.default
        for path in [sessionFilePath, pidFilePath] {
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    private static func listeningPIDs(on port: UInt16) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lsof", "-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func isProcessRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }

        #if canImport(Darwin)
        return errno == EPERM
        #elseif canImport(Glibc)
        return errno == EPERM
        #else
        return false
        #endif
    }

    private static func logIndicatesReady(at logPath: String) -> Bool {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return false
        }
        return contents.contains("Server running on ws://")
    }
}
