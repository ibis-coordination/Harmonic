# Run Manual Test

Run an existing manual test and update its status in `test/manual/**/*.manual_test.md`

## Usage

- `/run-manual-test <path>` - Run the manual test at the specified path
- `/run-manual-test` - If no path provided, prompt for a test file to run

## Instructions

1. **Parse the argument** `$ARGUMENTS`:
   - If a path is provided, use it directly
   - If empty, list available manual test files in `test/manual/` and ask which one to run

2. **Read the manual test file** to understand:
   - Prerequisites that must be met
   - Step-by-step instructions to follow
   - Checklist items to verify

3. **Verify prerequisites** are met:
   - Check if required user permissions are available
   - Use Rails console if needed to set up test data or permissions

4. **Execute the test steps** using the Harmonic MCP server:
   - Navigate to each specified location
   - Perform the actions described
   - Observe and verify expected results

5. **Update checklist items** as you go:
   - Mark items `- [x]` when verified as passing
   - Keep items `- [ ]` if they fail or cannot be verified
   - Add notes like `*(automated test)*` or `*(verified by code review)*` for items not directly testable via MCP

6. **Update the frontmatter** with results:
   ```yaml
   ---
   passing: true           # true only if ALL checklist items pass
   last_verified: YYYY-MM-DD  # today's date
   verified_by: Claude Opus 4.5  # who ran the test
   ---
   ```

7. **Report to the user** with a summary of:
   - Total checklist items: X
   - Passing: X
   - Failing: X (list any failures)
   - Overall status: PASSING or FAILING
