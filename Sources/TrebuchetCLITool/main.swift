import Foundation
import TrebuchetCLI

@main
struct Main {
    static func main() async {
        if let relaunchExitCode = CLIAutoSigner.relaunchIfNeeded() {
            Foundation.exit(relaunchExitCode)
        }
        await TrebuchetCommand.main()
    }
}
