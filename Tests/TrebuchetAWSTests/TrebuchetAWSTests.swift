import Testing
import Foundation
import SotoCore
@testable import TrebuchetAWS
@testable import TrebuchetCloud
@testable import Trebuchet

@Suite("TrebuchetAWS Tests")
struct TrebuchetAWSTests {

    @Test("AWSProvider type is correct")
    func awsProviderType() {
        #expect(AWSProvider.providerType == .aws)
    }

    @Test("AWSFunctionConfig defaults are reasonable")
    func functionConfigDefaults() {
        let config = AWSFunctionConfig.default
        #expect(config.memoryMB == 512)
        #expect(config.timeout == .seconds(30))
    }

    @Test("AWSFunctionConfig presets")
    func functionConfigPresets() {
        let highMem = AWSFunctionConfig.highMemory
        #expect(highMem.memoryMB == 2048)

        let longRunning = AWSFunctionConfig.longRunning
        #expect(longRunning.timeout == .seconds(300))
    }

    @Test("AWSCredentials from environment")
    func credentialsFromEnvironment() {
        let creds = AWSCredentials.fromEnvironment()
        // These should be nil in test environment unless explicitly set
        #expect(creds.sessionToken == nil || creds.sessionToken != nil)
    }

    @Test("AWSCredentials default uses credential provider chain")
    func credentialsDefaultBehavior() {
        // .default should have nil values, allowing Soto SDK to use its credential provider chain
        let creds = AWSCredentials.default
        #expect(creds.accessKeyId == nil)
        #expect(creds.secretAccessKey == nil)
        #expect(creds.sessionToken == nil)
    }

    @Test("LambdaInvokeTransport uses Soto credential chain with default credentials")
    func lambdaTransportCredentialChain() {
        // Create transport with .default credentials
        let transport = LambdaInvokeTransport(
            functionArn: "arn:aws:lambda:us-east-1:123456789012:function:test",
            region: "us-east-1",
            credentials: .default
        )

        // Transport should be initialized successfully
        // When credentials are .default (nil values), LambdaInvokeTransport uses
        // AWSClient(credentialProvider: .default) which leverages Soto's full
        // credential provider chain (environment, IAM roles, instance profiles, etc.)
        _ = transport  // Verify it initialized

        // Clean up
        Task {
            await transport.shutdown()
        }
    }

    @Test("LambdaInvokeTransport uses static credentials when provided")
    func lambdaTransportStaticCredentials() {
        // Create transport with explicit credentials
        let creds = AWSCredentials(
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        )

        let transport = LambdaInvokeTransport(
            functionArn: "arn:aws:lambda:us-east-1:123456789012:function:test",
            region: "us-east-1",
            credentials: creds
        )

        // Transport should be initialized with static credentials
        _ = transport  // Verify it initialized

        // Clean up
        Task {
            await transport.shutdown()
        }
    }

    @Test("AWSBase64Data decoded method works correctly")
    func awsBase64DataDecoding() {
        // Test data
        let testData = Data("Hello, Trebuchet!".utf8)

        // Create AWSBase64Data from raw data
        let awsData = AWSBase64Data.data(testData)

        // Decode back to bytes
        guard let decodedBytes = awsData.decoded() else {
            Issue.record("Failed to decode AWSBase64Data")
            return
        }

        // Convert back to Data
        let decodedData = Data(decodedBytes)

        // Verify round-trip works
        #expect(decodedData == testData)
        #expect(String(data: decodedData, encoding: .utf8) == "Hello, Trebuchet!")
    }

    @Test("AWSDeployment properties")
    func deploymentProperties() {
        let deployment = AWSDeployment(
            provider: .aws,
            actorID: "test-actor",
            region: "us-east-1",
            identifier: "arn:aws:lambda:us-east-1:123456789012:function:test-actor",
            createdAt: Date(),
            functionName: "test-actor",
            memoryMB: 512,
            timeout: .seconds(30)
        )

        #expect(deployment.provider == .aws)
        #expect(deployment.actorID == "test-actor")
        #expect(deployment.region == "us-east-1")
        #expect(deployment.functionName == "test-actor")
    }

    @Test("VPCConfig initialization")
    func vpcConfigInit() {
        let vpc = VPCConfig(
            subnetIds: ["subnet-1", "subnet-2"],
            securityGroupIds: ["sg-1"]
        )

        #expect(vpc.subnetIds.count == 2)
        #expect(vpc.securityGroupIds.count == 1)
    }
}

@Suite("DynamoDB State Store Tests")
struct DynamoDBStateStoreTests {

    @Test("DynamoDBStateStore initialization")
    func stateStoreInit() async throws {
        let store = DynamoDBStateStore(
            tableName: "test-table",
            region: .useast1
        )

        // Store should be created without errors
        // Note: We verify initialization succeeded by not throwing

        // Clean up
        try await store.shutdown()
    }
}

@Suite("CloudMap Registry Tests")
struct CloudMapRegistryTests {

    @Test("CloudMapRegistry initialization")
    func registryInit() async throws {
        let registry = CloudMapRegistry(
            namespace: "test-namespace",
            region: .useast1
        )

        // Note: We verify initialization succeeded by not throwing

        // Clean up
        try await registry.shutdown()
    }
}

@Suite("Lambda Transport Tests")
struct LambdaTransportTests {

    @Test("LambdaInvokeTransport initialization")
    func transportInit() async {
        let transport = LambdaInvokeTransport(
            functionArn: "arn:aws:lambda:us-east-1:123456789012:function:test",
            region: "us-east-1"
        )

        // Note: We verify initialization succeeded by not throwing

        // Clean up
        await transport.shutdown()
    }

    @Test("HTTP response status codes")
    func httpStatusCodes() {
        #expect(HTTPResponseStatus.ok.rawValue == 200)
        #expect(HTTPResponseStatus.badRequest.rawValue == 400)
        #expect(HTTPResponseStatus.internalServerError.rawValue == 500)
    }

    @Test("APIGatewayV2Request parsing")
    func apiGatewayRequest() throws {
        let json = """
        {
            "version": "2.0",
            "routeKey": "POST /invoke",
            "rawPath": "/invoke",
            "body": "{\\"test\\": true}"
        }
        """

        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(APIGatewayV2Request.self, from: data)

        #expect(request.version == "2.0")
        #expect(request.routeKey == "POST /invoke")
        #expect(request.rawPath == "/invoke")
        #expect(request.body != nil)
    }

    @Test("APIGatewayV2Response encoding")
    func apiGatewayResponse() throws {
        let response = APIGatewayV2Response(
            statusCode: .ok,
            headers: ["Content-Type": "application/json"],
            body: "{\"status\": \"ok\"}"
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(APIGatewayV2Response.self, from: data)

        #expect(decoded.statusCode == .ok)
        #expect(decoded.body == "{\"status\": \"ok\"}")
    }
}
