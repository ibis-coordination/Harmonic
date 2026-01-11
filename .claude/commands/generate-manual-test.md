# Generate Manual Test

Generate manual test instructions and checklist in `test/manual/**/*.manual_test.md`

## Usage

- `/generate-manual-test` - Start interactive manual test generation (will prompt for details)
- `/generate-manual-test <prompt>` - Generate a manual test based on the provided description

## Instructions

1. **Parse the argument** `$ARGUMENTS`:
   - If empty, ask the user for a description of the feature they want to test and what specific expectations they want to verify
   - If provided, interpret the user's intention to understand what feature needs to be tested and what expectations need to be verified. Ask followup questions for clarification if needed.

2. **Review relevant code** to understand the intended behavior of the feature being tested.

3. **Use the Harmonic MCP server** to navigate the markdown UI and execute actions until you have a repeatable step-by-step process that verifies the expected behavior.

4. **Create a markdown file** in `test/manual/` with the `.manual_test.md` extension:
   - Use snake_case naming: `feature_name.manual_test.md`
   - Organize by area using subdirectories if appropriate: `admin/tenant_settings.manual_test.md`
   - Follow the template structure in `test/manual/README.md`

5. **Write clear test content** including:
   - YAML frontmatter with run status (see format below)
   - Descriptive title and purpose
   - Prerequisites (setup, user permissions, test data)
   - Step-by-step instructions with exact actions to take
   - Checklist items to verify expected behavior (using `- [x]` for passing, `- [ ]` for failing/untested)

6. **Update frontmatter** after running the test:
   ```yaml
   ---
   passing: true           # true if all checklist items pass, false otherwise
   last_verified: 2026-01-11  # date of verification (YYYY-MM-DD)
   verified_by: Claude Opus 4.5  # who ran the test
   ---
   ```

7. **Report to the user** with a brief summary of:
   - What feature/behavior the test covers
   - The steps you took to verify it works
   - Whether the test is passing or failing
   - The path to the new test file
