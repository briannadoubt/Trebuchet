#!/bin/bash
set -e

echo "Creating IAM roles for Trebuchet tests..."

# Create Lambda execution role
awslocal iam create-role \
  --role-name trebuchet-test-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

echo "✓ Created trebuchet-test-lambda-role IAM role"

# Attach basic execution policy
awslocal iam attach-role-policy \
  --role-name trebuchet-test-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "✓ Attached AWSLambdaBasicExecutionRole policy"

echo "LocalStack IAM setup complete!"
