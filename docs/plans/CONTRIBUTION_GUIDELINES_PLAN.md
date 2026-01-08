# Contribution Guidelines Plan

This document outlines a plan to establish contribution guidelines and PR templates.

## Objective

Establish clear contribution guidelines and PR requirements to ensure consistent quality, especially when AI agents contribute to the codebase.

## Current State

- No `CONTRIBUTING.md` file exists
- No PR template exists
- No issue templates exist

## Tasks

### 1. Create CONTRIBUTING.md

**File**: `CONTRIBUTING.md` (project root)

```markdown
# Contributing to Harmonic

Thank you for your interest in contributing to Harmonic! This document provides guidelines and requirements for contributions.

## Before You Start

1. **Read the documentation**:
   - [AGENTS.md](AGENTS.md) - Guidelines for AI agents and developers
   - [PHILOSOPHY.md](PHILOSOPHY.md) - Project values and motivations
   - [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - System architecture

2. **Understand the codebase**:
   - This is a Rails 7.0 application with PostgreSQL
   - Multi-tenancy via subdomains is a core pattern
   - See `docs/` for detailed documentation

## Development Setup

1. Clone the repository
2. Run `./scripts/setup.sh` to initialize the environment
3. Run `./scripts/start.sh` to start Docker containers
4. Run `./scripts/run-tests.sh` to verify everything works

## Making Changes

### Branch Naming

Use descriptive branch names:
- `feature/add-user-notifications`
- `fix/decision-voting-bug`
- `test/add-commitment-tests`
- `docs/update-api-documentation`

### Code Style

- Follow existing Rails conventions
- Run `bundle exec rubocop` before committing
- Keep controllers thin, models focused
- Use service objects for complex business logic

### Testing Requirements

**All PRs must:**

1. **Not decrease test coverage** - Coverage must stay at or above the current threshold
2. **Include tests for new features** - New functionality requires corresponding tests
3. **Include tests for bug fixes** - Bug fixes should include a regression test
4. **Pass all existing tests** - No breaking changes to existing tests

**Test guidelines:**

- Follow patterns in `docs/TEST_COVERAGE_PLAN.md`
- Use helper methods from `test/test_helper.rb`
- Be mindful of multi-tenancy in tests
- Clean up test data (handled by global teardown)

### Commit Messages

Write clear, descriptive commit messages:

```
[Type] Short description (50 chars or less)

Longer description if needed. Explain what and why,
not how (the code shows how).

Refs: #123 (if applicable)
```

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `chore`

## Pull Request Process

1. **Create a draft PR early** for visibility on larger changes
2. **Fill out the PR template completely**
3. **Ensure CI passes** before requesting review
4. **Respond to feedback** promptly
5. **Squash commits** if requested

## For AI Agents

If you are an AI agent contributing to this codebase:

1. **Always read `AGENTS.md` first** - It contains critical context
2. **Run tests before and after changes** - Use `./scripts/run-tests.sh`
3. **Check for TODOs** - Run `./scripts/check-todo-index.sh`
4. **Don't introduce debug code** - Run `./scripts/check-debug-code.sh`
5. **Follow existing patterns** - Look at similar code before writing new code
6. **Ask for clarification** if requirements are unclear

## Questions?

Open an issue for questions about contributing.
```

### 2. Create PR Template

**File**: `.github/PULL_REQUEST_TEMPLATE.md`

```markdown
## Description

<!-- Briefly describe what this PR does -->

## Type of Change

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to change)
- [ ] 📝 Documentation update
- [ ] 🧪 Test update (no production code changes)
- [ ] 🔧 Refactor (no functional changes)

## Related Issues

<!-- Link any related issues: Fixes #123, Relates to #456 -->

## Changes Made

-
-

## Testing

- [ ] Added/updated tests for new functionality
- [ ] All tests pass (`./scripts/run-tests.sh`)
- [ ] Coverage does not decrease

## Pre-Submission Checklist

- [ ] I have read [AGENTS.md](../AGENTS.md)
- [ ] My code follows the existing code style
- [ ] I have run `./scripts/check-debug-code.sh` (no debug code)

## Screenshots (if applicable)

<!-- Add screenshots for UI changes -->
```

### 3. Create Issue Templates

**File**: `.github/ISSUE_TEMPLATE/bug_report.md`

```markdown
---
name: Bug Report
about: Report a bug to help us improve
title: '[BUG] '
labels: bug
---

## Bug Description

<!-- A clear description of the bug -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What should happen -->

## Actual Behavior

<!-- What actually happens -->

## Additional Context

<!-- Any other relevant information -->
```

**File**: `.github/ISSUE_TEMPLATE/feature_request.md`

```markdown
---
name: Feature Request
about: Suggest an idea for Harmonic
title: '[FEATURE] '
labels: enhancement
---

## Problem Statement

<!-- What problem does this feature solve? -->

## Proposed Solution

<!-- Describe the solution you'd like -->

## Additional Context

<!-- Any other context, mockups, or examples -->
```

## Checklist

| Task | Priority | Status |
|------|----------|--------|
| Create CONTRIBUTING.md | High | [ ] |
| Create PR template | High | [ ] |
| Create bug report template | Medium | [ ] |
| Create feature request template | Medium | [ ] |
