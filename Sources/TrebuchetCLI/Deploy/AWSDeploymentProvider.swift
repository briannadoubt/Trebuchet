import Foundation
import Trebuchet

struct AWSDeploymentProvider: DeploymentProvider {
    let id = "aws"

    func deploy(
        plan: DeploymentPlan,
        projectPath: String,
        executableProduct: String,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> ProviderDeploymentResult {
        let region = resolvedRegion(plan: plan)
        let resolvedConfig = resolveConfig(plan: plan, region: region)

        terminal.print("Building for Lambda (arm64)...", style: .header)
        let builder = DockerBuilder()
        let buildResult = try await builder.build(
            projectPath: projectPath,
            config: resolvedConfig,
            executableProduct: executableProduct,
            verbose: verbose,
            terminal: terminal
        )

        terminal.print("  ✓ Package built (\(buildResult.sizeDescription))", style: .success)
        terminal.print("", style: .info)

        terminal.print("Generating infrastructure...", style: .header)
        let terraformDir = try TerraformGenerator().generate(
            config: resolvedConfig,
            actors: plan.actors.map { actor in
                ActorMetadata(name: actor.actorType, filePath: "", lineNumber: 0, methods: [])
            },
            outputDir: "\(projectPath)/.trebuchet/terraform"
        )

        terminal.print("  ✓ Terraform generated at \(terraformDir)", style: .success)
        terminal.print("", style: .info)

        terminal.print("Deploying to AWS...", style: .header)
        let deployment = try await TerraformDeployer().deploy(
            terraformDir: terraformDir,
            region: region,
            verbose: verbose,
            terminal: terminal
        )

        let deploymentInfo = DeploymentInfo(
            projectName: plan.systemName,
            provider: "aws",
            region: region,
            lambdaArn: deployment.lambdaArn,
            apiGatewayUrl: deployment.apiGatewayUrl,
            dynamoDBTable: deployment.dynamoDBTable,
            cloudMapNamespace: deployment.cloudMapNamespace,
            deployedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let infoData = try encoder.encode(deploymentInfo)

        let summary = [
            "Lambda: \(deployment.lambdaArn)",
            "DynamoDB: \(deployment.dynamoDBTable)",
            "CloudMap: \(deployment.cloudMapNamespace)",
        ] + (deployment.apiGatewayUrl.map { ["API Gateway: \($0)"] } ?? [])

        return ProviderDeploymentResult(
            provider: id,
            summaryLines: summary,
            deploymentInfo: infoData
        )
    }

    private func resolvedRegion(plan: DeploymentPlan) -> String {
        if let configured = plan.actors.compactMap({ $0.aws?.region }).first {
            return configured
        }
        return "us-east-1"
    }

    private func resolveConfig(plan: DeploymentPlan, region: String) -> ResolvedConfig {
        let actorConfigs: [ResolvedActorConfig] = plan.actors.map { actor in
            let aws = actor.aws
            return ResolvedActorConfig(
                name: actor.actorType,
                memory: aws?.memory ?? 512,
                timeout: aws?.timeout ?? 30,
                stateful: actor.state != nil,
                isolated: false,
                environment: [:]
            )
        }

        let stateTableName: String = {
            for actor in plan.actors {
                if case let .dynamoDB(table) = actor.state {
                    return table
                }
            }
            return "\(plan.systemName)-state"
        }()

        return ResolvedConfig(
            projectName: plan.systemName,
            provider: "aws",
            region: region,
            actors: actorConfigs,
            stateTableName: stateTableName,
            discoveryNamespace: "\(plan.systemName)-actors",
            stateType: "dynamodb"
        )
    }
}
