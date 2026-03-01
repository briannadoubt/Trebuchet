import Foundation
import Trebuchet

protocol DeploymentProvider {
    var id: String { get }

    func deploy(
        plan: DeploymentPlan,
        projectPath: String,
        executableProduct: String,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> ProviderDeploymentResult
}

struct ProviderDeploymentResult: Sendable {
    let provider: String
    let summaryLines: [String]
    let deploymentInfo: Data
}

struct DeploymentProviderRegistry {
    private let providers: [String: any DeploymentProvider]

    init() {
        let aws = AWSDeploymentProvider()
        let fly = FlyDeploymentProvider()
        self.providers = [
            aws.id: aws,
            fly.id: fly,
        ]
    }

    func provider(for id: String) throws -> any DeploymentProvider {
        guard let provider = providers[id.lowercased()] else {
            throw CLIError.configurationError("Unsupported provider: \(id). Supported providers: aws, fly")
        }
        return provider
    }
}
