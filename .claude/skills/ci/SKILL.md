---
name: ci
description: Run complete CI checks locally (build debug/release, run tests, check warnings)
---

Run a complete CI-like workflow locally to catch issues before pushing:

## Workflow

1. Check git status:
   ```bash
   cd /Users/bri/dev/Trebuchet && git status --short
   ```
   Warn if there are uncommitted changes.

2. Build in debug mode:
   ```bash
   cd /Users/bri/dev/Trebuchet && swift build 2>&1 | tee /tmp/trebuchet-build-debug.log
   ```

3. Build in release mode:
   ```bash
   cd /Users/bri/dev/Trebuchet && swift build --configuration release 2>&1 | tee /tmp/trebuchet-build-release.log
   ```

4. Run all tests:
   ```bash
   cd /Users/bri/dev/Trebuchet && swift test 2>&1 | tee /tmp/trebuchet-test.log
   ```

5. Check for warnings (excluding known unhandled file warnings):
   ```bash
   grep -i "warning:" /tmp/trebuchet-build-release.log | grep -v "found.*file.*which are unhandled" || echo "No warnings found"
   ```

## Report Summary

Provide a summary with:
- ✅/❌ Debug build status
- ✅/❌ Release build status
- ✅/❌ Test status (include pass/fail counts)
- Warning count
- **Overall CI Status**: PASS or FAIL

## Notes

- Logs are saved to `/tmp/trebuchet-*.log` for detailed inspection
- This does NOT run LocalStack AWS tests (use `/test-aws` for those)
- Mirrors what would run in GitHub Actions CI
- Helps catch issues before creating PRs
