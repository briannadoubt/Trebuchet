---
name: test-aws
description: Run AWS integration tests with LocalStack for local AWS service simulation
---

Run AWS integration tests using LocalStack:

1. Check if LocalStack is running:
   ```bash
   curl -s http://localhost:4566/_localstack/health 2>/dev/null
   ```

2. If not running, start LocalStack:
   ```bash
   cd /Users/bri/dev/Trebuchet && docker-compose -f docker-compose.localstack.yml up -d
   ```

3. Wait for LocalStack to be healthy (up to 30 seconds):
   ```bash
   timeout 30 bash -c 'until curl -s http://localhost:4566/_localstack/health | grep -q "\"running\""; do sleep 1; done'
   ```

4. Run the AWS integration tests:
   ```bash
   cd /Users/bri/dev/Trebuchet && swift test --filter TrebuchetAWSTests
   ```

5. Report test results

6. Ask the user if they want to stop LocalStack:
   - If yes: `docker-compose -f docker-compose.localstack.yml down -v`
   - If no: Leave it running for further testing

LocalStack simulates these AWS services:
- Lambda (function deployment/invocation)
- DynamoDB (actor state persistence)
- DynamoDB Streams (real-time state broadcasting)
- Cloud Map (service discovery)
- IAM (role management)
- API Gateway WebSocket (connection management)

For troubleshooting, refer to Tests/TrebuchetAWSTests/README.md
