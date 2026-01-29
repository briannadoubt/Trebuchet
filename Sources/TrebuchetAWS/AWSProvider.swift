import Distributed
import Foundation
import Trebuchet
import TrebuchetCloud
import SotoLambda
import SotoIAM
import SotoCore
import NIOCore

// MARK: - AWS Provider

/// Cloud provider implementation for AWS Lambda deployment
public struct AWSProvider: CloudProvider, Sendable {
    public typealias FunctionConfig = AWSFunctionConfig
    public typealias DeploymentResult = AWSDeployment

    public static var providerType: CloudProviderType { .aws }

    private let region: String
    private let credentials: AWSCredentials
    private let lambdaClient: Lambda
    private let iamClient: IAM?
    private let awsClient: AWSClient
    private let createRoles: Bool

    /// Initialize AWS provider
    ///
    /// - Parameters:
    ///   - region: AWS region (e.g., "us-east-1")
    ///   - credentials: AWS credentials (default uses credential chain)
    ///   - createRoles: Whether to create IAM roles automatically (default: false)
    ///   - awsClient: Optional custom AWSClient for advanced configuration
    public init(
        region: String,
        credentials: AWSCredentials = .default,
        createRoles: Bool = false,
        awsClient: AWSClient? = nil
    ) {
        self.region = region
        self.credentials = credentials
        self.createRoles = createRoles

        // Create or use provided AWSClient
        let client: AWSClient
        if let provided = awsClient {
            client = provided
        } else if let accessKey = credentials.accessKeyId,
                  let secretKey = credentials.secretAccessKey {
            // Use static credentials if provided
            client = AWSClient(
                credentialProvider: .static(
                    accessKeyId: accessKey,
                    secretAccessKey: secretKey,
                    sessionToken: credentials.sessionToken
                )
            )
        } else {
            // Otherwise use default credential chain
            client = AWSClient(credentialProvider: .default)
        }

        self.awsClient = client
        self.lambdaClient = Lambda(
            client: client,
            region: Region(awsRegionName: region) ?? .useast1
        )
        self.iamClient = createRoles ? IAM(client: client) : nil
    }

    public func deploy<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        config: AWSFunctionConfig,
        factory: @Sendable (TrebuchetActorSystem) -> A
    ) async throws -> AWSDeployment where A.ActorSystem == TrebuchetActorSystem {
        let functionName = sanitizeFunctionName(actorID)

        // Get or create IAM role
        let roleArn: String
        if let providedRole = config.roleArn {
            roleArn = providedRole
        } else if createRoles, let iamClient = iamClient {
            roleArn = try await ensureRole(functionName: functionName, iamClient: iamClient)
        } else {
            throw AWSProviderError.missingRole("No IAM role provided and createRoles=false")
        }

        // Check if function exists
        let exists = try await functionExists(functionName: functionName)

        if exists {
            // Update existing function
            try await updateFunction(
                functionName: functionName,
                config: config,
                roleArn: roleArn
            )
        } else {
            // Create new function
            try await createFunction(
                functionName: functionName,
                actorID: actorID,
                config: config,
                roleArn: roleArn
            )
        }

        // Wait for function to be ready
        try await waitForFunctionReady(functionName: functionName)

        // Configure concurrency if specified
        if let reserved = config.reservedConcurrency {
            try await configureConcurrency(functionName: functionName, reserved: reserved)
        }

        // Get function ARN
        let functionArn = try await getFunctionArn(functionName: functionName)

        return AWSDeployment(
            provider: .aws,
            actorID: actorID,
            region: region,
            identifier: functionArn,
            createdAt: Date(),
            functionName: functionName,
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
        var deployments: [AWSDeployment] = []
        var marker: String?

        repeat {
            let request = Lambda.ListFunctionsRequest(marker: marker, maxItems: 50)
            let response = try await lambdaClient.listFunctions(request)

            // Filter functions with Trebuchet tag
            for function in response.functions ?? [] {
                guard let functionName = function.functionName,
                      let functionArn = function.functionArn else {
                    continue
                }

                // Get tags to verify this is a Trebuchet function
                let tagsRequest = Lambda.ListTagsRequest(resource: functionArn)
                let tagsResponse = try await lambdaClient.listTags(tagsRequest)

                if let tags = tagsResponse.tags,
                   tags["ManagedBy"] == "trebuchet" {
                    let deployment = AWSDeployment(
                        provider: .aws,
                        actorID: tags["ActorID"] ?? functionName,
                        region: region,
                        identifier: functionArn,
                        createdAt: Date(), // Could parse from LastModified if needed
                        functionName: functionName,
                        memoryMB: function.memorySize ?? 512,
                        timeout: .seconds(Int64(function.timeout ?? 30))
                    )
                    deployments.append(deployment)
                }
            }

            marker = response.nextMarker
        } while marker != nil

        return deployments
    }

    public func undeploy(_ deployment: AWSDeployment) async throws {
        let request = Lambda.DeleteFunctionRequest(functionName: deployment.functionName)
        _ = try await lambdaClient.deleteFunction(request)
    }

    public func status(of deployment: AWSDeployment) async throws -> DeploymentStatus {
        do {
            let request = Lambda.GetFunctionRequest(functionName: deployment.functionName)
            let response = try await lambdaClient.getFunction(request)

            guard let configuration = response.configuration else {
                return .failed(reason: "No configuration found")
            }

            // Map Lambda state to DeploymentStatus
            switch (configuration.state, configuration.lastUpdateStatus) {
            case (.active, .successful):
                return .active
            case (.pending, _), (_, .inProgress):
                return .deploying
            case (.failed, _):
                let reason = configuration.stateReason ?? "Unknown Lambda state error"
                return .failed(reason: reason)
            case (_, .failed):
                let reason = configuration.lastUpdateStatusReason ?? "Unknown update error"
                return .failed(reason: reason)
            case (.inactive, _):
                return .failed(reason: "Function is inactive")
            default:
                return .active
            }
        } catch {
            // If function doesn't exist, it's in failed state
            return .failed(reason: "Function not found: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helper Methods

    private func sanitizeFunctionName(_ actorID: String) -> String {
        // Lambda function names must match: [a-zA-Z0-9-_]+
        actorID
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private func functionExists(functionName: String) async throws -> Bool {
        do {
            let request = Lambda.GetFunctionRequest(functionName: functionName)
            _ = try await lambdaClient.getFunction(request)
            return true
        } catch {
            // Function doesn't exist
            return false
        }
    }

    private func createFunction(
        functionName: String,
        actorID: String,
        config: AWSFunctionConfig,
        roleArn: String
    ) async throws {
        // Note: In a real deployment, the code would be provided via deployment package
        // For now, we create a placeholder - the CLI would handle actual code upload
        var tags = config.tags
        tags["ManagedBy"] = "trebuchet"
        tags["ActorID"] = actorID

        let vpcConfig: Lambda.VpcConfig?
        if let vpc = config.vpcConfig {
            vpcConfig = Lambda.VpcConfig(
                securityGroupIds: vpc.securityGroupIds,
                subnetIds: vpc.subnetIds
            )
        } else {
            vpcConfig = nil
        }

        let environment = Lambda.Environment(variables: config.environment)

        // Note: In production, the deployment package would need to be provided
        // Either via S3 bucket or as a base64-encoded zip file
        // For now, we'll create an empty FunctionCode - this would need to be updated
        // with actual deployment package location before real use
        let request = Lambda.CreateFunctionRequest(
            code: Lambda.FunctionCode(),
            environment: environment,
            functionName: functionName,
            handler: "bootstrap", // Custom runtime
            memorySize: config.memoryMB,
            packageType: .zip,
            role: roleArn,
            runtime: .providedal2,
            tags: tags,
            timeout: Int(config.timeout.components.seconds),
            vpcConfig: vpcConfig
        )

        _ = try await lambdaClient.createFunction(request)
    }

    private func updateFunction(
        functionName: String,
        config: AWSFunctionConfig,
        roleArn: String
    ) async throws {
        // Update function configuration
        let environment = Lambda.Environment(variables: config.environment)

        let vpcConfig: Lambda.VpcConfig?
        if let vpc = config.vpcConfig {
            vpcConfig = Lambda.VpcConfig(
                securityGroupIds: vpc.securityGroupIds,
                subnetIds: vpc.subnetIds
            )
        } else {
            vpcConfig = nil
        }

        let request = Lambda.UpdateFunctionConfigurationRequest(
            environment: environment,
            functionName: functionName,
            memorySize: config.memoryMB,
            role: roleArn,
            timeout: Int(config.timeout.components.seconds),
            vpcConfig: vpcConfig
        )

        _ = try await lambdaClient.updateFunctionConfiguration(request)
    }

    private func waitForFunctionReady(functionName: String, maxAttempts: Int = 30) async throws {
        for attempt in 0..<maxAttempts {
            let request = Lambda.GetFunctionRequest(functionName: functionName)
            let response = try await lambdaClient.getFunction(request)

            guard let config = response.configuration else {
                throw AWSProviderError.deploymentFailed("No configuration returned")
            }

            if config.state == .active && config.lastUpdateStatus == .successful {
                return
            }

            if config.state == .failed || config.lastUpdateStatus == .failed {
                let reason = config.lastUpdateStatusReason ?? "Unknown error"
                throw AWSProviderError.deploymentFailed(reason)
            }

            // Wait 2 seconds before next check
            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: .seconds(2))
            }
        }

        throw AWSProviderError.deploymentTimeout
    }

    private func configureConcurrency(functionName: String, reserved: Int) async throws {
        let request = Lambda.PutFunctionConcurrencyRequest(
            functionName: functionName,
            reservedConcurrentExecutions: reserved
        )
        _ = try await lambdaClient.putFunctionConcurrency(request)
    }

    private func getFunctionArn(functionName: String) async throws -> String {
        let request = Lambda.GetFunctionRequest(functionName: functionName)
        let response = try await lambdaClient.getFunction(request)

        guard let arn = response.configuration?.functionArn else {
            throw AWSProviderError.deploymentFailed("No ARN returned")
        }

        return arn
    }

    private func ensureRole(functionName: String, iamClient: IAM) async throws -> String {
        let roleName = "trebuchet-\(functionName)-role"

        // Check if role exists
        do {
            let getRequest = IAM.GetRoleRequest(roleName: roleName)
            let response = try await iamClient.getRole(getRequest)
            return response.role.arn
        } catch {
            // Role doesn't exist, create it
        }

        // Create trust policy for Lambda
        let trustPolicy = """
        {
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "lambda.amazonaws.com"},
            "Action": "sts:AssumeRole"
          }]
        }
        """

        let createRequest = IAM.CreateRoleRequest(
            assumeRolePolicyDocument: trustPolicy,
            roleName: roleName,
            tags: [
                IAM.Tag(key: "ManagedBy", value: "trebuchet"),
                IAM.Tag(key: "FunctionName", value: functionName)
            ]
        )

        let createResponse = try await iamClient.createRole(createRequest)

        // Attach basic Lambda execution policy
        let attachRequest = IAM.AttachRolePolicyRequest(
            policyArn: "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
            roleName: roleName
        )
        _ = try await iamClient.attachRolePolicy(attachRequest)

        // Wait for role to propagate (usually takes a few seconds)
        try await Task.sleep(for: .seconds(10))

        return createResponse.role.arn
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

// MARK: - AWS Provider Error

/// Errors that can occur during AWS deployment
public enum AWSProviderError: Error {
    case missingRole(String)
    case deploymentFailed(String)
    case deploymentTimeout
    case roleCreationFailed(String)
}
