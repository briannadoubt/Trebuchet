---
name: dev-test
description: Run the complete dev server test workflow for the Aura project
---

Execute the dev server test workflow from DEV_SERVER_TEST_PROMPT.md:

1. Clean the .trebuchet directory in the Aura project: `cd /Users/bri/dev/Aura && rm -rf .trebuchet`
2. Run the dev server with verbose output:
   ```bash
   /Users/bri/dev/Trebuchet/.build/release/trebuchet dev --local /Users/bri/dev/Trebuchet --verbose
   ```
3. Monitor the output for:
   - Actor discovery
   - Build success/failure
   - Server startup on localhost:8080

If build fails:
- Analyze the error output
- Identify the error pattern (actor isolation, module not found, streaming handler error)
- Refer to DEV_SERVER_TEST_PROMPT.md for fix patterns
- Apply the fix if possible
- Rebuild trebuchet if changes were made to Trebuchet sources
- Retry (max 3 attempts)

If successful:
- Confirm server is running on ws://localhost:8080
- Provide next steps for client verification
- Keep the server running for testing

Expected success output includes:
- "✓ Build succeeded"
- "✓ Runner generated"
- "Server running on ws://localhost:8080"
