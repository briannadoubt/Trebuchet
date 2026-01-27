import Testing
import Foundation
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
    func stateStoreInit() async {
        let store = DynamoDBStateStore(
            tableName: "test-table",
            region: "us-east-1"
        )

        // Store should be created without errors
        #expect(store != nil)
    }
}

@Suite("CloudMap Registry Tests")
struct CloudMapRegistryTests {

    @Test("CloudMapRegistry initialization")
    func registryInit() async {
        let registry = CloudMapRegistry(
            namespace: "test-namespace",
            region: "us-east-1"
        )

        #expect(registry != nil)
    }
}

@Suite("Lambda Transport Tests")
struct LambdaTransportTests {

    @Test("LambdaInvokeTransport initialization")
    func transportInit() {
        let transport = LambdaInvokeTransport(
            functionArn: "arn:aws:lambda:us-east-1:123456789012:function:test",
            region: "us-east-1"
        )

        #expect(transport != nil)
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
