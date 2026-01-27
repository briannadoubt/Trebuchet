/// TrebuchetAWS - AWS Lambda deployment support for Trebuchet
///
/// This module provides AWS-specific implementations for deploying
/// distributed actors to AWS Lambda with:
/// - DynamoDB for actor state storage
/// - CloudMap for service discovery
/// - Direct Lambda invocation for actor-to-actor calls
///
/// ## Overview
///
/// TrebuchetAWS enables serverless deployment of Swift distributed actors.
/// Each actor runs in a Lambda function and can discover and communicate
/// with other actors through CloudMap.
///
/// ## Basic Usage
///
/// ```swift
/// import TrebuchetAWS
///
/// // Configure AWS provider
/// let provider = AWSProvider(region: "us-east-1")
///
/// // Deploy an actor
/// let deployment = try await provider.deploy(
///     MyActor.self,
///     as: "my-actor",
///     config: .default,
///     factory: { MyActor(actorSystem: $0) }
/// )
///
/// // Create a transport for the deployed actor
/// let transport = try await provider.transport(for: deployment)
/// ```
///
/// ## Lambda Bootstrap
///
/// In your Lambda function, use CloudGateway with AWS state and registry:
///
/// ```swift
/// @main
/// struct ActorLambdaHandler: LambdaHandler {
///     let gateway: CloudGateway
///
///     init(context: LambdaInitializationContext) async throws {
///         let stateStore = DynamoDBStateStore(tableName: "my-actors")
///         let registry = CloudMapRegistry(namespace: "my-app")
///
///         gateway = CloudGateway(configuration: .init(
///             stateStore: stateStore,
///             registry: registry
///         ))
///
///         // Register actors
///         try await gateway.expose(MyActor(actorSystem: gateway.system), as: "my-actor")
///     }
///
///     func handle(_ event: APIGatewayV2Request, context: LambdaContext) async throws -> APIGatewayV2Response {
///         let envelope = try LambdaEventAdapter.fromAPIGateway(event)
///         let response = await gateway.handleInvocation(envelope)
///         return try LambdaEventAdapter.toAPIGatewayResponse(response)
///     }
/// }
/// ```

@_exported import Trebuchet
@_exported import TrebuchetCloud
