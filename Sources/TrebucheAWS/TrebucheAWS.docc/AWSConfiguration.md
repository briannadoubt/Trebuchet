# AWS Configuration Reference

Complete reference for AWS deployment configuration options.

## Overview

This article covers all configuration options available when deploying to AWS.

## trebuche.yaml Reference

### Top-Level Configuration

```yaml
name: my-project           # Project name (used for resource naming)
version: "1"               # Configuration version

defaults:
  provider: aws            # Cloud provider
  region: us-east-1        # AWS region
  memory: 512              # Default memory (MB)
  timeout: 30              # Default timeout (seconds)

actors: {}                 # Actor-specific configuration
environments: {}           # Environment overrides
state: {}                  # State storage configuration
discovery: {}              # Service discovery configuration
```

### Actor Configuration

```yaml
actors:
  MyActor:
    memory: 1024           # Memory in MB (128-10240)
    timeout: 60            # Timeout in seconds (1-900)
    stateful: true         # Enable DynamoDB state persistence
    isolated: true         # Run in dedicated Lambda function
    environment:           # Environment variables
      KEY: value
```

### State Configuration

```yaml
state:
  type: dynamodb           # State store type
  tableName: custom-table  # Optional: custom table name
```

### Discovery Configuration

```yaml
discovery:
  type: cloudmap           # Registry type
  namespace: my-namespace  # CloudMap namespace name
```

### Environment Configuration

```yaml
environments:
  production:
    region: us-west-2
    memory: 2048
    environment:
      LOG_LEVEL: warn
  staging:
    region: us-east-1
    environment:
      LOG_LEVEL: debug
```

## AWS Credentials

The CLI uses the standard AWS credential chain:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. AWS credentials file (`~/.aws/credentials`)
3. IAM instance profile (EC2, ECS, Lambda)

```bash
# Using environment variables
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_REGION=us-east-1

trebuche deploy
```

```bash
# Using a named profile
export AWS_PROFILE=my-profile
trebuche deploy
```

## IAM Permissions

The deployment requires these IAM permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:GetFunction",
        "lambda:CreateFunctionUrlConfig",
        "lambda:DeleteFunctionUrlConfig"
      ],
      "Resource": "arn:aws:lambda:*:*:function:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DeleteTable",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "servicediscovery:CreatePrivateDnsNamespace",
        "servicediscovery:DeleteNamespace",
        "servicediscovery:CreateService",
        "servicediscovery:DeleteService"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::*:role/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:*"
    }
  ]
}
```

## Terraform Variables

The generated Terraform accepts these variables:

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | us-east-1 | AWS region |
| `vpc_id` | string | required | VPC ID |
| `subnet_ids` | list(string) | required | Subnet IDs |
| `security_group_ids` | list(string) | required | Security group IDs |
| `lambda_memory` | number | 512 | Lambda memory (MB) |
| `lambda_timeout` | number | 30 | Lambda timeout (seconds) |
| `lambda_url_auth_type` | string | NONE | Auth type (NONE, AWS_IAM) |
| `create_api_gateway` | bool | false | Create API Gateway |
| `cors_allowed_origins` | list(string) | ["*"] | CORS origins |
| `log_level` | string | info | Application log level |
| `log_retention_days` | number | 14 | Log retention period |

## DynamoDB Table Schema

The state table uses this schema:

| Attribute | Type | Description |
|-----------|------|-------------|
| `actorId` | String (PK) | Actor identifier |
| `state` | Binary | Serialized actor state |
| `updatedAt` | String | Last update timestamp |
| `ttl` | Number | TTL for automatic cleanup |

## CloudMap Configuration

Actors register with CloudMap using:

| Attribute | Description |
|-----------|-------------|
| `ENDPOINT` | Lambda ARN or API Gateway URL |
| `REGION` | AWS region |
| `PROVIDER` | Always "aws" |

## See Also

- <doc:DeployingToAWS>
- ``AWSProvider``
- ``AWSFunctionConfig``
