import Distributed
import Foundation
import Trebuche
import TrebucheCloud

// MARK: - AWS Provider

/// Cloud provider implementation for AWS Lambda deployment
public struct AWSProvider: CloudProvider, Sendable {
    public typealias FunctionConfig = AWSFunctionConfig
    public typealias DeploymentResult = AWSDeployment

    public static var providerType: CloudProviderType { .aws }

    private let region: String
    private let credentials: AWSCredentials

    public init(region: String, credentials: AWSCredentials = .default) {
        self.region = region
        self.credentials = credentials
    }

    public func deploy<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        config: AWSFunctionConfig,
        factory: @Sendable (TrebuchetActorSystem) -> A
    ) async throws -> AWSDeployment where A.ActorSystem == TrebuchetActorSystem {
        // In a real implementation, this would use the AWS SDK to:
        // 1. Create/update the Lambda function
        // 2. Configure IAM roles
        // 3. Set up triggers

        // For now, return a placeholder deployment
        return AWSDeployment(
            provider: .aws,
            actorID: actorID,
            region: region,
            identifier: "arn:aws:lambda:\(region):123456789012:function:\(actorID)",
            createdAt: Date(),
            functionName: actorID,
            memoryMB: config.memoryMB,
            timeout: config.timeout
        )
    }

    public func transport(for deployment: AWSDeployment) async throws -> any TrebuchetTransport {
        LambdaInvokeTransport(
            functionArn: deployment.identifier,
            region: region,
            credentials: credentials
        )
    }

    public func listDeployments() async throws -> [AWSDeployment] {
        // Would use AWS SDK to list Lambda functions with trebuche tags
        []
    }

    public func undeploy(_ deployment: AWSDeployment) async throws {
        // Would use AWS SDK to delete the Lambda function
    }

    public func status(of deployment: AWSDeployment) async throws -> DeploymentStatus {
        // Would use AWS SDK to check function status
        .active
    }
}

// MARK: - AWS Function Configuration

/// Configuration for deploying an actor to AWS Lambda
public struct AWSFunctionConfig: Sendable {
    /// Memory allocation in MB (128-10240)
    public var memoryMB: Int

    /// Timeout duration (1-900 seconds)
    public var timeout: Duration

    /// VPC configuration
    public var vpcConfig: VPCConfig?

    /// Environment variables
    public var environment: [String: String]

    /// IAM role ARN (optional, will be created if not provided)
    public var roleArn: String?

    /// Tags for the function
    public var tags: [String: String]

    /// Reserved concurrent executions
    public var reservedConcurrency: Int?

    /// Provisioned concurrency
    public var provisionedConcurrency: Int?

    public init(
        memoryMB: Int = 512,
        timeout: Duration = .seconds(30),
        vpcConfig: VPCConfig? = nil,
        environment: [String: String] = [:],
        roleArn: String? = nil,
        tags: [String: String] = [:],
        reservedConcurrency: Int? = nil,
        provisionedConcurrency: Int? = nil
    ) {
        self.memoryMB = memoryMB
        self.timeout = timeout
        self.vpcConfig = vpcConfig
        self.environment = environment
        self.roleArn = roleArn
        self.tags = tags
        self.reservedConcurrency = reservedConcurrency
        self.provisionedConcurrency = provisionedConcurrency
    }

    public static let `default` = AWSFunctionConfig()
    public static let highMemory = AWSFunctionConfig(memoryMB: 2048)
    public static let longRunning = AWSFunctionConfig(timeout: .seconds(300))
}

/// VPC configuration for Lambda
public struct VPCConfig: Sendable, Codable {
    public let subnetIds: [String]
    public let securityGroupIds: [String]

    public init(subnetIds: [String], securityGroupIds: [String]) {
        self.subnetIds = subnetIds
        self.securityGroupIds = securityGroupIds
    }
}

// MARK: - AWS Deployment

/// Result of deploying an actor to AWS Lambda
public struct AWSDeployment: CloudDeployment {
    public let provider: CloudProviderType
    public let actorID: String
    public let region: String
    public let identifier: String  // Lambda ARN
    public let createdAt: Date

    /// The Lambda function name
    public let functionName: String

    /// Memory allocation
    public let memoryMB: Int

    /// Timeout duration
    public let timeout: Duration

    public init(
        provider: CloudProviderType,
        actorID: String,
        region: String,
        identifier: String,
        createdAt: Date,
        functionName: String,
        memoryMB: Int,
        timeout: Duration
    ) {
        self.provider = provider
        self.actorID = actorID
        self.region = region
        self.identifier = identifier
        self.createdAt = createdAt
        self.functionName = functionName
        self.memoryMB = memoryMB
        self.timeout = timeout
    }
}

// MARK: - AWS Credentials

/// AWS credentials for API access
public struct AWSCredentials: Sendable {
    public let accessKeyId: String?
    public let secretAccessKey: String?
    public let sessionToken: String?

    public init(
        accessKeyId: String? = nil,
        secretAccessKey: String? = nil,
        sessionToken: String? = nil
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    /// Use default credential chain (environment, profile, instance metadata)
    public static let `default` = AWSCredentials()

    /// Create from environment variables
    public static func fromEnvironment() -> AWSCredentials {
        AWSCredentials(
            accessKeyId: ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
            secretAccessKey: ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"],
            sessionToken: ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"]
        )
    }
}
