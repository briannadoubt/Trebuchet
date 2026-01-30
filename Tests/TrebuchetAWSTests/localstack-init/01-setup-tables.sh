#!/bin/bash
set -e

echo "Creating DynamoDB tables for Trebuchet tests..."

# Create state table with DynamoDB Streams enabled
awslocal dynamodb create-table \
  --table-name trebuchet-test-state \
  --attribute-definitions \
    AttributeName=actorId,AttributeType=S \
  --key-schema \
    AttributeName=actorId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification \
    StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES

echo "✓ Created trebuchet-test-state table with DynamoDB Streams"

# Create connections table with ActorIndex GSI
awslocal dynamodb create-table \
  --table-name trebuchet-test-connections \
  --attribute-definitions \
    AttributeName=connectionId,AttributeType=S \
    AttributeName=actorId,AttributeType=S \
  --key-schema \
    AttributeName=connectionId,KeyType=HASH \
  --global-secondary-indexes \
    "[{\"IndexName\":\"ActorIndex\",\"KeySchema\":[{\"AttributeName\":\"actorId\",\"KeyType\":\"HASH\"}],\"Projection\":{\"ProjectionType\":\"ALL\"}}]" \
  --billing-mode PAY_PER_REQUEST

echo "✓ Created trebuchet-test-connections table with ActorIndex GSI"

# Create Cloud Map namespace
awslocal servicediscovery create-private-dns-namespace \
  --name trebuchet-test \
  --vpc vpc-12345

echo "✓ Created trebuchet-test Cloud Map namespace"

echo "LocalStack table setup complete!"
