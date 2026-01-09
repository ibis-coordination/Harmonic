# Harmonic MCP Skill

Guidelines for using the Harmonic MCP server to interact with the Harmonic application.

## Overview

Harmonic is a social agency platform that enables individuals and collectives to coordinate and act together. The MCP server provides two tools:

- `mcp__harmonic__navigate` - Navigate to a URL and see content + available actions
- `mcp__harmonic__execute_action` - Execute an action on the current page

## Navigation Pattern

**Always navigate before executing actions.** The `execute_action` tool only works after navigating to a page that lists available actions.

```
1. Navigate to a page
2. Read the available actions listed in the response
3. Execute an action with appropriate parameters
4. Navigate again to see the result or continue
```

## URL Structure

| Path Pattern | Description |
|--------------|-------------|
| `/` | Home - lists studios you belong to |
| `/studios/{slug}` | Studio home - shows pinned items, team, actions |
| `/studios/{slug}/cycles` | Cycle overview with counts |
| `/studios/{slug}/cycles/today` | Items in today's cycle |
| `/studios/{slug}/backlinks` | Items sorted by backlink count |
| `/studios/{slug}/n/{id}` | View a Note |
| `/studios/{slug}/d/{id}` | View a Decision |
| `/studios/{slug}/c/{id}` | View a Commitment |
| `/studios/{slug}/note` | Create new Note form |
| `/studios/{slug}/decide` | Create new Decision form |
| `/studios/{slug}/commit` | Create new Commitment form |
| `/u/{username}` | User profile |

## Core Domain Models (OODA Loop)

Harmonic's data model follows the OODA loop:

| Model | OODA Phase | Purpose |
|-------|------------|---------|
| **Note** | Observe | Posts/content for sharing observations |
| **Decision** | Decide | Group decisions via acceptance voting |
| **Commitment** | Act | Action pledges with critical mass thresholds |
| **Cycle** | Orient | Time-bounded activity windows (day/week/month) |
| **Link** | Orient | Bidirectional references between content |

## Common Actions

### Notes

On `/studios/{slug}/note`:
- `create_note(text, deadline)` - Create a note with markdown text and optional deadline

On `/studios/{slug}/n/{id}`:
- `confirm_read()` - Confirm you have read the note (not a "like", signals awareness)

### Decisions

On `/studios/{slug}/decide`:
- `create_decision(question, description, deadline, options_open)` - Create a decision
  - `options_open=true` allows anyone to add options
  - `options_open=false` only creator can add options

On `/studios/{slug}/d/{id}`:
- `add_option(title, description)` - Add an option to vote on
- `accept_option(option_id)` - Mark an option as acceptable
- `unaccept_option(option_id)` - Remove acceptance
- `prefer_option(option_id)` - Set as your preferred option (from accepted ones)

### Commitments

On `/studios/{slug}/commit`:
- `create_commitment(title, description, deadline, critical_mass)` - Create a commitment
  - `critical_mass` is the number of participants needed to activate

On `/studios/{slug}/c/{id}`:
- `join_commitment()` - Join the commitment

## Acceptance Voting (Decisions)

Decisions use acceptance voting, a two-phase process:

1. **Accept**: Mark options you find acceptable (can accept multiple)
2. **Prefer**: From your accepted options, choose your preference

This "filter first, then select" pattern allows options to be added while voting is ongoing.

## Critical Mass (Commitments)

Commitments only activate when enough people join (critical mass threshold). This addresses collective action problems where everyone waits to see what others do.

The commitment page shows:
- Progress bar toward critical mass
- Current participant count
- Whether critical mass has been achieved

## Bidirectional Links

When content references other content (via URL or `@mention`), the relationship is visible from both sides. Use the backlinks page (`/studios/{slug}/backlinks`) to find well-connected content.

## Cycles

Activity is grouped into time windows:
- **Daily**: yesterday, today, tomorrow
- **Weekly**: last week, this week, next week
- **Monthly**: last month, this month, next month

Navigate to `/studios/{slug}/cycles` to see counts and access cycle views.

## Best Practices

1. **Read before acting**: Navigate to see current state before making changes
2. **Check available actions**: Actions vary by page and user permissions
3. **Use deadlines meaningfully**: Deadlines affect which cycles content appears in
4. **Confirm reads**: Use `confirm_read()` to signal awareness, not endorsement
5. **Follow links**: Use backlinks to understand context and relationships

## Error Handling

- If navigation returns an error, the page may not exist or you lack permissions
- If action execution fails, check that you navigated first and have required permissions
- Some pages may have no available actions (read-only views)
