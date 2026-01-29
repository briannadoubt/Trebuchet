# Soto Integration Examples

This document shows what the AWS implementations will look like after Soto integration.

## Before vs After

### DynamoDB State Store

**Before (Manual HTTP):**
```swift
private func execute(_ request: DynamoDBRequest) async throws -> DynamoDBResponse {
    // In a real implementation, this would use the AWS SDK (Soto)
    // For now, we'll use direct HTTP calls
    let url = endpoint ?? "https://dynamodb.\(region).amazonaws.com"
    let body = try encoder.encode(request)

    var urlRequest = URLRequest(url: URL(string: url)!)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
    // ... manual AWS Signature V4 signing ...
    // ... manual error handling ...
    // ... manual retries ...
}
```

**After (With Soto):**
```swift
import SotoDynamoDB

actor DynamoDBStateStore: ActorStateStore {
    private let client: DynamoDB
    private let tableName: String

    init(tableName: String, region: Region = .useast1) {
        self.tableName = tableName
        self.client = DynamoDB(client: AWSClient(), region: region)
    }

    func save(_ state: Data, for actorID: String, version: Int) async throws {
        let input = DynamoDB.PutItemInput(
            conditionExpression: "attribute_not_exists(actorId) OR version < :newVersion",
            expressionAttributeValues: [":newVersion": .n(String(version))],
            item: [
                "actorId": .s(actorID),
                "state": .b(state),
                "version": .n(String(version)),
                "updatedAt": .n(String(Date().timeIntervalSince1970))
            ],
            tableName: tableName
        )

        _ = try await client.putItem(input)
    }

    func load(for actorID: String) async throws -> (Data, Int)? {
        let input = DynamoDB.GetItemInput(
            key: ["actorId": .s(actorID)],
            tableName: tableName
        )

        let output = try await client.getItem(input)

        guard let item = output.item,
              let stateAttr = item["state"], case .b(let stateData) = stateAttr,
              let versionAttr = item["version"], case .n(let versionStr) = versionAttr,
              let version = Int(versionStr) else {
            return nil
        }

        return (stateData, version)
    }

    func delete(for actorID: String) async throws {
        let input = DynamoDB.DeleteItemInput(
            key: ["actorId": .s(actorID)],
            tableName: tableName
        )

        _ = try await client.deleteItem(input)
    }
}
```

### CloudMap Service Registry

**Before (Stub):**
```swift
private func execute(_ request: CloudMapRequest) async throws -> CloudMapResponse {
    // In a real implementation, this would use the AWS SDK (Soto)
    // For now, we return an empty response
    return CloudMapResponse()
}
```

**After (With Soto):**
```swift
import SotoServiceDiscovery

actor CloudMapRegistry: ServiceRegistry {
    private let client: ServiceDiscovery
    private let namespaceId: String
    private let serviceId: String

    init(namespace: String, region: Region = .useast1) async throws {
        let awsClient = AWSClient()
        self.client = ServiceDiscovery(client: awsClient, region: region)

        // Look up or create namespace
        self.namespaceId = try await getOrCreateNamespace(namespace)
        self.serviceId = try await getOrCreateService("trebuchet-actors")
    }

    func register(actorType: String, endpoint: CloudEndpoint) async throws {
        let input = ServiceDiscovery.RegisterInstanceInput(
            attributes: [
                "endpoint": endpoint.url.absoluteString,
                "actorType": actorType
            ],
            instanceId: "\(actorType)-\(UUID().uuidString)",
            serviceId: serviceId
        )

        _ = try await client.registerInstance(input)
    }

    func discover(actorType: String) async throws -> [CloudEndpoint] {
        let input = ServiceDiscovery.DiscoverInstancesInput(
            healthStatus: .healthy,
            queryParameters: ["actorType": actorType],
            serviceId: serviceId
        )

        let output = try await client.discoverInstances(input)

        return output.instances?.compactMap { instance in
            guard let urlStr = instance.attributes?["endpoint"],
                  let url = URL(string: urlStr) else {
                return nil
            }
            return CloudEndpoint(url: url, metadata: instance.attributes ?? [:])
        } ?? []
    }
}
```

### CloudWatch Metrics Reporter

**Before (Console Print):**
```swift
private func sendBatch(_ batch: [Metric]) async {
    #if DEBUG
    print("Would send \(batch.count) metrics to CloudWatch")
    #endif
}
```

**After (With Soto):**
```swift
import SotoCloudWatch

actor CloudWatchReporter {
    private let client: CloudWatch
    private let namespace: String

    init(namespace: String, region: Region = .useast1) {
        self.client = CloudWatch(client: AWSClient(), region: region)
        self.namespace = namespace
    }

    private func sendBatch(_ batch: [Metric]) async throws {
        let metricData = batch.map { metric -> CloudWatch.MetricDatum in
            CloudWatch.MetricDatum(
                dimensions: metric.tags.map { key, value in
                    CloudWatch.Dimension(name: key, value: value)
                },
                metricName: metric.name,
                timestamp: Date(),
                unit: convertUnit(metric.unit),
                value: metric.value
            )
        }

        let input = CloudWatch.PutMetricDataInput(
            metricData: metricData,
            namespace: namespace
        )

        // CloudWatch can handle up to 1000 metrics per request
        // but we batch smaller for better reliability
        for batch in metricData.chunked(into: 20) {
            let batchInput = CloudWatch.PutMetricDataInput(
                metricData: batch,
                namespace: namespace
            )
            try await client.putMetricData(batchInput)
        }
    }
}
```

### Lambda Deployment (AWS Provider)

**Before (Placeholder):**
```swift
func deploy() async throws -> CloudDeployment {
    // For now, return a placeholder deployment
    return CloudDeployment(
        id: UUID().uuidString,
        endpoint: URL(string: "https://placeholder.execute-api.us-east-1.amazonaws.com")!,
        metadata: [:]
    )
}
```

**After (With Soto):**
```swift
import SotoLambda

actor AWSProvider: CloudProvider {
    private let lambda: Lambda
    private let region: Region

    func deploy(configuration: DeploymentConfiguration) async throws -> CloudDeployment {
        // Create or update Lambda function
        let functionName = "\(configuration.projectName)-actors"

        do {
            // Try to update existing function
            let updateCodeInput = Lambda.UpdateFunctionCodeRequest(
                functionName: functionName,
                zipFile: configuration.packageData
            )
            _ = try await lambda.updateFunctionCode(updateCodeInput)

        } catch {
            // Create new function if it doesn't exist
            let createInput = Lambda.CreateFunctionRequest(
                architectures: [.arm64],
                code: Lambda.FunctionCode(zipFile: configuration.packageData),
                environment: Lambda.Environment(
                    variables: configuration.environmentVariables
                ),
                functionName: functionName,
                handler: "bootstrap",
                memorySize: configuration.memory,
                packageType: .zip,
                role: try await getOrCreateExecutionRole(),
                runtime: .providedal2023,
                timeout: configuration.timeout
            )
            _ = try await lambda.createFunction(createInput)
        }

        // Get function configuration to return endpoint
        let getInput = Lambda.GetFunctionRequest(functionName: functionName)
        let output = try await lambda.getFunction(getInput)

        guard let functionArn = output.configuration?.functionArn else {
            throw TrebuchetError.deploymentFailed("Failed to get function ARN")
        }

        return CloudDeployment(
            id: functionArn,
            endpoint: URL(string: "https://\(functionName).lambda-url.\(region.rawValue).on.aws")!,
            metadata: [
                "functionArn": functionArn,
                "region": region.rawValue
            ]
        )
    }
}
```

## Benefits of Soto

1. **Type Safety**: All AWS API calls are fully typed
2. **Error Handling**: AWS errors are automatically mapped to Swift errors
3. **Retries**: Built-in retry logic with exponential backoff
4. **Authentication**: Automatic credential discovery (environment, IAM roles, profiles)
5. **Request Signing**: AWS Signature V4 handled automatically
6. **Async/Await**: Native Swift concurrency support
7. **Streaming**: Efficient handling of large responses
8. **Testing**: Easy to mock with protocols

## Build Time Impact

With SotoCodeGenerator plugin and only 5 services configured:
- **First build**: ~30-60 seconds additional
- **Incremental builds**: ~5-10 seconds additional (only if Soto code changes)
- **Clean builds**: Same as first build

The generated code is cached, so you don't pay the generation cost every build.

## Next Steps

1. ✅ Add Soto dependencies to Package.swift
2. ✅ Configure soto.config.json with required services
3. ⏳ Replace DynamoDBStateStore implementation
4. ⏳ Replace CloudMapRegistry implementation
5. ⏳ Replace CloudWatchReporter implementation
6. ⏳ Implement AWSProvider deployment
7. ⏳ Add integration tests with LocalStack

## Testing Strategy

Use LocalStack for local AWS simulation:

```bash
# Start LocalStack
docker run -d -p 4566:4566 localstack/localstack

# Configure Soto to use LocalStack
let client = AWSClient(
    credentialProvider: .static(accessKeyId: "test", secretAccessKey: "test"),
    httpClientProvider: .createNew
)

let dynamodb = DynamoDB(
    client: client,
    region: .useast1,
    endpoint: "http://localhost:4566"
)
```

This allows full integration testing without AWS costs.
