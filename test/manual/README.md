# Manual Testing

This folder contains manual test instructions for verifying features that benefit from end-to-end human or AI review beyond automated tests.

## Running Manual Tests

**AI agents (primary):** Use the Harmonic MCP server to navigate the markdown UI, follow the step-by-step instructions in the test file, and verify each checklist item.

**Humans:** Follow the instructions in a web browser using the HTML UI. The steps should translate directly between interfaces.

## Creating New Tests

Use the `/generate-manual-test` command to create new manual tests. This command will:
1. Help you define what feature and expectations to test
2. Review relevant code to understand intended behavior
3. Walk through the feature via the MCP server to verify steps
4. Generate a properly formatted test file

## File Format

Manual test files use the `.manual_test.md` extension and follow this structure:

```markdown
---
passing: true
last_verified: 2026-01-11
verified_by: Claude Opus 4.5
---

# Test: Feature Name

Brief description of what this test verifies.

## Prerequisites

- Required user permissions or roles
- Any test data that must exist
- Setup steps before starting

## Steps

1. Navigate to [specific location]
2. Perform [specific action]
3. Observe [expected result]

## Checklist

- [ ] Expected behavior 1 is verified
- [ ] Expected behavior 2 is verified
- [ ] Edge case is handled correctly
```

## Frontmatter

Each manual test file must include YAML frontmatter with run status:

| Field | Type | Description |
|-------|------|-------------|
| `passing` | boolean | Whether all checklist items passed on last run |
| `last_verified` | date | Date of last verification (YYYY-MM-DD) |
| `verified_by` | string | Who ran the test (e.g., "Claude Opus 4.5", "Human - @username") |

Update the frontmatter each time you run a manual test.

## Organization

- Files are named using snake_case: `feature_name.manual_test.md`
- Related tests can be grouped in subdirectories: `admin/`, `decisions/`, etc.
