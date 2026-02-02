---
name: test
description: Run Trebuchet test suites using Swift Testing framework
---

Run the test suite for Trebuchet:

1. Ask the user which test suite to run (or run all if not specified)

Available test suites:
- All tests: `swift test`
- Core: `swift test --filter TrebuchetTests`
- Macros: `swift test --filter TrebuchetMacrosTests`
- Cloud: `swift test --filter TrebuchetCloudTests`
- AWS (unit tests): `swift test --filter TrebuchetAWSTests`
- CLI: `swift test --filter TrebuchetCLITests`
- Security: `swift test --filter TrebuchetSecurityTests`
- Observability: `swift test --filter TrebuchetObservabilityTests`
- PostgreSQL: `swift test --filter TrebuchetPostgreSQLTests`

2. Run the appropriate test command from `/Users/bri/dev/Trebuchet`
3. Report test results including pass/fail counts
4. If failures occur, show the failing tests and suggest next steps

Note: AWS integration tests require LocalStack - use the `/test-aws` skill instead.
