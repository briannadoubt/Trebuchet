#if !os(Linux)
import Foundation
import Testing
@testable import TrebuchetCLI

@Suite("Xcode Integration Tests")
struct XcodeIntegrationTests {

    @Test("Parses Xcode target metadata from pbxproj contents")
    func parsesTargetInfo() throws {
        let pbxproj = """
        /* Begin PBXFileReference section */
                ABCDEFABCDEFABCDEFABCDEF /* App.app */ = {isa = PBXFileReference; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXNativeTarget section */
                111111111111111111111111 /* App */ = {
                        isa = PBXNativeTarget;
                        name = App;
                        productReference = ABCDEFABCDEFABCDEFABCDEF /* App.app */;
                        productType = "com.apple.product-type.application";
                };
        /* End PBXNativeTarget section */
        """

        let targets = try XcodeIntegration.parseTargetInfos(
            fromPBXProjContents: pbxproj,
            projectFileName: "App.xcodeproj"
        )

        #expect(targets.count == 1)
        guard let target = targets.first else { return }
        #expect(target.identifier == "111111111111111111111111")
        #expect(target.name == "App")
        #expect(target.buildableName == "App.app")
        #expect(target.referencedContainer == "container:App.xcodeproj")
    }

    @Test("Managed launch actions are inserted idempotently")
    func managedActionsAreIdempotent() throws {
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "2620" version = "1.7">
           <LaunchAction
              buildConfiguration = "Debug">
              <BuildableProductRunnable runnableDebuggingMode = "0">
              </BuildableProductRunnable>
           </LaunchAction>
        </Scheme>
        """

        let once = try XcodeIntegration.addManagedLaunchActions(to: scheme)
        let twice = try XcodeIntegration.addManagedLaunchActions(to: once)

        #expect(once.contains(XcodeIntegration.managedStartActionTitle))
        #expect(once.contains(XcodeIntegration.managedStopActionTitle))

        let startCount = twice.components(separatedBy: XcodeIntegration.managedStartActionTitle).count - 1
        let stopCount = twice.components(separatedBy: XcodeIntegration.managedStopActionTitle).count - 1
        let hostCount = twice.components(separatedBy: "key = \"TREBUCHET_HOST\"").count - 1
        let portCount = twice.components(separatedBy: "key = \"TREBUCHET_PORT\"").count - 1
        #expect(startCount == 1)
        #expect(stopCount == 1)
        #expect(hostCount == 1)
        #expect(portCount == 1)
        #expect(twice.contains("value = \"127.0.0.1\""))
        #expect(twice.contains("value = \"8080\""))
    }

    @Test("Strip managed actions removes injected launch actions")
    func stripManagedActions() {
        let scheme = """
        <Scheme>
          <LaunchAction>
            <PreActions>
              <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
                <ActionContent title = "\(XcodeIntegration.managedStartActionTitle)" scriptText = "echo start">
                </ActionContent>
              </ExecutionAction>
            </PreActions>
            <PostActions>
              <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
                <ActionContent title = "\(XcodeIntegration.managedStopActionTitle)" scriptText = "echo stop">
                </ActionContent>
              </ExecutionAction>
            </PostActions>
          </LaunchAction>
        </Scheme>
        """

        let stripped = XcodeIntegration.stripManagedActions(from: scheme)
        #expect(!stripped.contains(XcodeIntegration.managedStartActionTitle))
        #expect(!stripped.contains(XcodeIntegration.managedStopActionTitle))
    }

    @Test("Fallback scheme contains target buildable reference")
    func fallbackSchemeIncludesTarget() {
        let target = XcodeTargetInfo(
            identifier: "111111111111111111111111",
            name: "App",
            productType: "com.apple.product-type.application",
            buildableName: "App.app",
            referencedContainer: "container:App.xcodeproj"
        )

        let xml = XcodeIntegration.buildFallbackSchemeXML(target: target)
        #expect(xml.contains("BlueprintIdentifier = \"111111111111111111111111\""))
        #expect(xml.contains("BuildableName = \"App.app\""))
        #expect(xml.contains("ReferencedContainer = \"container:App.xcodeproj\""))
    }

    @Test("Start script includes system path and product")
    func startScriptIncludesSystemPathAndProduct() {
        let script = XcodeIntegration.startScriptContents(
            cliExecutablePath: "/usr/local/bin/trebuchet",
            systemPath: "/tmp/Aura/Server",
            product: "AuraSystem",
            host: "127.0.0.1",
            port: 8080,
            runtime: "auto",
            noDeps: true
        )

        #expect(script.contains("--system-path '/tmp/Aura/Server'"))
        #expect(script.contains("--product 'AuraSystem'"))
        #expect(script.contains("--no-deps"))
        #expect(!script.contains("--local"))
    }

    @Test("Session manager dev args include product and omit local")
    func sessionManagerDevArgs() {
        let args = XcodeSessionManager.devCommandArguments(
            systemPath: "/tmp/Aura/Server",
            product: "AuraSystem",
            host: "127.0.0.1",
            port: 8080,
            runtime: "auto",
            noDeps: false
        )

        #expect(args == [
            "dev",
            "/tmp/Aura/Server",
            "--product",
            "AuraSystem",
            "--host",
            "127.0.0.1",
            "--port",
            "8080",
            "--runtime",
            "auto",
            "--verbose",
        ])
    }

    @Test("Setup marks managed scheme visible in scheme management plists")
    func ensureSharedSchemeVisibleWritesPlists() throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let project = try makeProjectReference(in: tempRoot)
        let updatedPaths = try XcodeIntegration.ensureSharedSchemeVisible(
            named: "App+Trebuchet",
            in: project,
            currentUserName: "tester"
        )

        #expect(!updatedPaths.isEmpty)

        let sharedPath = "\(project.xcodeprojPath)/\(XcodeIntegration.sharedSchemeManagementRelativePath)"
        let userPath = "\(project.xcodeprojPath)/xcuserdata/tester.xcuserdatad/xcschemes/xcschememanagement.plist"
        let schemeKey = "App+Trebuchet.xcscheme_^#shared#^_"

        for plistPath in [sharedPath, userPath] {
            let plist = try readPlist(atPath: plistPath)
            let userState = plist["SchemeUserState"] as? [String: Any]
            let entry = userState?[schemeKey] as? [String: Any]
            #expect(entry != nil)
            #expect(entry?["isShown"] as? Bool == true)
        }
    }

    @Test("Teardown removes managed scheme visibility entries")
    func removeSharedSchemeVisibilityRemovesEntries() throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let project = try makeProjectReference(in: tempRoot)
        _ = try XcodeIntegration.ensureSharedSchemeVisible(
            named: "App+Trebuchet",
            in: project,
            currentUserName: "tester"
        )

        let updatedPaths = try XcodeIntegration.removeSharedSchemeVisibility(
            named: "App+Trebuchet",
            in: project,
            currentUserName: "tester"
        )
        #expect(!updatedPaths.isEmpty)

        let sharedPath = "\(project.xcodeprojPath)/\(XcodeIntegration.sharedSchemeManagementRelativePath)"
        let userPath = "\(project.xcodeprojPath)/xcuserdata/tester.xcuserdatad/xcschemes/xcschememanagement.plist"
        let schemeKey = "App+Trebuchet.xcscheme_^#shared#^_"

        for plistPath in [sharedPath, userPath] {
            let plist = try readPlist(atPath: plistPath)
            let userState = plist["SchemeUserState"] as? [String: Any] ?? [:]
            #expect(userState[schemeKey] == nil)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrebuchetCLI-XcodeIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeProjectReference(in tempRoot: URL) throws -> XcodeProjectReference {
        let projectRoot = tempRoot.appendingPathComponent("App")
        let xcodeproj = projectRoot.appendingPathComponent("App.xcodeproj")
        let pbxproj = xcodeproj.appendingPathComponent("project.pbxproj")

        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        try "".write(to: pbxproj, atomically: true, encoding: .utf8)

        return XcodeProjectReference(
            projectRoot: projectRoot.path,
            xcodeprojPath: xcodeproj.path,
            pbxprojPath: pbxproj.path,
            projectFileName: "App.xcodeproj"
        )
    }

    private func readPlist(atPath path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = raw as? [String: Any] else {
            throw NSError(domain: "XcodeIntegrationTests", code: 1)
        }
        return plist
    }
}
#endif
